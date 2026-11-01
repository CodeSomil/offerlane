import Foundation
import AppKit
import Network
import OfferlaneCore

/// In-app acceptance test of the apply engine against the prototype's mock sites (OFFERLANE_SELFTEST=apply).
/// WebKit needs a real app process, so this runs inside Offerlane and prints PASS/FAIL lines, then quits.
@MainActor
enum ApplySelfTest {
    static func run(app: AppModel) async -> Int32 {
        var results: [(Bool, String)] = []
        func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); fflush(stdout); results.append((ok, what)) }
        let kc = Keychain(service: "com.somilmanke.Offerlane.selftest"); defer { kc.deleteAll() }
        let vault = Vault(store: app.store, keychain: kc)
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("SelfTest"), let server = try? LocalServer(root: dir) else { print("FAIL no mock sites"); return 1 }
        let port = await server.ready()
        let base = "http://127.0.0.1:\(port)"

        var p = Profile()
        p.personal.firstName = "Test"; p.personal.lastName = "Person"; p.personal.fullName = "Test Person"; p.personal.email = "test@example.com"
        p.personal.phone = "+44 7700 900000"; p.personal.city = "London"; p.personal.country = "United Kingdom"
        p.work.currentCompany = "Acme"; p.work.currentTitle = "Senior Data Scientist"; p.work.yearsExperience = "5"
        p.authorization.authorizedCountries = ["United Kingdom"]; p.authorization.needsSponsorship = true
        p.misc.howHeard = "Company Website"; p.eeo.gender = "Male"
        try? app.store.set(.profile, p)
        var r = ResumeContent(); r.name = "Test Person"; r.email = "test@example.com"
        r.experience = [.init(id: "e1", title: "Senior Data Scientist", company: "Acme", bullets: [.init(id: "e1.1", text: "Built forecasting for 1,200 products.")])]
        let pdf = ResumePDF.render(r).0
        let answers = AnswerRules.parseAnswers(Tailor.answersMarkdown({ var t = TailorPlan(); t.coverLetter = "Hello from the cover letter"; t.whyCompany = "Because"
            t.answers = [.init(q: "Why do you want to work here?", a: "Because the mission fits.")]; return t }(), company: "Globex"))

        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1200, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Offerlane self-test"; window.orderFrontRegardless()
        func page() -> WebPage { let pg = WebPage(persistent: false); window.contentView = pg.web; return pg }
        func engine(_ pg: WebPage, _ j: Job) -> ApplyEngine {
            ApplyEngine(page: pg, job: j, profile: p, answers: answers, pdf: (pdf, "Test_Person_Resume.pdf"), vault: vault, pace: 0.08)
        }
        func js(_ pg: WebPage, _ s: String) async -> JSONValue {
            guard let str = await pg.eval("JSON.stringify(\(s))") as? String else { return .null }
            return (try? JSONDecoder().decode(JSONValue.self, from: Data(str.utf8))) ?? .null
        }

        // ---- Workday-style site: account gate, approval, account creation, six pages, stop at Review ----
        let wd = Job(company: "Acme", title: "Senior Data Scientist", location: "London, UK", url: "\(base)/workday.html")
        let pg = page()
        await pg.load(URL(string: wd.url)!)
        let o1 = await engine(pg, wd).run(first: true)
        check(o1 == .account("Create a Workday account at Acme with test@example.com?"), "Workday-style site: asks before creating an account (\(o1.message))")
        try? vault.approve(host: pg.host, company: "Acme", email: p.personal.email)
        check(vault.isApproved(host: pg.host, company: "Acme"), "your approval recorded for this company")
        let o2 = await engine(pg, wd).run(first: false)
        let created = await js(pg, "window.CREATED"), saved = vault.password(host: pg.host)
        check(created["p"]?.string == saved && saved != nil && created["e"]?.string == "test@example.com", "account created with a strong password stored in Keychain")
        let body = (await pg.eval("document.body.innerText") as? String) ?? ""
        check({ if case .prefilled = o2 { return true }; return false }() && body.contains("Submit"), "filled every page and stopped on Review before Submit (\(o2.message))")
        check(await js(pg, "window.SUBMITTED ?? null") == .null, "agent did NOT submit")
        let d = await js(pg, "S.data")
        print("   workday answers:", ["source", "country", "phoneType", "phone-number", "prev", "sponsor", "auth", "agr"].map { "\($0)=\(d[$0]?.string ?? (d[$0] == .bool(true) ? "true" : "-"))" }.joined(separator: " "))
        check(Set([d["sponsor"]?.string, d["auth"]?.string]) == Set(["Yes", "No"]) && d["prev"]?.string == "No" && d["country"]?.string == "United Kingdom"
              && d["phoneType"]?.string == "Mobile", "Workday dropdowns/radios answered from your profile")
        check(d["source"]?.string == "Company Website", "multi-select prompt answered (How did you hear)")
        _ = await pg.eval("document.querySelector('[data-automation-id=\"bottom-navigation-next-button\"]').click()")
        try? await Task.sleep(nanoseconds: 800_000_000)
        let after = (await pg.eval("document.body.innerText") as? String) ?? ""
        check(ApplyController.isConfirmation(body: after, url: pg.url?.absoluteString ?? ""), "after YOUR click, the confirmation page is detected")

        // ---- second visit to the same site signs in with the saved password ----
        let pg2 = page()
        await pg2.load(URL(string: wd.url)!)
        _ = await pg2.eval("S.account = \(String(data: try! JSONEncoder().encode(created), encoding: .utf8)!); true")
        let o3 = await engine(pg2, wd).run(first: true)
        check({ if case .prefilled = o3 { return true }; return false }(), "next application at that company signs in with the saved password (\(o3.message))")

        // ---- simple single-page form (Greenhouse-like) ----
        let simple = Job(company: "Globex", title: "Data Scientist", location: "New York, NY", url: "\(base)/simple.html")
        let pg3 = page()
        await pg3.load(URL(string: simple.url)!)
        let o4 = await engine(pg3, simple).run(first: true)
        let v = await js(pg3, "({fn:fn.value,em:em.value,ph:ph.value,sp:sp.value,why:why.value,cl:cl.value,cv:cv.files.length,pp:pp.checked})")
        print("   simple form:", v)
        check({ if case .prefilled = o4 { return true }; return false }() && v["fn"]?.string == "Test" && v["sp"]?.string == "Yes" && v["cv"]?.double == 1 && v["pp"] == .bool(false),
              "single-page form filled, resume uploaded, consent box left for you (\(o4.message))")
        check(o4.message.contains("tick: I agree to the privacy policy"), "the unticked consent box is listed for you")
        check(v["why"]?.string?.hasPrefix("Because") == true, "custom question answered from the drafted answers")
        check(v["cl"]?.string == "Hello from the cover letter", "cover letter pasted")

        // ---- honeypots and hidden fields are never filled ----
        let pg4 = page()
        await pg4.load(URL(string: "\(base)/honeypot.html")!)
        _ = await engine(pg4, simple).run(first: true)
        let h = await js(pg4, "({fn:fn.value, trap:trap.value, hid:hid.value, em:em.value})")
        check(h["fn"]?.string == "Test" && h["trap"]?.string == "" && h["hid"]?.string == "" && h["em"]?.string == "test@example.com", "honeypot and aria-hidden fields skipped")

        server.stop(); window.close()
        let failed = results.filter { !$0.0 }.count
        print(failed == 0 ? "ALL \(results.count) APPLY CHECKS PASSED" : "\(failed) OF \(results.count) APPLY CHECKS FAILED")
        return failed == 0 ? 0 : 1
    }
}

