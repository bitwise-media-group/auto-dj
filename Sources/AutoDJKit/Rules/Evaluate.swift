// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// Scores the rules against the user's own hand-placed cues (the 'manual' tracks; port of
/// internal/evaluate).
public enum Evaluate {
    /// Hot cue kinds and the template names they are scored as, in report order.
    public static let names: [(kind: Int, name: String)] = [
        (1, "IN"), (2, "BRIDGE"), (3, "DROP"), (5, "OUT"), (9, "EMERGENCY"),
    ]

    static func nameOf(_ kind: Int) -> String { names.first { $0.kind == kind }?.name ?? "" }

    /// How close the rules came to one hot cue.
    public struct CueScore: Sendable, Equatable {
        public var n = 0
        public var exact = 0
        public var within16 = 0
        public var within32 = 0
        public var missing = 0

        public init(n: Int = 0) { self.n = n }
    }

    /// One track's cue-by-cue comparison (verbose).
    public struct Row: Sendable, Equatable {
        public var title: String
        public var cells: [String]
    }

    /// The evaluation result.
    public struct Report: Sendable, Equatable {
        public var cues: [String: CueScore] = [:]
        public var dropHit = 0
        public var dropMissed = 0
        public var dropExtra = 0
        public var bassSwapN = 0
        public var bassSwapExact = 0
        public var bassSwapWithin16 = 0
        /// With verbose only.
        public var rows: [Row] = []
    }

    /// Runs the rules on every manual track and compares them with the user's cues.
    public static func score(_ ts: [Track], _ R: Rules, verbose: Bool) -> Report {
        var res: [String: [Int?]] = [:]
        var rep = Report()
        var bassSwap: [Int] = []
        var rows: [Row] = []
        for t in ts where t.category == "manual" {
            let hot = CueRules.hotCues(t, R)
            let row = scoreHot(t, hot, &res)
            if t.hasFB, let d = scoreMemory(t, CueRules.memoryCues(t, hot, R), &rep) {
                bassSwap.append(d)
            }
            rows.append(Row(title: t.title, cells: row))
        }
        for n in names { rep.cues[n.name] = summarise(res[n.name] ?? []) }
        rep.bassSwapN = bassSwap.count
        rep.bassSwapExact = bassSwap.filter { $0 == 0 }.count
        rep.bassSwapWithin16 = bassSwap.filter { $0 <= 16 }.count
        if verbose { rep.rows = rows }
        return rep
    }

    /// Records predicted - placed (nil: not predicted) per hot cue and returns the verbose row.
    static func scoreHot(_ t: Track, _ hot: Hot, _ res: inout [String: [Int?]]) -> [String] {
        var row: [String] = []
        for c in t.cues {
            let n = nameOf(c.kind)
            if n.isEmpty || c.name != n { continue }
            let bi = Track.beatOf(t.beats, c.t)
            guard let pr = hot[n] else {
                res[n, default: []].append(nil)
                row.append("\(n):\(bi)/None")
                continue
            }
            res[n, default: []].append(pr - bi)
            row.append("\(n):\(bi)/\(pr)")
        }
        return row
    }

    /// Adds the memory DROP hits, misses and extras to rep, and returns the distance from the
    /// user's nearest BASS SWAP to the predicted one (nil when the user has none).
    static func scoreMemory(_ t: Track, _ mem: Memory, _ rep: inout Report) -> Int? {
        var md = Set<Int>()
        var mbs: [Int] = []
        for c in t.cues where c.kind == 0 {
            if c.name == "DROP" { md.insert(Track.beatOf(t.beats, c.t)) }
            if c.name == "BASS SWAP" { mbs.append(Track.beatOf(t.beats, c.t)) }
        }
        let pd = Set(mem.drops)
        func near(_ a: Int, _ set: Set<Int>) -> Bool { set.contains { abs(a - $0) <= 1 } }
        let hit = md.filter { near($0, pd) }.count
        let extra = pd.filter { !near($0, md) }.count
        rep.dropHit += hit
        rep.dropMissed += md.count - hit
        rep.dropExtra += extra
        if mbs.isEmpty { return nil }
        let p = mem.bassSwap == 0 ? -999 : mem.bassSwap
        return mbs.map { abs($0 - p) }.min()
    }

    static func summarise(_ v: [Int?]) -> CueScore {
        var s = CueScore(n: v.count)
        for x in v {
            guard let x else {
                s.missing += 1
                continue
            }
            if x == 0 { s.exact += 1 }
            if abs(x) <= 16 { s.within16 += 1 }
            if abs(x) <= 32 { s.within32 += 1 }
        }
        return s
    }

    /// The report as the evaluate command prints it.
    public static func format(_ rep: Report) -> String {
        func pad(_ s: Any, _ n: Int, left: Bool = false) -> String {
            left ? Text.padRight("\(s)", n) : Text.padLeft("\(s)", n)
        }
        var out = [
            [pad("cue", 12, left: true), pad("n", 3), pad("exact", 6), pad("<=16", 6), pad("<=32", 6), pad("none", 5)]
                .joined(separator: " ")
        ]
        for n in names {
            let r = rep.cues[n.name] ?? CueScore()
            out.append(
                [
                    pad(n.name, 12, left: true), pad(r.n, 3), pad(r.exact, 6), pad(r.within16, 6), pad(r.within32, 6),
                    pad(r.missing, 5),
                ]
                .joined(separator: " "))
        }
        out.append("memory DROP  hit \(rep.dropHit)  missed \(rep.dropMissed)  extra \(rep.dropExtra)")
        out.append("BASS SWAP    n \(rep.bassSwapN)  exact \(rep.bassSwapExact)  <=16 \(rep.bassSwapWithin16)")
        for r in rep.rows {
            out.append("  " + Text.padRight(Text.truncate(r.title, 34), 34) + " " + r.cells.joined(separator: " "))
        }
        return out.joined(separator: "\n")
    }
}
