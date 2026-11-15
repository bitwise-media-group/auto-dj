// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// A phrase as [start, end) with its label.
public struct Segment: Sendable, Equatable {
    public var start: Int
    public var end: Int
    public var label: String
}

/// Cue names (IN, BRIDGE, DROP, OUT, EMERGENCY, plus the BASS_END diagnostic) to beats; a
/// missing name means no such cue.
public typealias Hot = [String: Int]

/// The memory cue placement: START, the DROPs and an optional BASS SWAP (0 = none).
public struct Memory: Sendable, Equatable {
    public var start: Int
    public var drops: [Int]
    public var bassSwap: Int
}

/// The cue-placement rules (port of internal/rules).
///
/// Inputs per track: the Rekordbox beat grid, beat-in-bar numbers, phrase starts, and
/// optional per-beat band energies (without them the rules fall back to phrase labels only,
/// e.g. for streaming tracks). All positions are 1-based beat indices. Everything snaps to the
/// "grid": Rekordbox phrase starts plus every 16 beats from the first downbeat. See
/// docs/decisions/0003-cue-placement-rules.md for the why.
public enum CueRules {
    /// The phrases covering the whole track, and the beat count.
    public static func segments(_ t: Track) -> ([Segment], Int) {
        let nb = t.beats.count
        let segs = t.phrases.enumerated().map { i, p in
            Segment(
                start: p.beat, end: i + 1 < t.phrases.count ? t.phrases[i + 1].beat : nb + 1,
                label: p.label)
        }
        return (segs, nb)
    }

    /// The first beat of the first full bar (np.argmax(bnum == 1) + 1).
    public static func firstDownbeat(_ t: Track) -> Int {
        (t.bnum.firstIndex(of: 1) ?? 0) + 1
    }

    /// The sorted union of the phrase starts and every 16 beats from d1 to nb.
    public static func grid(_ starts: [Int], _ d1: Int, _ nb: Int) -> [Int] {
        var set = Set(starts)
        var b = d1
        while b <= nb {
            set.insert(b)
            b += 16
        }
        return set.sorted()
    }

    /// Python's max(a, b): b only when b > a, so a NaN first argument wins.
    static func pyMax(_ a: Double, _ b: Double) -> Double { b > a ? b : a }

    /// The first element with the smallest key (Python's min(xs, key=...)).
    static func minKey(_ xs: [Int], _ key: (Int) -> Double) -> Int {
        var best = xs[0]
        var bk = key(best)
        for x in xs.dropFirst() {
            let k = key(x)
            if k < bk { (best, bk) = (x, k) }
        }
        return best
    }

    // ---------------------------------------------------------------- hot cues

    /// Places IN, BRIDGE?, DROP?, OUT and EMERGENCY (plus the BASS_END diagnostic).
    public static func hotCues(_ t: Track, _ R: Rules) -> Hot {
        var c = HotCtx(t, R)
        c.placeIn()
        c.placeEmergency()
        var r = c.chooseBridge(c.breakdownRuns())
        if r == nil { r = c.fallbackBridge() }  // a mid-track 'Down' phrase, else the lowest bass
        if let rr = r, rr.1 - rr.0 < R.bridgeMin { r = nil }  // user rule: < 16 beats = no bridge
        c.placeDrop(r)
        c.placeOut()
        c.keepOrder()
        return c.out
    }

    struct HotCtx {
        let R: Rules
        let segs: [Segment]
        let nb: Int
        /// Normalised bass level per beat, nil without audio analysis.
        let lo: [Double]?
        /// Phrase starts.
        let st: [Int]
        let grid: [Int]
        var out: Hot = [:]
        /// EMERGENCY.
        var em = 0
        /// First Chorus.
        var first = 1

        init(_ t: Track, _ R: Rules) {
            self.R = R
            (segs, nb) = segments(t)
            st = segs.map(\.start)
            lo = t.hasFB ? Track.normLevel(t.col(0)) : nil
            grid = CueRules.grid(st, firstDownbeat(t), nb)
            if let s = segs.first(where: { $0.label == "Chorus" }) { first = s.start }
        }

        /// The mean bass over beats [a, b); nil without audio analysis.
        func bass(_ a: Int, _ b: Int) -> Double? {
            guard let lo else { return nil }
            let a = max(a - 1, 0)
            let b = min(b - 1, nb)
            return b > a ? Num.mean(lo[a..<b]) : 0
        }

        func bassV(_ a: Int, _ b: Int) -> Double { bass(a, b) ?? 0 }

        func isStart(_ b: Int) -> Bool { st.contains(b) }

        /// IN: start of the first phrase after Rekordbox's Intro, kept within beats 33..129.
        mutating func placeIn() {
            var introEnd = segs.first(where: { $0.label != "Intro" })?.start ?? 1
            if introEnd > R.inMax || introEnd < R.inMin {
                introEnd = st.first(where: { 33 <= $0 && $0 <= R.inMax }) ?? 33
            }
            out["IN"] = introEnd
        }

