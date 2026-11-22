// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// Builds a set around a few picked tracks (ADR 0021): fills the gaps between them with tracks
/// from a pool, by key, tempo, vocal overlap and an energy arc.
public enum SetBuilder {
    /// The energy shape of a set.
    public enum Arc: String, Sendable, CaseIterable, Codable {
        /// Low to high.
        case build
        /// Up to a peak about two thirds in, then halfway back down.
        case peak
        /// No arc: energy only keeps neighbours within a star of each other.
        case flat

        /// The arc at x (0 = first track, 1 = last) between lo and hi, nil for flat.
        public func at(_ x: Double, lo: Double, hi: Double) -> Double? {
            switch self {
            case .build: return lo + (hi - lo) * x
            case .peak:
                let top = 0.65
                return x <= top ? lo + (hi - lo) * x / top : hi - (hi - lo) * 0.5 * (x - top) / (1 - top)
            case .flat: return nil
            }
        }
    }

    public struct Options: Sendable {
        /// The picked tracks (content IDs).
        public var picks: [String]
        /// Tracks in the set, picks included.
        public var length: Int
        public var arc: Arc = .peak
        /// Keep the picks in the given order; otherwise they're placed along the arc by energy.
        public var keepOrder = false
        /// The first pick opens the set / the last pick closes it (no tracks before / after).
        public var opener = false
        public var closer = false
        /// The set tempo; nil = the picks' median BPM.
        public var bpm: Double?
        /// How far a track's tempo may be from the set tempo (half and double time count).
        public var tempoRange = 0.06
        /// Only these tracks may be added (a playlist); nil = the whole library.
        public var pool: Set<String>?
        /// Tracks never added.
        public var exclude: Set<String> = []

        public init(picks: [String], length: Int) {
            (self.picks, self.length) = (picks, length)
        }
    }

    /// One track of a built set.
    public struct Slot: Sendable, Equatable {
        public var id: String
        public var title: String
        public var key: String
        public var bpm: Double
        public var energy: Energy.Level?
        /// The arc's energy at this position (nil for a flat arc).
        public var target: Double?
        /// Picked (or locked) by the DJ rather than chosen.
        public var anchor: Bool
        /// The key move and transition into this track (nil for the first).
        public var keyMove: Keys.Move?
        public var fit: SetPlanner.Fit?
    }

    public struct Result: Sendable {
        public var slots: [Slot]
        public var bpm: Double
        /// The pool's size (tracks that could be added).
        public var pool: Int

        public var order: [PlaylistTrack] {
            slots.enumerated().map { PlaylistTrack(no: $0 + 1, id: $1.id, title: $1.title, bpm: $1.bpm, key: $1.key) }
        }
        public var clashes: Int { slots.filter { $0.keyMove?.ok == false }.count }
        /// Transitions with 2 bars or more of vocal overlap / finishing in the last 16 bars.
        public var vocalOverlaps: Int { slots.filter { ($0.fit?.vocalBeats ?? 0) >= 8 }.count }
        public var lateEndings: Int { slots.filter { $0.fit?.late == true }.count }
    }

    public struct BuildError: Error, CustomStringConvertible {
        public let description: String
    }

    // ---------------------------------------------------------------- weights

    /// Per star between a track's energy and the arc.
    static let energyWeight = 2.0
    /// Per star a neighbour's energy differs beyond one.
    static let jumpWeight = 2.0
    /// Per BPM a track is stretched from the set tempo, and per BPM between neighbours.
    static let stretchWeight = 0.1
    static let tempoStepWeight = 0.02
    /// Beam width, and the candidates per beam state checked with the real transition plan.
    static let beamWidth = 32
    static let checked = 6

    // ---------------------------------------------------------------- building

