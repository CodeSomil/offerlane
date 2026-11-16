import Foundation

/// One typical career ladder (Resources/career_paths.json), junior to senior, with adjacent tracks to pivot to.
public struct CareerTrack: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var ladder: [String]
    public var pivots: [String]
    public init(id: String, name: String, ladder: [String], pivots: [String] = []) { self.id = id; self.name = name; self.ladder = ladder; self.pivots = pivots }
}

/// A role on the map, scored against the user's own collected postings (no AI call).
public struct CareerStep: Codable, Hashable, Sendable, Identifiable {
    public var role: String
    public var track: String
    /// 1, 3 or 5 for ladder steps; nil for pivots.
    public var years: Int?
    public var report: GapReport
    public var id: String { role }
    public var topGaps: [GapItem] { Array(report.gaps.prefix(3)) }
}

public struct CareerMap: Codable, Hashable, Sendable {
    public var current: String
    public var track: CareerTrack?
    /// Rung of `current` on `track`; nil when the track was picked by hand (steps start at its first rung).
    public var level: Int?
    public var steps: [CareerStep]
    public var pivots: [CareerStep]
}

public enum CareerPaths {
    public static let bundled: [CareerTrack] = {
        struct File: Decodable { var tracks: [CareerTrack] }
        guard let url = Bundle.module.url(forResource: "Resources/career_paths", withExtension: "json"),
              let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) else { return [] }
        return f.tracks
    }()

    /// Unlike MarketScan.tokens this keeps seniority words: "Senior Data Scientist" and "Data Scientist" are different rungs.
    static func words(_ s: String) -> Set<String> {
        Set(Text.norm(s).split(separator: " ").map(String.init)).subtracting(["of", "and", "the", "for", "a", "an", "in", "at", "to"])
    }

    /// Best-matching rung for a title: most shared words over all words (ties: earlier track wins); needs half the rung's words.
    public static func locate(_ title: String, in tracks: [CareerTrack] = bundled) -> (track: CareerTrack, level: Int)? {
        let have = words(title)
        var best: (CareerTrack, Int, Double)?
        for t in tracks { for (i, rung) in t.ladder.enumerated() {
            let want = words(rung), shared = want.intersection(have).count
            guard !want.isEmpty, shared * 2 >= want.count else { continue }
            let score = Double(shared) / Double(want.union(have).count)
            if score > best?.2 ?? 0 { best = (t, i, score) }
        } }
        return best.map { ($0.0, $0.1) }
    }

    /// 1/3/5-year steps up the ladder (one, two, three rungs; repeats at the top are dropped) and same-level pivots.
    public static func explore(current: String, trackId: String? = nil, store: Store, tracks: [CareerTrack] = bundled) throws -> CareerMap {
        let found = trackId == nil ? locate(current, in: tracks) : nil
        guard let track = found?.track ?? tracks.first(where: { $0.id == trackId }) else { return CareerMap(current: current, track: nil, level: nil, steps: [], pivots: []) }
        let level = found?.level
        let jobs = try store.jobs(), resume = try store.resume()?.content, state: SkillPlanState = try store.get(.skillPlan) ?? SkillPlanState()
        func step(_ role: String, _ t: CareerTrack, _ years: Int?) -> CareerStep {
            CareerStep(role: role, track: t.name, years: years, report: SkillPlanner.report(jobs: jobs, resume: resume, state: state, role: role))
        }
        let from = level ?? -1
        var seen = Set<Int>()
        let steps = zip([1, 3, 5], [1, 2, 3]).compactMap { years, up -> CareerStep? in
            let i = min(from + up, track.ladder.count - 1)
            guard i > from, seen.insert(i).inserted else { return nil }
            return step(track.ladder[i], track, years)
        }
        let pivots = track.pivots.compactMap { id in tracks.first { $0.id == id } }.map { t in step(t.ladder[min(max(from, 0), t.ladder.count - 1)], t, nil) }
        return CareerMap(current: current, track: track, level: level, steps: steps, pivots: pivots)
    }

    /// Makes `role` the goal and the first Skills role (keeping the roles Skills already showed).
    public static func setGoal(_ role: String, years: Int?, search: SearchConfig, store: Store) throws {
        var state: SkillPlanState = try store.get(.skillPlan) ?? SkillPlanState()
        state.roles = [role] + SkillPlanner.roles(state, search).filter { $0 != role }
        state.goal = role; state.goalYears = years
        try store.set(.skillPlan, state)
    }
}
