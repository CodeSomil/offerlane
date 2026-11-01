import Foundation
import OfferlaneCore

/// Fills an application at a human pace and stops before Submit. Ported from browser.py (fill, wd_dropdowns, workday, generic).
@MainActor
final class ApplyEngine {
    enum Outcome: Equatable {
        case applied(String), prefilled(String), account(String), needsYou(String)
        var status: JobStatus {
            switch self { case .applied: .applied; case .prefilled: .prefilled; case .account: .account; case .needsYou: .needsYou }
        }
        var message: String { switch self { case .applied(let m), .prefilled(let m), .account(let m), .needsYou(let m): m } }
    }

    let page: WebPage, job: Job, profile: Profile, answers: [(String, String)], pdf: (data: Data, name: String)?, vault: Vault
    let pace: Double
    /// Looks for a verification link from the career site (IMAP), if email tracking is on.
    let verificationLink: (String) async -> String?
    var approved = false
    /// Smoke tests on real sites: fill the create-account form, then stop before clicking Create (no real account).
    var stopBeforeCreate = false
    private(set) var filledCount = 0

    init(page: WebPage, job: Job, profile: Profile, answers: [(String, String)], pdf: (Data, String)?, vault: Vault, pace: Double = 1,
         verificationLink: @escaping (String) async -> String? = { _ in nil }) {
        self.page = page; self.job = job; self.profile = profile; self.answers = answers; self.pdf = pdf.map { (data: $0.0, name: $0.1) }
        self.vault = vault; self.pace = pace; self.verificationLink = verificationLink
    }