    /// Places the picks and fills the rest of the set. recs: every track by ID (the pool is
    /// those with audio analysis and a beat grid).
    public static func build(_ o: Options, _ recs: [String: Track], _ cache: TransitionCache) throws -> Result {
        let picks = try o.picks.map { id in
            guard let t = recs[id] else { throw BuildError(description: "track \(id) has no Rekordbox analysis") }
            return t
        }
        if picks.isEmpty { throw BuildError(description: "pick at least one track") }
        if Set(o.picks).count != o.picks.count { throw BuildError(description: "a track is picked twice") }
        if o.length < picks.count {
            throw BuildError(description: "the set is shorter (\(o.length)) than the picks (\(picks.count))")
        }
        let bpm = o.bpm ?? median(picks.map(\.bpm).filter { $0 > 0 })
        var ctx = Context(recs: recs, cache: cache, bpm: bpm, tempoRange: o.tempoRange)
        ctx.pool = recs.values.filter { t in
            !o.exclude.contains(t.id) && !o.picks.contains(t.id) && (o.pool?.contains(t.id) ?? true)
                && usable(t) && ctx.effBPM(t) != nil
        }.sorted { $0.id < $1.id }
        let (lo, hi) = range(ctx.pool + picks)
        ctx.arc = { x in o.arc.at(x, lo: lo, hi: hi) }

        let positions = pickPositions(n: picks.count, length: o.length, opener: o.opener, closer: o.closer)
        var placed = picks
        if !o.keepOrder, o.arc != .flat {
            // rank matching: the lowest-energy pick at the lowest point of the arc, and so on
            let n = o.length
            let targets = positions.map { o.arc.at(n > 1 ? Double($0) / Double(n - 1) : 0, lo: lo, hi: hi)! }
            let byTarget = positions.indices.sorted { targets[$0] < targets[$1] }
            let byEnergy = picks.indices.sorted {
                (Energy.level(picks[$0])?.stars ?? 0) < (Energy.level(picks[$1])?.stars ?? 0)
            }
            for (slot, p) in zip(byTarget, byEnergy) { placed[slot] = picks[p] }
        }
        var anchors: [Int: Track] = [:]
        for (p, t) in zip(positions, placed) { anchors[p] = t }
        return ctx.fill(anchors: anchors, length: o.length)
    }

    /// Fills every position of a set of `length` tracks that isn't anchored (a draft with some
    /// tracks locked, or one slot re-rolled). exclude: tracks never added.
    public static func refill(
        anchors: [Int: String], length: Int, bpm: Double, arc: Arc, pool: Set<String>?, exclude: Set<String>,
        tempoRange: Double = 0.06, _ recs: [String: Track], _ cache: TransitionCache
    ) -> Result {
        var ctx = Context(recs: recs, cache: cache, bpm: bpm, tempoRange: tempoRange)
        let fixed = anchors.compactMapValues { recs[$0] }
        let ids = Set(anchors.values)
        ctx.pool = recs.values.filter { t in
            !exclude.contains(t.id) && !ids.contains(t.id) && (pool?.contains(t.id) ?? true) && usable(t)
                && ctx.effBPM(t) != nil
        }.sorted { $0.id < $1.id }
        let (lo, hi) = range(ctx.pool + Array(fixed.values))
        ctx.arc = { x in arc.at(x, lo: lo, hi: hi) }
        return ctx.fill(anchors: fixed, length: length)
    }

    /// Where n picks sit in a set of length tracks: spread evenly, with as many tracks before
    /// the first (unless it opens) and after the last (unless it closes) as between them.
    static func pickPositions(n: Int, length: Int, opener: Bool, closer: Bool) -> [Int] {
        let gaps = (n - 1) + (opener ? 0 : 1) + (closer ? 0 : 1)
        let extra = length - n
        if gaps == 0 { return Array(0..<n) }
        // extra tracks per gap: as even as possible, the larger gaps first
        let sizes = (0..<gaps).map { extra / gaps + ($0 < extra % gaps ? 1 : 0) }
        var out: [Int] = []
        var pos = 0
        var g = 0
        if !opener {
            pos += sizes[0]
            g = 1
        }
        for i in 0..<n {
            out.append(pos)
            pos += 1
            if i < n - 1 {
                pos += sizes[g]
                g += 1
            }
        }
        return out
    }

