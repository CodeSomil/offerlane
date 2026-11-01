import Foundation

/// found → (you approve) tailoring → review → (you approve) ready → applying → [account | needsYou] → prefilled
/// → (you submit) applied → acknowledged | assessment | screen | interview | offer.  Hidden: declined, rejected, withdrawn.
public enum JobStatus: String, Codable, CaseIterable, Sendable {
    case found, tailoring, review, ready, applying, account
    case needsYou = "needs_you"
    case prefilled, applied, acknowledged, assessment, screen, interview, offer
    case declined, rejected, withdrawn

    /// Submitted applications shown on the dashboard.
    public static let tracked: [JobStatus] = [.applied, .acknowledged, .assessment, .screen, .interview, .offer]
    /// Hidden but remembered: fingerprints stay so these never resurface, and they still count in stats.
    public static let hidden: Set<JobStatus> = [.declined, .rejected, .withdrawn]
    /// In the apply pipeline (approved, not yet submitted).
    public static let inFlight: Set<JobStatus> = [.tailoring, .review, .ready, .applying, .account, .needsYou, .prefilled]

    public var isTracked: Bool { JobStatus.tracked.contains(self) }
    public var isHidden: Bool { JobStatus.hidden.contains(self) }

    public var title: String {
        switch self {
        case .found: "New match"
        case .tailoring: "Tailoring"
        case .review: "Review resume"
        case .ready: "Ready to apply"
        case .applying: "Applying"
        case .account: "Account approval"
        case .needsYou: "Needs you"
        case .prefilled: "Ready to submit"
        case .applied: "Applied"
        case .acknowledged: "Acknowledged"
        case .assessment: "Assessment"
        case .screen: "Screen"
        case .interview: "Interview"
        case .offer: "Offer"
        case .declined: "Declined"
        case .rejected: "Rejected"
        case .withdrawn: "Withdrawn"
        }
    }

    /// Statuses from the Python prototype's jobs.json (`dismissed` was renamed `declined`).
    public init?(legacy raw: String) {
        if raw == "dismissed" { self = .declined; return }
        self.init(rawValue: raw)
    }
}

public struct IllegalTransition: LocalizedError, Equatable {
    public let from: JobStatus, to: JobStatus
    public var errorDescription: String? { "A role can't move from \(from.title) to \(to.title)." }
}

/// The only legal moves between statuses. Every status change in the app goes through `check`.
public enum StateMachine {
    static let pipelineExits: Set<JobStatus> = [.declined]
    public static let allowed: [JobStatus: Set<JobStatus>] = {
        let tracked = Set(JobStatus.tracked)
        var m: [JobStatus: Set<JobStatus>] = [
            .found: [.tailoring, .declined],
            // Undo a decline, or approve a previously declined role from "Show removed".
            .declined: [.found, .tailoring],
            // Tailoring finished, or failed and the user gave up on the role.
            .tailoring: [.review, .declined],
            // Approve & Apply, redo with a note / use as-is (back to the queue), or decline.
            .review: [.ready, .tailoring, .declined],
            .ready: [.applying, .review, .declined],
            .applying: [.account, .needsYou, .prefilled, .applied, .ready, .declined],
            // Approve (resume applying), "I'll do it myself" (needs you), "Don't apply".
            .account: [.applying, .needsYou, .declined],
            // Continue resumes from the current page; the user may also finish by hand.
            .needsYou: [.applying, .prefilled, .applied, .declined],
            // The user submits (or the confirmation page is detected), or asks the agent to continue.
            .prefilled: [.applied, .applying, .needsYou, .declined],
            .rejected: tracked.union([.withdrawn]),
            .withdrawn: tracked.union([.rejected]),
        ]
        // Submitted applications: email moves them forward; the Kanban lets the user drag them anywhere on the board.
        for s in JobStatus.tracked { m[s] = tracked.subtracting([s]).union([.rejected, .withdrawn]) }
        return m
    }()

    public static func canMove(_ from: JobStatus, to: JobStatus) -> Bool { allowed[from]?.contains(to) ?? false }

    public static func check(_ from: JobStatus, to: JobStatus) throws {
        guard canMove(from, to: to) else { throw IllegalTransition(from: from, to: to) }
    }
}