    func pause(_ a: Double = 0.35, _ b: Double = 0.9) async { try? await Task.sleep(nanoseconds: UInt64(Double.random(in: a...b) * pace * 1e9)) }
    func settle(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * max(pace, 0.15) * 1e9)); await page.waitForLoad() }

    var email: String { profile.personal.email }
    func rules(_ consent: Bool) -> [AnswerRules.Rule] {
        AnswerRules.rules(profile, jobLocation: job.location, consent: consent, visa: Visa(profile: profile))
    }

    // MARK: fill one page

    func fill(consent: Bool, withPDF: Bool = true) async -> (filled: [(String, String)], need: [String]) {
        let R = rules(consent)
        var filled: [(String, String)] = [], need: [String] = [], done = Set<String>()
        let fields = await page.fields()
        let files = fields.filter { $0.type == "file" }
        func blob(_ f: FormField) -> String { "\(f.label) \(f.name) \(f.flabel)" }
        let named = files.filter { Re.search("resume|cv\\b", blob($0)) && !blob($0).lowercased().contains("cover") }
        for f in fields {
            if Task.isCancelled { break }
            if f.type == "file" {
                let target = !named.isEmpty ? named.contains(f) : (f == files.first && !blob(f).lowercased().contains("cover"))
                if withPDF, let pdf, target, f.value.isEmpty {
                    if await page.bool("upload", [f.i, pdf.data.base64EncodedString(), pdf.name, "application/pdf"]) { filled.append(("Resume upload", pdf.name)) }
                    else if f.required { need.append("resume upload") }
                } else if f.required && f.value.isEmpty { need.append(f.flabel.isEmpty ? (f.label.isEmpty ? "file upload" : f.label) : f.flabel) }
                continue
            }
            let (v, L) = AnswerRules.want(f, R, answers)
            if f.type == "radio" || f.type == "checkbox" {
                let key = L.isEmpty ? f.name : L
                if done.contains(key) || f.checked { done.insert(key); continue }
                if f.type == "checkbox" && Re.search(AnswerRules.consentRx, L + " " + f.label) {
                    if consent { await page.bool("click", [f.i]); done.insert(key); filled.append((String(L.prefix(60)), "ticked (approved)")) }
                    else if f.required { need.append("tick: " + String((f.label.isEmpty ? L : f.label).prefix(70))) }
                    continue
                }
                if let v, AnswerRules.pick([f.label], v) != nil { await page.bool("click", [f.i]); done.insert(key); filled.append((L, f.label)) }
                continue
            }
            guard f.value.isEmpty, let v else { if f.value.isEmpty && f.required { need.append(L) }; continue }
            if f.type == "select" {
                if let o = AnswerRules.pick(f.options ?? [], v) { if await page.bool("select", [f.i, o]) { filled.append((L, o)) } }
                else if f.required { need.append(L) }
            } else if f.role == "combobox" {
                let first = String((v.split(separator: ",").first.map(String.init) ?? v).prefix(60))
                await page.bool("comboType", [f.i, first]); filled.append((L, first))
            } else {
                await page.bool("type", [f.i, v]); filled.append((L, String(v.prefix(60))))
            }
        }
        if case .array(let names) = await page.call("requiredRadioNames") { need += names.compactMap(\.string).map { "choose an option: \($0)" } }
        var seen = Set<String>()
        return (filled, need.filter { !$0.isEmpty && seen.insert($0).inserted })
    }

    /// Workday's custom list boxes and multi-select prompts. Re-query after every pick: Workday re-renders.
    func workdayControls(consent: Bool) async -> (filled: Int, need: [String]) {
        let R = rules(consent); var filled = 0, need: [String] = [], done = Set<String>()
        for _ in 0..<30 {
            guard case .array(let boxes) = await page.call("listboxes") else { break }
            let target = boxes.first { b in
                let L = b["label"]?.string ?? "", cur = b["current"]?.string ?? ""
                return !done.contains(L) && (cur.isEmpty || Re.search("^select", cur))
            }
            guard let b = target, let k = b["k"]?.double else { break }
            let L = b["label"]?.string ?? ""; var req = false; if case .bool(true) = b["required"] ?? .null { req = true }
            done.insert(L)
            let (v, _) = AnswerRules.want(FormField(type: "select", label: L), R, answers)
            guard let v else { if req { need.append(L) }; continue }
            let opts = (await page.call("openListbox", [Int(k)])).array?.compactMap(\.string) ?? []
            if let o = AnswerRules.pick(opts, v), await page.bool("chooseOption", [o]) { filled += 1 }
            else { await page.call("escape"); if req { need.append(L) } }
        }
        if case .array(let boxes) = await page.call("searchBoxes") {
            for b in boxes {
                if case .bool(true) = b["selected"] ?? .null { continue }
                guard let k = b["k"]?.double else { continue }
                let (v, _) = AnswerRules.want(FormField(type: "select", label: b["label"]?.string ?? "source"), R, answers)
                if let v, await page.bool("promptPick", [Int(k), String(v.prefix(30))]) { filled += 1 }
            }
        }
        return (filled, need)
    }

    // MARK: Workday (multi-page, per-company account)

    static func isWorkday(_ url: String) -> Bool { Re.search("myworkdayjobs\\.com|myworkday(site)?\\.com|wd\\d+\\.myworkday", url) }

    func workday() async -> Outcome {
        let host = page.host
        var last: String?, stuck = 0, uploaded = false, stuckSince: Date?
        let start = Date()
        for _ in 0..<60 {
            if Task.isCancelled { return .needsYou("Paused. Press Continue to carry on.") }
            await page.waitForLoad(); await pause(1.2, 2.2)
            let body = await page.string("text")
            if Re.search(AnswerRules.humanRx, body) { return .needsYou("The site is asking to verify you're human. Complete it here, then press Continue.") }
            if Re.search(AnswerRules.doneRx, body) { return .applied("Application submitted") }
            if await page.bool("visible", ["applyFlowLoadingPage"]) { continue }
            // Workday is a single-page app: right after "load" nothing is rendered yet. Give it time before judging the page.
            let rendered = (await page.call("count", ["[data-automation-id]"])).double ?? 0
            if rendered == 0 && Date().timeIntervalSince(start) < 15 { try? await Task.sleep(nanoseconds: 700_000_000); continue }
            var dialog = false
            for id in ["autofillWithResume", "applyManually"] where await page.bool("visible", [id]) {
                await page.bool("clickAid", [id]); await settle(3); dialog = true; break
            }
            if dialog { continue }
            if await page.bool("visible", ["adventureButton"]), !(await page.bool("exists", ["applyFlowPage"])) {
                await page.bool("clickAid", ["adventureButton"]); await settle(2); continue
            }
            let pwVisible = await page.bool("anyVisible", ["input[type=password]"])
            let signIn = await page.bool("visible", ["signInContent"]), createLink = await page.bool("visible", ["createAccountLink"])
            if pwVisible || signIn || createLink {
                let creating = await page.bool("visible", ["verifyPassword"])
                let saved = vault.password(host: host)
                if saved == nil && !approved { return .account("Create a Workday account at \(job.company) with \(email)?") }
                if await page.bool("visible", ["SignInWithEmailButton"]), !(await page.bool("visible", ["email"])) {
                    await page.bool("clickAid", ["SignInWithEmailButton"]); continue
                }
                if let saved, !creating {
                    let acct = (try? vault.store.account(host: host))?.email ?? email
                    await page.bool("typeAid", ["email", acct.isEmpty ? email : acct]); await page.bool("typeAid", ["password", saved])
                    let via = await page.bool("visible", ["click_filter"]) ? "click_filter" : "signInSubmitButton"
                    await page.bool("clickAid", [via]); await settle(3.5)
                    if await page.bool("visible", ["password"]), Re.search("invalid|incorrect|wrong|locked", await page.string("text")) {
                        return .needsYou("Sign-in failed with the saved password. Sign in (or reset it) here, then press Continue.")
                    }
                    continue
                }
                if !approved { return .account("Create a Workday account at \(job.company) with \(email)?") }
                if !creating {
                    if await page.bool("visible", ["createAccountLink"]) { await page.bool("clickAid", ["createAccountLink"]); continue }
                    return .needsYou("Couldn't find Workday's “Create Account” option. Create an account or sign in here, then press Continue.")
                }
                let pw = Keychain.strongPassword()
                if stopBeforeCreate {
                    let e = await page.bool("typeAid", ["email", email]), a = await page.bool("typeAid", ["password", pw]), b = await page.bool("typeAid", ["verifyPassword", pw])
                    return .needsYou("Dry run: create-account form filled (email \(e), password \(a), verify \(b)); stopped before Create.")
                }
                do { try vault.save(host: host, company: job.company, email: email, password: pw) }   // saved BEFORE clicking Create
                catch { return .needsYou("Couldn't save the new password to your Keychain (\(error.localizedDescription)). Create the account yourself, then press Continue.") }
                await page.bool("typeAid", ["email", email]); await page.bool("typeAid", ["password", pw]); await page.bool("typeAid", ["verifyPassword", pw])
                if await page.bool("visible", ["createAccountCheckbox"]), !(await page.bool("checked", ["createAccountCheckbox"])) { await page.bool("clickAid", ["createAccountCheckbox"]) }
                let via = await page.bool("visible", ["click_filter"]) ? "click_filter" : "createAccountSubmitButton"
                await page.bool("clickAid", [via]); await settle(4)
                Log.info("workday account created at \(host) (password in Keychain)")
                if Re.search(AnswerRules.verifyRx, await page.string("text")) {
                    if let link = await verificationLink(job.company), let u = URL(string: link) {
                        let back = page.url; await page.load(u); await settle(3); if let back { await page.load(back) }
                    } else { return .needsYou("Workday sent a verification email to \(email). Click the link in it, then press Continue.") }
                }
                continue
            }
            if let pdf, !uploaded, await page.bool("exists", ["file-upload-input-ref"]) {
                if !(await page.bool("anyVisible", ["[data-automation-id=\"file-upload-successful\"],[data-automation-id=\"file-upload-item\"]"])) {
                    await page.bool("uploadAid", ["file-upload-input-ref", pdf.data.base64EncodedString(), pdf.name, "application/pdf"]); await settle(2)
                }
                uploaded = true
            }
            let (f1, n1) = await fill(consent: approved)
            let (f2, n2) = await workdayControls(consent: approved)
            filledCount += f1.count + f2
            let need = n1 + n2
            var nextID: String?
            for id in ["bottom-navigation-next-button", "pageFooterNextButton"] where await page.bool("visible", [id]) { nextID = id; break }
            let hasStep = await page.bool("exists", ["progressBarActiveStep"])
            let step = hasStep ? await page.string("aidText", ["progressBarActiveStep"]) : (page.url?.absoluteString ?? "")
            guard let nextID else {
                stuck += 1; if stuckSince == nil { stuckSince = Date() }
                if stuck > 3 && Date().timeIntervalSince(stuckSince!) > 10 { return .needsYou("Offerlane isn't sure what to do on this page. Take a look, then press Continue.") }
                try? await Task.sleep(nanoseconds: 800_000_000)
                continue
            }
            stuck = 0; stuckSince = nil
            if Re.search("submit", await page.string("aidText", [nextID])) {
                return .prefilled("Filled \(filledCount) fields across all pages. Check the Review page, then click Submit.")
            }
            let errs = (await page.call("errors")).array?.compactMap(\.string) ?? []
            if step == last && (!errs.isEmpty || !need.isEmpty) { return .needsYou("Please complete: " + (errs + need).prefix(6).joined(separator: "; ") + ", then press Continue.") }
            last = step
            await page.bool("clickAid", [nextID]); await settle(1)
        }
        return .needsYou("This application has more pages than expected. Please finish it here.")
    }

    // MARK: everything else (Greenhouse, Lever, Ashby, SmartRecruiters, company sites)

    static let nextRx = "^(next|continue|save and continue|save & continue|proceed|next step)$"
    static let submitRx = "^(submit( application)?|send application|apply now|finish)$"

    func generic(first: Bool) async -> Outcome {
        let host = page.host; var total = 0, lastURL: String?
        for loop in 0..<14 {
            if Task.isCancelled { return .needsYou("Paused. Press Continue to carry on.") }
            await page.waitForLoad(); await pause(1.0, 1.8)
            let body = await page.string("text")
            if Re.search(AnswerRules.humanRx, body) { return .needsYou("The site is asking to verify you're human. Complete it here, then press Continue.") }
            if loop > 0 && Re.search(AnswerRules.doneRx, body) { return .applied("Application submitted") }
            let hasInputs = await page.bool("hasFormInputs")
            if first && loop == 0 && !hasInputs {
                for name in ["Apply for this job", "Apply now", "Apply", "I'm interested", "Apply for this position"] {
                    if await page.bool("clickMatching", ["^\(Re.escape(name))$", true]) { await settle(2.5); break }
                }
                continue
            }
            let pwCount = Int((await page.call("count", ["input[type=password]"])).double ?? 0)
            if await page.bool("anyVisible", ["input[type=password]"]), !(await page.bool("anyVisible", ["input[type=file]"])) {
                if let saved = vault.password(host: host) {
                    let acct = (try? vault.store.account(host: host))?.email ?? email
                    await page.bool("typeSel", ["input[type=email],input[name*=mail i],input[id*=mail i],input[name*=user i]", acct])
                    await page.bool("typeAllPasswords", [saved, 1])
                    await page.bool("clickMatching", ["sign in|log ?in|continue", false]); await settle(3.5)
                    if await page.bool("anyVisible", ["input[type=password]"]) { return .needsYou("Sign-in didn't go through. Please sign in here, then press Continue.") }
                    continue
                }
                if !approved { return .account("\(job.company)'s career site needs an account. Create one with \(email)?") }
                if pwCount == 1, await page.bool("hasMatching", ["create (an )?account|sign up|register|new user", true]) {
                    await page.bool("clickMatching", ["create (an )?account|sign up|register|new user", true]); await settle(2.5); continue
                }
                if pwCount >= 2 {
                    let p = Keychain.strongPassword()
                    do { try vault.save(host: host, company: job.company, email: email, password: p) } catch { return .needsYou("Couldn't save the password to Keychain.") }
                    await page.bool("typeSel", ["input[type=email],input[name*=mail i],input[id*=mail i]", email])
                    await page.bool("typeAllPasswords", [p, 2])
                    _ = await fill(consent: true, withPDF: false)
                    await page.bool("clickMatching", ["create|sign up|register|continue|submit", false]); await settle(4)
                    if Re.search(AnswerRules.verifyRx, await page.string("text")) { return .needsYou("\(job.company) sent a verification email to \(email). Open it, then press Continue.") }
                    continue
                }
                return .needsYou("This site needs you to sign in or register. Do it here, then press Continue.")
            }
            let (f, need) = await fill(consent: approved); total += f.count; filledCount += f.count
            let buttons = (await page.call("buttons")).array ?? []
            let names = buttons.map { $0["name"]?.string ?? "" }
            let next = buttons.first { Re.search(Self.nextRx, $0["name"]?.string ?? "") }
            let hasSubmit = names.contains { Re.search(Self.submitRx, $0) } || buttons.contains { if case .bool(true) = $0["submit"] ?? .null { return true }; return false }
            if let next, !hasSubmit, let k = next["k"]?.double {
                let u = page.url?.absoluteString
                if !need.isEmpty && u == lastURL { return .needsYou("Please complete: " + need.prefix(6).joined(separator: "; ") + ", then press Continue.") }
                lastURL = u; await page.bool("clickButton", [Int(k)]); await settle(2.5); continue
            }
            return .prefilled("Filled \(total) fields." + (need.isEmpty ? "" : " Still needed: \(need.prefix(6).joined(separator: "; ")).") + " Check the form, then click Submit.")
        }
        return .needsYou("This application has more steps than expected. Please finish it here.")
    }

    func run(first: Bool) async -> Outcome {
        approved = vault.isApproved(host: page.host, company: job.company)
        if pace < 1 { await page.call("setPace", [pace]) }
        let wdHooks = await page.bool("anyVisible", ["[data-automation-id=\"adventureButton\"],[data-automation-id=\"signInContent\"],[data-automation-id=\"progressBarActiveStep\"]"])
        let wd = Self.isWorkday(page.url?.absoluteString ?? "") || wdHooks
        let out = wd ? await workday() : await generic(first: first)
        let banner: String
        switch out {
        case .prefilled: banner = "<b>Offerlane</b> filled this application for <b>\(job.company)</b>. Review everything, then click <b>Submit</b> yourself."
        default: banner = "<b>Offerlane</b> is working on this application for <b>\(job.company)</b>. \(out.message)"
        }
        await page.call("banner", [banner])
        return out
    }
}