        /// EMERGENCY: a 32-beat loop near nb-68, on the grid, with bass throughout, ending before
        /// the bass runs out.
        mutating func placeEmergency() {
            var be = nb
            if let lo {
                be = CueRules.bassEnd(lo, nb, R.bassPresent)
                out["BASS_END"] = be
            }
            let target = nb - R.emBack
            var cands = grid.filter { $0 + 32 <= min(nb - 8, be) && Double($0) > Double(nb) * 0.6 }
            if lo != nil {
                let good = cands.filter { bassV($0, $0 + 32) >= R.bassPresent }
                if !good.isEmpty { cands = good }
            }
            em = nb - 64
            if !cands.isEmpty {
                em = minKey(cands) { b in
                    var k = abs(b - target)
                    if isStart(b) { k -= R.phraseBonus }
                    return Double(k)
                }
            }
            out["EMERGENCY"] = em
        }

        /// The runs of phrases without bass (or Rekordbox 'Down' phrases).
        func breakdownRuns() -> [(Int, Int)] {
            func startsBreak(_ s: Segment) -> Bool {
                if let b = bass(s.start, s.end) { return b < R.bassLow || (s.label == "Down" && b < 0.6) }
                return s.label == "Down"
            }
            func contBreak(_ s: Segment) -> Bool {
                if let b = bass(s.start, s.end) { return b < R.bassCont }
                return s.label == "Down" || s.label == "Up"
            }
            var runs: [(Int, Int)] = []
            var cur = -1  // the run being extended
            for s in segs {
                if s.label == "Intro" || s.label == "Outro" {
                    cur = -1
                    continue
                }
                if cur >= 0, runs[cur].1 == s.start, contBreak(s) {
                    runs[cur].1 = s.end
                } else if startsBreak(s) {
                    runs.append((s.start, s.end))
                    cur = runs.count - 1
                } else {
                    cur = -1
                }
            }
            return runs
        }

        /// The breakdown: after the first chorus, not in the last quarter, followed by a chorus;
        /// the first big one unless a later one is at least twice as long, else the longest.
        func chooseBridge(_ runs: [(Int, Int)]) -> (Int, Int)? {
            var ok: [(Int, Int)] = []
            var big: [(Int, Int)] = []
            for r in runs {
                if r.0 <= first || Double(r.0) > 0.75 * Double(nb) { continue }
                if segs.contains(where: { $0.label == "Chorus" && r.1 <= $0.start && $0.start <= em - 16 }) {
                    ok.append(r)
                    if r.1 - r.0 >= R.bridgeBig { big.append(r) }
                }
            }
            if let r = big.first {
                for b in big.dropFirst() where b.1 - b.0 >= 2 * (r.1 - r.0) { return b }
                return r
            }
            guard var r = ok.first else { return nil }
            for o in ok.dropFirst() where o.1 - o.0 > r.1 - r.0 { r = o }
            return r
        }

        /// A mid-track Rekordbox 'Down' phrase, else the lowest-bass window.
        func fallbackBridge() -> (Int, Int)? {
            let nbf = Double(nb)
            for s in segs
            where s.label == "Down" && 0.25 * nbf <= Double(s.start)
                && Double(s.start) <= min(0.75 * nbf, Double(em - 48)) && s.start > first
            {
                return (s.start, s.end)
            }
            if lo == nil { return nil }
            let cand = st.filter { 0.25 * nbf <= Double($0) && Double($0) <= min(0.7 * nbf, Double(em - 48)) }
            if cand.isEmpty { return nil }
            let b = minKey(cand) { bassV($0, $0 + 32) }
            if bassV(b, b + 16) >= R.bassLow { return nil }
            var r = (b, b + 16)
            while r.1 < nb, bassV(r.1, r.1 + 16) < R.bassCont { r.1 += 16 }
            return r
        }

        /// DROP: with a bridge, the first Chorus after it; without one, the first bass return
        /// after a break past IN, else the first Chorus after IN.
        mutating func placeDrop(_ r: (Int, Int)?) {
            if let r {
                out["BRIDGE"] = r.0
                out["DROP"] = segs.first(where: { $0.start >= r.1 && $0.label == "Chorus" })?.start ?? r.1
                return
            }
            let inB = out["IN"]!
            var ev = segs.filter { $0.label == "Chorus" && $0.start > inB && $0.start <= em - 32 }.map(\.start)
            if lo != nil {
                let evb = grid.filter {
                    inB < $0 && $0 <= em - 32 && bassV($0, $0 + 16) >= R.dropOn && bassV($0 - 16, $0) <= R.bassLow
                }
                if !evb.isEmpty { ev = evb }
            }
            if let d = ev.first { out["DROP"] = d }
        }

        /// OUT: the grid point ~64 beats before EMERGENCY (32..128 allowed) with bass present.
        mutating func placeOut() {
            let cands = grid.filter {
                em - 128 <= $0 && $0 <= em - 32 && (lo == nil || bassV($0, $0 + 16) >= R.bassPresent)
            }
            out["OUT"] = em - 64
            guard var best = cands.first else { return }
            func key(_ b: Int) -> Int {
                var k = abs((em - b) - 64)
                if isStart(b) { k -= R.phraseBonus }
                return k
            }
            for b in cands.dropFirst() {  // min by (key, b)
                let (kb, kc) = (key(b), key(best))
                if kb < kc || (kb == kc && b < best) { best = b }
            }
            out["OUT"] = best
        }