/// Real-site smoke tests (OFFERLANE_SELFTEST=real): fill real application forms without submitting and without creating
/// accounts. Prints what was filled for each site.
@MainActor
enum RealSiteSmoke {
    static func run(app: AppModel) async -> Int32 {
        var failed = 0
        let kc = Keychain(service: "com.somilmanke.Offerlane.selftest"); defer { kc.deleteAll() }
        let vault = Vault(store: app.store, keychain: kc)
        var p = Profile()
        p.personal.firstName = "Test"; p.personal.lastName = "Person"; p.personal.fullName = "Test Person"; p.personal.email = "test.person.offerlane@example.com"
        p.personal.phone = "+44 7700 900000"; p.personal.city = "London"; p.personal.country = "United Kingdom"; p.personal.linkedin = "https://linkedin.com/in/test"
        p.work.currentCompany = "Acme"; p.work.currentTitle = "Senior Data Scientist"; p.work.yearsExperience = "5"
        p.authorization.authorizedCountries = ["United Kingdom"]; p.authorization.needsSponsorship = true
        var r = ResumeContent(); r.name = "Test Person"; r.email = p.personal.email
        r.experience = [.init(id: "e1", title: "Senior Data Scientist", company: "Acme", bullets: [.init(id: "e1.1", text: "Built forecasting for 1,200 products.")])]
        let pdf = ResumePDF.render(r).0
        let answers = [("Cover letter", "Hello, I'm testing an autofill tool and will not submit this form."), ("Why this company?", "Testing only.")]
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1280, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Offerlane real-site smoke test (nothing is submitted)"; window.orderFrontRegardless()

        func first(_ ats: ATS, _ slug: String, title: String = "") async -> Posting? {
            let list = await ats.list(slug, http: .shared, queries: [title]) ?? []
            return list.first { title.isEmpty || $0.title.lowercased().contains(title.lowercased()) } ?? list.first
        }
        let targets: [(String, ATS, String, String)] = [("Scale AI", .greenhouse, "scaleai", ""), ("Spotify", .lever, "spotify", ""),
                                                       ("Perplexity", .ashby, "perplexity", ""), ("NVIDIA", .workday, "https://nvidia.wd5.myworkdayjobs.com/NVIDIAExternalCareerSite", "data scientist")]
        for (company, ats, slug, title) in targets {
            guard let post = await first(ats, slug, title: title) else { print("FAIL \(company): couldn't fetch a current posting"); failed += 1; continue }
            var j = Job(company: company, title: post.title, location: post.location, url: post.url); j.applyUrl = post.applyUrl; j.ats = ats.rawValue
            j.atsSlug = ats == .workday ? "" : slug
            let pg = WebPage(persistent: false); window.contentView = pg.web
            let url = URL(string: AnswerRules.formURL(j))!
            await pg.load(url)
            let eng = ApplyEngine(page: pg, job: j, profile: p, answers: answers, pdf: (pdf, "Test_Person_Resume.pdf"), vault: vault, pace: 0.3)
            let out = await eng.run(first: true)
            print("SMOKE \(company) [\(ats.rawValue)] \(post.title) → \(out.status.rawValue): \(out.message) | filled=\(eng.filledCount) | \(url.absoluteString)")
            if ats == .workday {
                let ok: Bool = { if case .account = out { return true }; return false }()
                print((ok ? "PASS " : "FAIL ") + "NVIDIA Workday reaches the account question"); if !ok { failed += 1 }
                if ok {
                    let eng2 = ApplyEngine(page: pg, job: j, profile: p, answers: answers, pdf: (pdf, "Test_Person_Resume.pdf"), vault: vault, pace: 0.3)
                    eng2.stopBeforeCreate = true
                    try? vault.approve(host: pg.host, company: company, email: p.personal.email)
                    let o2 = await eng2.run(first: false)
                    let filledForm = o2.message.contains("email true, password true, verify true")
                    print((filledForm ? "PASS " : "FAIL ") + "Workday create-account form filled, stopped before Create (\(o2.message))"); if !filledForm { failed += 1 }
                    try? vault.forget(host: pg.host)
                }
            } else {
                let ok = eng.filledCount >= 4 && out.status != .applied
                print((ok ? "PASS " : "FAIL ") + "\(company) form filled without submitting"); if !ok { failed += 1 }
            }
        }
        window.close()
        print(failed == 0 ? "ALL REAL-SITE SMOKE CHECKS PASSED" : "\(failed) REAL-SITE SMOKE CHECKS FAILED")
        return failed == 0 ? 0 : 1
    }
}