    /// A track the builder can add: it has audio analysis, vocals and a beat grid.
    static func usable(_ t: Track) -> Bool {
        t.local && t.fb != nil && t.vocals != nil && t.beats.count > 64 && t.bpm > 0
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 128 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The arc's range: the 10th to 90th percentile of the energies, at least a star wide.
    static func range(_ ts: [Track]) -> (Double, Double) {
        let es = ts.compactMap { Energy.level($0)?.stars }
        guard !es.isEmpty else { return (2.5, 3.5) }
        var lo = Num.percentile(es, 10)
        var hi = Num.percentile(es, 90)
        if hi - lo < 1 {
            let mid = (hi + lo) / 2
            (lo, hi) = (mid - 0.5, mid + 0.5)
        }
        return (lo, hi)
    }

    // ---------------------------------------------------------------- search

    struct Context {
        let recs: [String: Track]
        let cache: TransitionCache
        let bpm: Double
        let tempoRange: Double
        var pool: [Track] = []
        var arc: (Double) -> Double? = { _ in nil }
        /// Transition plans by "a b" (the real check is the slow part).
        var fits: [String: SetPlanner.Fit] = [:]
        var vox: [String: Vox] = [:]
        var stems: [String: String] = [:]
        /// Key moves by "from|to" (parsing a key is slow, and the search asks a lot).
        var moves: [String: Keys.Move] = [:]

        init(recs: [String: Track], cache: TransitionCache, bpm: Double, tempoRange: Double) {
            (self.recs, self.cache, self.bpm, self.tempoRange) = (recs, cache, bpm, tempoRange)
        }

        /// t's BPM as played in the set (itself, doubled or halved: whichever is nearest the set
        /// tempo), nil when that is further than tempoRange.
        func effBPM(_ t: Track) -> Double? {
            let b = [t.bpm, t.bpm * 2, t.bpm / 2].min { abs($0 - bpm) < abs($1 - bpm) }!
            return abs(b / bpm - 1) <= tempoRange + 1e-9 ? b : nil
        }

        /// What a track costs at position i of n, apart from its neighbours.
        func nodeCost(_ t: Track, _ i: Int, _ n: Int) -> Double {
            var c = stretchWeight * abs((effBPM(t) ?? t.bpm) - bpm)
            if let target = arc(n > 1 ? Double(i) / Double(n - 1) : 0), let e = Energy.level(t) {
                c += energyWeight * abs(e.stars - target)
            }
            return c
        }

        mutating func move(_ a: String, _ b: String) -> Keys.Move {
            let k = a + "|" + b
            if let m = moves[k] { return m }
            let m = Keys.move(a, b)
            moves[k] = m
            return m
        }

        /// What a -> b costs without the transition's vocals: key, tempo step and energy jump.
        mutating func edgeBase(_ a: Track, _ b: Track) -> Double {
            var c = Double(move(a.key, b.key).cost)
            c += tempoStepWeight * abs((effBPM(a) ?? a.bpm) - (effBPM(b) ?? b.bpm))
            if let ea = Energy.level(a), let eb = Energy.level(b) {
                c += jumpWeight * max(0, abs(ea.stars - eb.stars) - 1)
            }
            return c
        }

        /// The vocals a transition is likely to overlap, without planning it: the least vocal
        /// 48 beats of a's outro (from OUT back up to 8 phrases) against b's 48 after IN.
        mutating func proxy(_ a: Track, _ b: Track) -> Double {
            let va = vox(a)
            let vb = vox(b)
            return 2 * 48 * va.out * vb.in
        }

        struct Vox {
            var out: Double
            var `in`: Double
        }

        mutating func vox(_ t: Track) -> Vox {
            if let v = vox[t.id] { return v }
            let hot = Dictionary(t.cues.filter { $0.kind > 0 }.map { ($0.kind, $0) }, uniquingKeysWith: { _, b in b })
            lazy var rules = CueRules.hotCues(t, .default)
            let outB = hot[Config.kind["D"]!].map { Track.beatOf(t.beats, $0.t) } ?? rules["OUT"] ?? t.beats.count
            let inB = hot[Config.kind["A"]!].map { Track.beatOf(t.beats, $0.t) } ?? rules["IN"] ?? 1
            func frac(_ s: Int) -> Double {
                let r = max(s, 1)..<min(s + 48, t.beats.count + 1)
                return r.isEmpty ? 0 : Double(r.filter { SetPlanner.vocal(t, $0) }.count) / Double(r.count)
            }
            var out = 1.0
            for k in 0...SetPlanner.movePhrases {
                let g = outB - SetPlanner.phrase * k
                if g < t.beats.count / 2 && k > 0 { break }
                out = min(out, frac(g))
            }
            let v = Vox(out: out, in: frac(inB))
            vox[t.id] = v
            return v
        }

        /// Plans the transitions of pairs that aren't planned yet, across the cores.
        mutating func prefetch(_ pairs: [(Track, Track)]) {
            var seen = Set<String>()
            let todo = pairs.filter { a, b in
                let k = a.id + " " + b.id
                return fits[k] == nil && seen.insert(k).inserted
            }
            if todo.isEmpty { return }
            let out = Results(todo.count)
            let cache = self.cache
            DispatchQueue.concurrentPerform(iterations: todo.count) { i in
                out.set(i, SetPlanner.fit(todo[i].0, todo[i].1, cache))
            }
            for (i, (a, b)) in todo.enumerated() { fits[a.id + " " + b.id] = out.get(i) }
        }

        /// Slots the parallel plans write into.
        final class Results: @unchecked Sendable {
            private var xs: [SetPlanner.Fit?]
            private let lock = NSLock()
            init(_ n: Int) { xs = Array(repeating: nil, count: n) }
            func set(_ i: Int, _ f: SetPlanner.Fit) { lock.withLock { xs[i] = f } }
            func get(_ i: Int) -> SetPlanner.Fit? { lock.withLock { xs[i] } }
        }

        /// t's title without mix names (two mixes of one song never both go in a set).
        mutating func stem(_ t: Track) -> String {
            if let s = stems[t.id] { return s }
            let s = Track.titleStem(t.title)
            stems[t.id] = s
            return s
        }

        /// The transition a -> b as `set` would plan it.
        mutating func fit(_ a: Track, _ b: Track) -> SetPlanner.Fit {
            let k = a.id + " " + b.id
            if let f = fits[k] { return f }
            let f = SetPlanner.fit(a, b, cache)
            fits[k] = f
            return f
        }

        struct State {
            var seq: [Track]
            var cost: Double
        }

        /// Fills the positions between anchors, gap by gap.
        mutating func fill(anchors: [Int: Track], length n: Int) -> Result {
            var set = [Track?](repeating: nil, count: n)
            for (p, t) in anchors where p >= 0 && p < n { set[p] = t }
            var used = Set(anchors.values.map(\.id))
            var stems = Set(anchors.values.map { stem($0) })
            var i = 0
            while i < n {
                if set[i] != nil {
                    i += 1
                    continue
                }
                var j = i
                while j < n && set[j] == nil { j += 1 }
                let prev = i > 0 ? set[i - 1] : nil
                let next = j < n ? set[j] : nil
                let seq = gap(prev: prev, next: next, positions: Array(i..<j), n: n, used: used, stems: stems)
                for (k, t) in seq.enumerated() {
                    set[i + k] = t
                    used.insert(t.id)
                    stems.insert(stem(t))
                }
                i = j
            }
            let ts = set.compactMap { $0 }
            var slots: [Slot] = []
            for (k, t) in ts.enumerated() {
                var s = Slot(
                    id: t.id, title: t.title, key: t.key, bpm: t.bpm, energy: Energy.level(t),
                    target: arc(n > 1 ? Double(k) / Double(n - 1) : 0),
                    anchor: anchors.values.contains { $0.id == t.id })
                if k > 0 {
                    s.keyMove = move(ts[k - 1].key, t.key)
                    s.fit = fit(ts[k - 1], t)
                }
                slots.append(s)
            }
            return Result(slots: slots, bpm: bpm, pool: pool.count)
        }

        /// The cheapest tracks for one gap, by beam search: each step keeps the best sequences
        /// (one per last track), checking the most promising candidates with the real plan.
        mutating func gap(prev: Track?, next: Track?, positions: [Int], n: Int, used: Set<String>, stems: Set<String>)
            -> [Track]
        {
            let cands = pool.filter { !used.contains($0.id) && !stems.contains(stem($0)) }
            if cands.isEmpty { return [] }
            var beam = [State(seq: [], cost: 0)]
            for (step, pos) in positions.enumerated() {
                let final = step == positions.count - 1
                // the most promising candidates of every beam state, by the cheap estimate
                var shortlist: [(State, Track?, [(Track, Double)])] = []
                for s in beam {
                    let last = s.seq.last ?? prev
                    let taken = Set(s.seq.map(\.id))
                    let takenStems = Set(s.seq.map { stem($0) })
                    var scored: [(Track, Double)] = []
                    for c in cands where !taken.contains(c.id) && !takenStems.contains(stem(c)) {
                        var v = nodeCost(c, pos, n)
                        if let last { v += edgeBase(last, c) + proxy(last, c) }
                        if final, let next { v += edgeBase(c, next) + proxy(c, next) }
                        scored.append((c, v))
                    }
                    scored.sort { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0.id < $1.0.id) }
                    shortlist.append((s, last, Array(scored.prefix(checked))))
                }
                // their transitions planned for real, in parallel
                var pairs: [(Track, Track)] = []
                for (_, last, cs) in shortlist {
                    for (c, _) in cs {
                        if let last { pairs.append((last, c)) }
                        if final, let next { pairs.append((c, next)) }
                    }
                }
                prefetch(pairs)
                var best: [String: State] = [:]
                for (s, last, cs) in shortlist {
                    for (c, approx) in cs {
                        var v = approx
                        if let last { v += fit(last, c).cost - proxy(last, c) }
                        if final, let next { v += fit(c, next).cost - proxy(c, next) }
                        let st = State(seq: s.seq + [c], cost: s.cost + v)
                        if let cur = best[c.id], cur.cost <= st.cost { continue }
                        best[c.id] = st
                    }
                }
                if best.isEmpty { break }
                beam = Array(
                    best.values.sorted {
                        $0.cost < $1.cost || ($0.cost == $1.cost && $0.seq.last!.id < $1.seq.last!.id)
                    }
                    .prefix(beamWidth))
            }
            return beam.first?.seq ?? []
        }
    }

