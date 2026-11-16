import Foundation

public struct CoachingReview: Hashable, Sendable {
    public var headline: String
    public var points: [String]
}

/// The weekly coaching review: fixed sentences filled in from analytics counts and pipeline state. No AI call, no invented figures.
public enum Coaching {
    public static func weekly(report r: AnalyticsReport, tracked: [Job], contactsDue: Int, now: Date = Date()) -> CoachingReview {
        let this = r.thisWeek.sent, last = r.lastWeek.sent
        let headline: String
        if r.total.sent == 0 && this == 0 { headline = "No applications yet. One strong, tailored application is a good start this week." }
        else if this == 0 && last == 0 { headline = "Nothing sent in the last two weeks. One application this week restarts the momentum." }
        else if this > last { headline = "More applications than last week: \(this) this week, \(last) last week. Keep the pace." }
        else if this < last { headline = "Fewer applications than last week: \(this) this week, \(last) last week." }
        else { headline = "Steady week: \(this) sent, the same as last week." }

        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var points: [String] = []
        if r.thisWeek.responses > 0 { points.append("\(plural(r.thisWeek.responses, "reply", "replies")) arrived this week. Answer \(r.thisWeek.responses == 1 ? "it" : "them") within a day.") }
        let interviewing = tracked.filter { [.screen, .interview].contains($0.status) }.count
        if interviewing > 0 { points.append("\(plural(interviewing, "role is", "roles are")) at screen or interview. Prepare one STAR story for each.") }
        let quiet = tracked.filter { PipelineHints.isStale($0, now: now) }.count
        if quiet > 0 { points.append("\(plural(quiet, "application has", "applications have")) been quiet for \(PipelineHints.staleDays)+ days. A short follow-up is worth sending.") }
        if contactsDue > 0 { points.append("\(plural(contactsDue, "follow-up", "follow-ups")) with people \(contactsDue == 1 ? "is" : "are") due (Pipeline → People).") }
        let big = r.byVersion.filter { $0.sent >= Analytics.minSample }.sorted { ($0.responseRate, $1.name) > ($1.responseRate, $0.name) }
        if let best = big.first, let worst = big.last, best.responseRate > worst.responseRate {
            points.append("Resume \"\(best.name)\" gets the most replies (\(best.responseRate)% of \(best.sent)). Use it for similar roles.")
        }
        if points.isEmpty { points.append("Nothing urgent. Pick your best new match and tailor it.") }
        return CoachingReview(headline: headline, points: points)
    }
}
