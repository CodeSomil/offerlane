import Foundation

/// Times the first-run setup so the "under 5 minutes" stranger test can be measured. Local only: the summary is
/// step names and whole seconds, written to the app's own log, never sent anywhere.
public struct SetupTimer {
    public struct Summary {
        public let steps: [(name: String, seconds: Int)]
        public let total: Int
        public var underFiveMinutes: Bool { total < 300 }
        public var line: String {
            let parts = steps.map { "\($0.name) \($0.seconds)s" } + ["total \(total)s"]
            return "setup timer: \(parts.joined(separator: ", ")) (under 5 min: \(underFiveMinutes ? "yes" : "no"))"
        }
    }

    private var started: Date?
    private var current: (name: String, since: Date)?
    private var order: [String] = []
    private var spent: [String: TimeInterval] = [:]

    public init() {}

    public mutating func start(at now: Date = Date()) {
        started = now; current = nil; order = []; spent = [:]
    }

    /// Records a step change; re-entering a step (after Back) keeps adding to its total.
    public mutating func enter(_ step: String, at now: Date = Date()) {
        guard started != nil else { return }
        close(at: now)
        if !order.contains(step) { order.append(step) }
        current = (step, now)
    }

    /// One summary per start; nil when the timer never started (e.g. a step opened from Settings).
    public mutating func finish(at now: Date = Date()) -> Summary? {
        guard let s = started else { return nil }
        close(at: now)
        started = nil; current = nil
        return Summary(steps: order.map { ($0, Int(spent[$0] ?? 0)) }, total: Int(now.timeIntervalSince(s)))
    }

    private mutating func close(at now: Date) {
        guard let c = current else { return }
        spent[c.name, default: 0] += max(0, now.timeIntervalSince(c.since))
    }
}
