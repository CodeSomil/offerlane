import Foundation

/// Pipeline card hints (v4): how old a card is, whether it has gone quiet, and one template next step. No AI call.
public enum PipelineHints {
    /// Days with no reply before an application counts as quiet and earns a follow-up nudge.
    public static let staleDays = 14

    public static func age(_ job: Job, now: Date = Date()) -> Int {
        // Calendar days, not 24-hour blocks: a clock change must not make a card read a day short.
        max(0, Dates.ageDays(job.updated, now: now))
    }

    /// Waiting on the employer for `staleDays` or more.
    public static func isStale(_ job: Job, now: Date = Date()) -> Bool {
        [.applied, .acknowledged].contains(job.status) && age(job, now: now) >= staleDays
    }

    public static func nextStep(_ job: Job, now: Date = Date()) -> String {
        let days = age(job, now: now)
        switch job.status {
        case .applied, .acknowledged:
            return isStale(job, now: now) ? "Send a short follow-up" : days < 7 ? "Nothing to do yet" : "Wait; replies usually come in 7–10 days"
        case .assessment: return "Complete the assessment"
        case .screen, .interview: return "Prepare your STAR stories"
        case .offer: return "Compare offers"
        default: return "Open it to see what's next"
        }
    }
}