/// Packaged-app check (OFFERLANE_SELFTEST=package): import the v2 folder, Find Jobs live with the real Claude CLI, then tailor
/// the best role with the real AI through LaTeX. Proves the signed, hardened app can run the CLI, tectonic and the network.
@MainActor
enum PackageSelfTest {
    static func run(app: AppModel) async -> Int32 {
        var failed = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); fflush(stdout); if !ok { failed += 1 } }
        do {
            let rep = try LegacyImporter(store: app.store).run(from: LegacyImporter.defaultFolder)
            check(rep.resumes.count == 2, "imported previous-version (v2) data (\(rep.description))")
        } catch { check(false, "import: \(error.localizedDescription)"); return 1 }
        try? await app.store.db.write { try $0.execute(sql: "DELETE FROM job WHERE status != 'declined'") }
        guard let exe = ClaudeCLIClient.locate() else { check(false, "Claude CLI found"); return 1 }
        let ai = AI(client: ClaudeCLIClient(executable: exe), store: app.store)
        let t0 = Date()
        guard let s = try? await FindJobs(store: app.store, ai: ai).run(progress: { _ in }) else { check(false, "Find Jobs ran"); return 1 }
        print("   find: \(Int(Date().timeIntervalSince(t0)))s, \(s.discovery.checked) sites, \(s.discovery.matching) matching, \(s.ranking.scored) scored, \(s.ranking.good) good, errors=\(s.errors)")
        check(s.discovery.matching > 0 && s.ranking.scored > 0 && s.errors.isEmpty, "Find Jobs with the real Claude CLI")
        guard let best = ((try? app.store.jobs([.found])) ?? []).filter({ $0.llmScore != nil }).max(by: { ($0.llmScore ?? 0) < ($1.llmScore ?? 0) }) else { return 1 }
        _ = try? app.store.transition(best.id, to: .tailoring, by: "selftest")
        let t1 = Date()
        do {
            try await Tailor(store: app.store, ai: ai).run(best.id)
            let j = try app.store.job(best.id)!, t = Tailor(store: app.store, ai: ai), ch = t.changes(j), r = try t.review(j)
            print("   tailored \(j.company) – \(j.title) with '\(j.variant)' in \(Int(Date().timeIntervalSince(t1)))s: \(ch?.pages ?? 0) page(s), \(ch?.ats ?? "?"), note=\(ch?.note ?? "none")")
            print("   changes: \(j.changesSummary)")
            print("   rewrites: \(r.groups.flatMap(\.bullets).filter { $0.text != $0.original }.count), guard warnings: \(r.warnings.count)")
            check(j.status == .review && ch?.note == nil && (ch?.ats.hasPrefix("PASS") ?? false), "tailored with the real AI and compiled with the bundled LaTeX")
        } catch { check(false, "tailoring: \(error.localizedDescription)") }
        print(failed == 0 ? "PACKAGE SELF-TEST PASSED" : "PACKAGE SELF-TEST FAILED")
        return failed == 0 ? 0 : 1
    }
}

/// A tiny static file server on 127.0.0.1 for the self-test's mock sites.
final class LocalServer: @unchecked Sendable {
    let listener: NWListener, root: URL
    init(root: URL) throws {
        self.root = root
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [root] c in
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let req = String(decoding: data ?? Data(), as: UTF8.self)
                let path = req.split(separator: " ").dropFirst().first.map { String($0.split(separator: "?").first ?? "") } ?? "/"
                let file = root.appendingPathComponent(String(path.dropFirst()))
                let body = (try? Data(contentsOf: file)) ?? Data("not found".utf8)
                let ok = FileManager.default.fileExists(atPath: file.path)
                let head = "HTTP/1.1 \(ok ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
            }
        }
        listener.start(queue: .global())
    }
    func ready() async -> UInt16 {
        for _ in 0..<50 { if let p = listener.port?.rawValue, p != 0 { return p }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return 0
    }
    func stop() { listener.cancel() }
}