    // ---------------------------------------------------------------- report

    /// The set list: position, energy (yours, or ~Mixed In Key's) against the arc, key and the
    /// move into it, BPM, title, and the transition's vocal overlap or late ending.
    public static func report(_ r: Result) -> [String] {
        var lines = [
            "Set of \(r.slots.count) tracks at \(SetsFormat.bpm(r.bpm)) BPM, from a pool of \(r.pool) "
                + "(* = picked; energy: yours, ~ Mixed In Key's, arc target in brackets):"
        ]
        for (i, s) in r.slots.enumerated() {
            let e = s.energy?.label ?? "?"
            let tgt = s.target.map { String(format: "(%.1f)", $0) } ?? ""
            var notes: [String] = []
            if let m = s.keyMove, !m.ok || m.cost > 0 { notes.append(m.desc) }
            if let f = s.fit {
                if f.vocalBeats >= 8 { notes.append("vocals overlap \(f.vocalBeats / 4) bars") }
                if f.late { notes.append("ends in the last 16 bars") }
                if !f.aligned { notes.append("not phrase-aligned") }
            }
            lines.append(
                "\(Text.padLeft(String(i + 1), 3))\(s.anchor ? "*" : " ") \(Text.padRight(e, 4)) "
                    + "\(Text.padRight(tgt, 5)) \(Text.padLeft(s.key.isEmpty ? "?" : s.key, 4)) "
                    + "\(Text.padLeft(SetsFormat.bpm(s.bpm), 6))  \(s.title)"
                    + (notes.isEmpty ? "" : "  [" + notes.joined(separator: "; ") + "]"))
        }
        lines.append(
            "\(r.clashes) key clash(es), \(r.vocalOverlaps) vocal overlap(s), \(r.lateEndings) transition(s) ending in "
                + "the last 16 bars")
        return lines
    }
}