        /// Keeps IN < BRIDGE < DROP < OUT < EMERGENCY on short edits.
        mutating func keepOrder() {
            guard let drop = out["DROP"], out["OUT"]! <= drop else { return }
            if let later = grid.first(where: { drop + 32 <= $0 && $0 <= em - 16 }) {
                out["OUT"] = later
                return
            }
            guard let em2 = grid.first(where: { $0 >= drop + 16 && $0 + 32 <= nb + 1 }) else { return }
            out["EMERGENCY"] = em2
            out["OUT"] = grid.last(where: { drop + 8 <= $0 && $0 <= em2 - 8 }) ?? drop + 8
        }
    }

    /// The last beat whose preceding 16 beats still have bass (searching the second half of
    /// the track), else nb.
    static func bassEnd(_ lo: [Double], _ nb: Int, _ present: Double) -> Int {
        var b = nb
        while b > Int(Double(nb) * 0.5) {
            let hi = min(max(b - 1, 0), lo.count)
            if Num.mean(lo[min(max(0, b - 17), hi)..<hi]) >= present { return b }
            b -= 1
        }
        return nb
    }

    // ---------------------------------------------------------------- memory cues

    /// The mean of arr over beats [a, b) (0 unless b > a >= 1).
    static func mean(_ arr: [Double], _ a: Int, _ b: Int) -> Double {
        if b <= a || a < 1 { return 0 }
        let j = min(max(b - 1, 0), arr.count)
        return Num.mean(arr[min(a - 1, j)..<j])
    }

    /// Places START, the memory DROPs and the BASS SWAP.
    public static func memoryCues(_ t: Track, _ hot: Hot, _ R: Rules) -> Memory {
        let (segs, nb) = segments(t)
        let st = segs.map(\.start)
        let d1 = firstDownbeat(t)
        var res = Memory(start: d1, drops: [], bassSwap: 0)
        let outB = hot["OUT"] ?? nb
        func label(_ b: Int) -> String { segs.first(where: { $0.start <= b && b < $0.end })?.label ?? "" }

        guard t.hasFB else {  // phrase-only fallback: every Chorus that follows a non-Chorus
            var set = Set<Int>()
            for (i, s) in segs.enumerated()
            where s.label == "Chorus" && i > 0 && segs[i - 1].label != "Chorus" && (hot["IN"] ?? 0) < s.start
                && s.start < outB
            {
                set.insert(s.start)
            }
            if let d = hot["DROP"] { set.insert(d) }
            res.drops = set.sorted()
            return res
        }
        let lo = Track.normLevel(t.col(0))
        let lm = Track.normLevel(t.col(1))
        let grid = CueRules.grid(st, d1, nb)

        // bass entries: grid beats (snapped to a phrase start within 4 beats) where the bass comes
        // in hard after 16 quiet beats
        func snap(_ b: Int) -> Int { st.first(where: { abs($0 - b) <= 4 }) ?? b }
        var evSet = Set<Int>()
        for b in grid
        where d1 < b && b <= nb - 32 && mean(lo, b, b + 16) >= R.dropOn && mean(lo, b - 16, b) <= R.dropOff
            && mean(lo, b - 8, b) <= R.dropOff
        {
            evSet.insert(snap(b))
        }
        let ev = evSet.sorted()

        // bass swap: the first bass entry >= 16 beats after IN and before the bridge, else the
        // biggest sub/low-mid jump in that window
        let inB = hot["IN"] ?? 0
        let lim = hot["BRIDGE"] ?? nb / 2
        if let b = ev.first(where: { inB + 16 <= $0 && $0 < lim }) {
            res.bassSwap = b
        } else {
            var bestJ = 0.0
            var bestB = 0
            for b in grid where b >= inB + 16 && b < lim {
                var j = pyMax(mean(lo, b, b + 16) - mean(lo, b - 16, b), mean(lm, b, b + 16) - mean(lm, b - 16, b))
                if st.contains(b) { j += 0.05 }
                if j >= R.bassSwapMin && (bestB == 0 || j > bestJ) { (bestJ, bestB) = (j, b) }
            }
            res.bassSwap = bestB
        }

        // drops: bass entries after a >= 32-beat low-bass stretch, on a Chorus, before OUT, at
        // least 32 beats apart
        func isDrop(_ b: Int) -> Bool {
            mean(lo, b - R.dropPre, b) <= R.dropOff && (label(b) == "Chorus" || !R.dropNeedsChorus)
        }
        let after = res.bassSwap == 0 ? inB : res.bassSwap
        var dr = Set<Int>()
        for b in ev
        where (after < b || (b == after && mean(lo, b - 64, b) <= R.dropOff)) && b < outB && isDrop(b) {
            dr.insert(b)
        }
        if let d = hot["DROP"] { dr.insert(d) }
        for b in dr.sorted() {
            if let l = res.drops.last, b - l < 32 { continue }
            res.drops.append(b)
        }
        return res
    }
}
