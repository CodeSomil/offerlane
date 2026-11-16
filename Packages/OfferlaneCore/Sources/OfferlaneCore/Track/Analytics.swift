import Foundation

/// Reply and interview rates for one slice of submitted applications (a resume version, a source or a role type).
public struct AnalyticsGroup: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var sent = 0, responses = 0, interviews = 0
    public var responseRate: Int { Analytics.percent(responses, sent) }
    public var interviewRate: Int { Analytics.percent(interviews, sent) }
}

public struct AnalyticsReport: Hashable, Sendable {
    public var total = AnalyticsGroup(name: "All")
    public var byVersion: [AnalyticsGroup] = [], bySource: [AnalyticsGroup] = [], byRole: [AnalyticsGroup] = []
    /// Rolling 7-day windows: sent = submitted in the window, replies = first reply arrived in the window.
    public var thisWeek = AnalyticsGroup(name: "This week"), lastWeek = AnalyticsGroup(name: "Last week")
    /// Plain sentences built only from the counts above. No AI.
    public var insights: [String] = []
    public init() {}
}

/// Application analytics, computed locally from job rows and their status history.
public enum Analytics {
    /// A slice needs this many applications before it's compared with others.
    public static let minSample = 3
    /// Any real employer reply. An automatic acknowledgment isn't one; withdrawing is the user's own move.
    static let reply: Set<JobStatus> = [.assessment, .screen, .interview, .offer, .rejected]
    static let interview: Set<JobStatus> = [.screen, .interview, .offer]
    /// Submitted applications. Rejected/withdrawn can only follow a submitted status (StateMachine).
    static let submitted: Set<JobStatus> = Set(JobStatus.tracked).union([.rejected, .withdrawn])

    static func percent(_ n: Int, _ d: Int) -> Int { d == 0 ? 0 : Int((Double(n) * 100 / Double(d)).rounded()) }

    public static func report(store: Store, now: Date = Date()) throws -> AnalyticsReport {
        let labels = Dictionary(try store.resumeVersions().map { ($0.name, $0.label) }, uniquingKeysWith: { a, _ in a })
        return report(jobs: try store.jobs(Array(submitted)), events: try store.events(limit: 1_000_000), labels: labels, now: now)
    }

    /// `labels`: resume version name → display label.
    public static func report(jobs: [Job], events: [JobEvent], labels: [String: String] = [:], now: Date = Date()) -> AnalyticsReport {
        let byJob = Dictionary(grouping: events, by: \.jobId)
        let cal = Calendar(identifier: .gregorian)
        let weekAgo = cal.date(byAdding: .day, value: -7, to: now)!, twoWeeksAgo = cal.date(byAdding: .day, value: -14, to: now)!
        var r = AnalyticsReport()
        var version: [String: AnalyticsGroup] = [:], source: [String: AnalyticsGroup] = [:], role: [String: AnalyticsGroup] = [:]

        for j in jobs where submitted.contains(j.status) {
            let evs = (byJob[j.id] ?? []).sorted { $0.ts < $1.ts }
            let reached = Set(evs.compactMap { JobStatus(rawValue: $0.status) }).union([j.status])
            let replied = !reached.isDisjoint(with: reply), interviewed = !reached.isDisjoint(with: interview)
            func add(_ g: inout AnalyticsGroup) { g.sent += 1; if replied { g.responses += 1 }; if interviewed { g.interviews += 1 } }
            add(&r.total)
            let v = j.variant.isEmpty ? "Unknown" : labels[j.variant] ?? j.variant
            add(&version[v, default: AnalyticsGroup(name: v)])
            add(&source[sourceName(j.source), default: AnalyticsGroup(name: sourceName(j.source))])
            let t = CareerPaths.locate(j.title)?.track.name ?? "Other"
            add(&role[t, default: AnalyticsGroup(name: t)])

            let sentAt = Dates.parse(evs.first { $0.status == JobStatus.applied.rawValue }?.ts ?? j.updated)
            let replyAt = Dates.parse(evs.first { JobStatus(rawValue: $0.status).map(reply.contains) ?? false }?.ts)
            if let d = sentAt { if d > weekAgo { r.thisWeek.sent += 1 } else if d > twoWeeksAgo { r.lastWeek.sent += 1 } }
            if let d = replyAt { if d > weekAgo { r.thisWeek.responses += 1 } else if d > twoWeeksAgo { r.lastWeek.responses += 1 } }
        }
        let sorted = { (m: [String: AnalyticsGroup]) in m.values.sorted { ($0.sent, $1.name) > ($1.sent, $0.name) } }
        r.byVersion = sorted(version); r.bySource = sorted(source); r.byRole = sorted(role)
        r.insights = insights(r)
        return r
    }

    /// "ats:greenhouse" → "Greenhouse", "api:remotive" → "Remotive", "" → "Unknown".
    static func sourceName(_ s: String) -> String {
        let name = s.split(separator: ":").last.map(String.init) ?? ""
        return name.isEmpty ? "Unknown" : name.prefix(1).uppercased() + name.dropFirst()
    }

    static func insights(_ r: AnalyticsReport) -> [String] {
        guard r.total.sent > 0 else { return [] }
        var out = ["This week: \(r.thisWeek.sent) sent, \(r.thisWeek.responses) replies (last week: \(r.lastWeek.sent) sent, \(r.lastWeek.responses) replies).",
                   "Overall: \(r.total.responseRate)% reply rate and \(r.total.interviewRate)% interview rate across \(r.total.sent) applications."]
        var compared = false
        for (kind, groups) in [("Resume version", r.byVersion), ("Source", r.bySource), ("Role type", r.byRole)] {
            let big = groups.filter { $0.sent >= minSample }.sorted { ($0.responseRate, $1.name) > ($1.responseRate, $0.name) }
            guard let best = big.first, let worst = big.last, best.responseRate > worst.responseRate else { continue }
            compared = true
            out.append("\(kind) \"\(best.name)\" gets replies most often: \(best.responseRate)% of \(best.sent) (vs \(worst.responseRate)% of \(worst.sent) for \"\(worst.name)\").")
        }
        if !compared { out.append("Too few to compare yet: send at least \(minSample) applications per resume version, source or role type.") }
        return out
    }
}

extension Dates {
    /// An ISO timestamp ("2026-11-10T09:30:00") or day ("2026-11-10").
    static func parse(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        return isoSeconds.date(from: String(iso.prefix(19))) ?? day(iso)
    }
}