/// Number formats for set reports.
enum SetsFormat {
    static func bpm(_ b: Double) -> String { b == b.rounded() ? String(Int(b)) : String(format: "%.1f", b) }
}

extension SetPlanner {
    /// How a transition a -> b works out as `set` plans it (ADR 0020, 0023): beats of vocal
    /// overlap, where a leaves the mix (`endingCost`; late = in its last 16 bars), whether it
    /// lines up on the phrase.
    public struct Fit: Sendable, Equatable {
        public var vocalBeats: Int
        public var late: Bool
        public var ending: Double
        public var aligned: Bool

        /// The planner's own cost (2 per overlapping beat, the ending's), plus 24 when the
        /// phrases don't line up.
        public var cost: Double { 2 * Double(vocalBeats) + ending + (aligned ? 0 : 24) }
    }

    /// Plans E and G for a -> b alone and reports how it works out.
    public static func fit(_ a: Track, _ b: Track, _ cache: TransitionCache) -> Fit {
        let x = PlaylistTrack(no: 1, id: a.id, title: a.title, bpm: a.bpm, key: a.key)
        let y = PlaylistTrack(no: 2, id: b.id, title: b.title, bpm: b.bpm, key: b.key)
        var out = [SetAction(id: a.id, title: a.title), SetAction(id: b.id, title: b.title)]
        var tr = Transition(i: 0, x: x, nxt: y, t: a, u: b, cached: cache.get(a.id, b.id) ?? TransitionCache.Entry())
        tr.chooseG(&out)
        tr.chooseE(&out)
        tr.moveG()
        let end = leaveBeat(a, tr.g, b, tr.e, swap: tr.swapAt(tr.g, tr.e))
        return Fit(
            vocalBeats: vocalOverlap(a, tr.g, b, tr.e, until: end).beats, late: end > lastAudioBeat(a) - lateBeats,
            ending: endingCost(a, end), aligned: tr.al.phraseAligned || tr.al.endsOnPhrase)
    }
}
