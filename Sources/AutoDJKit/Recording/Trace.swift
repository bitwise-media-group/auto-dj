// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

// Port of internal/mixalign/trace.go.
extension MixAlign.Aligner {
    /// A place a probe may have played: where it starts in the recording (s), the implied
    /// offset (s) and its correlation.
    struct Candidate {
        var pos: Double
        var off: Double
        var score: Double
    }

    /// Path states: before the track is heard, a probe heard at a candidate, a probe not heard
    /// in between (it carries the offset it came from), after the track has gone.
    enum Kind { case lead, real, mid, trail }

    final class State {
        let kind: Kind
        let off: Double
        let pos: Double
        /// The path has been on the global fit.
        let seen: Bool
        /// The candidate's correlation (real).
        let match: Double
        let score: Double
        let prev: State?

        init(
            _ kind: Kind, off: Double = 0, pos: Double = 0, seen: Bool = false, match: Double = 0, score: Double = 0,
            prev: State? = nil
        ) {
            (self.kind, self.off, self.pos, self.seen, self.match, self.score, self.prev) =
                (kind, off, pos, seen, match, score, prev)
        }
    }

    /// The trace's scores: before / after the track (tau), not heard in between (tauMid), and
    /// the global fit's offset the path must pass through.
    struct PathScores {
        var tau: Double
        var tauMid: Double
        var global: Double

        func jump(_ o: Double, _ off: Double) -> Double { abs(o - off) > A.continuous ? -A.jumpPenalty : 0 }

        /// The next probe's states from the previous probe's and its candidates: the best path
        /// to each (kind, offset, seen).
        func step(_ prev: [State], _ cands: [Candidate]) -> [State] {
            var layer: [State] = []
            func put(_ s: State) {
                if let i = layer.firstIndex(where: {
                    $0.kind == s.kind && $0.seen == s.seen && abs($0.off - s.off) <= A.continuous / 2
                }) {
                    if s.score > layer[i].score { layer[i] = s }
                } else {
                    layer.append(s)
                }
            }
            for ps in prev {
                switch ps.kind {
                case .lead: put(State(.lead, score: ps.score + tau, prev: ps))
                case .real, .mid:
                    put(State(.mid, off: ps.off, pos: ps.pos, seen: ps.seen, score: ps.score + tauMid, prev: ps))
                case .trail: break
                }
                put(State(.trail, seen: ps.seen, score: ps.score + tau, prev: ps))
            }
            for c in cands {
                for ps in prev {
                    var gain = 0.0
                    switch ps.kind {
                    case .trail: continue
                    case .real:
                        if c.pos <= ps.pos { continue }
                        gain = jump(ps.off, c.off)
                    case .mid: gain = jump(ps.off, c.off)
                    case .lead: break
                    }
                    put(
                        State(
                            .real, off: c.off, pos: c.pos, seen: ps.seen || abs(c.off - global) <= 2 * A.continuous,
                            match: c.score, score: ps.score + gain + c.score, prev: ps))
                }
            }
            return layer
        }
    }

    /// Follows the track through the recording: a probe every `traceBeats` beats (8 s without
    /// a grid) is matched within `localSec` of the global fit, keeping its best few candidates,
    /// then a path through them (Viterbi) collects the most correlation while paying
    /// `jumpPenalty` for every change of offset. The path must pass through the global fit, or
    /// it may wander off on a bar-shifted lookalike. Probes before the track is heard and after
    /// it has gone score a fixed 0.85 x notFound; a probe nobody can hear in between (a
    /// breakdown, a mashup, a fader down) scores 0.55 x notFound and keeps the offset it came
    /// with. Straight runs of the path become pieces; the first reaches back to the track's
    /// start and the last on to its end.
    func trace(_ t: A.Item) {
        let g = t.global!
        let starts = traceStarts(t)
        let p = PathScores(tau: A.notFound * 0.85, tauMid: A.notFound * 0.55, global: g.offset)
        var layers: [[State]] = []
        var prev = [State(.lead)]
        for s in starts {
            prev = p.step(prev, candidates(t, s, g))
            layers.append(prev)
        }
        var end: State?
        for s in prev {
            if let e = end {
                if (s.seen && !e.seen) || (s.seen == e.seen && s.score > e.score) { end = s }
            } else {
                end = s
            }
        }
        var path = [State?](repeating: nil, count: layers.count)
        var s = end
        var k = layers.count - 1
        while k >= 0, let st = s {
            path[k] = st
            s = st.prev
            k -= 1
        }
        piecesOf(t, starts, path)
    }

    /// The trace's probe starts (track frames).
    func traceStarts(_ t: A.Item) -> [Int] {
        let n = t.env[0].count
        if let r = t.input.rec, !r.beats.isEmpty {
            return stride(from: 1, through: r.beats.count, by: A.traceBeats).compactMap { b in
                let s = Int((r.beats[b - 1] * A.fps).rounded())
                return s + m <= n ? s : nil
            }
        }
        return Array(stride(from: 0, through: n - m, by: m))
    }

    /// The best few places (at least a quarter second apart) the probe starting at track frame
    /// p plays within `localSec` of where the global fit puts it.
    func candidates(_ t: A.Item, _ p: Int, _ g: A.Fit) -> [Candidate] {
        let keep = 16
        let mm = Int(Double(m) / g.r)
        let x0 = max(0, Int((g.rec(Double(p) / A.fps) - A.localSec) * A.fps))
        let x1 = min(env[0].count, Int((g.rec(Double(p) / A.fps) + A.localSec) * A.fps) + mm)
        if x1 - x0 < mm + 1 { return [] }
        var avg: [Double] = []
        var q = [Double](repeating: 0, count: mm)
        for (k, ch) in env.enumerated() {
            for j in 0..<mm { q[j] = Signal.at(t.env[k], Double(p) + Double(j) * g.r) ?? 0 }
            if !Signal.normalise(&q) { continue }
            let x = Correlator(Array(ch[x0..<x1])).ncc(q)
            if avg.isEmpty { avg = [Double](repeating: 0, count: x.count) }
            for L in x.indices { avg[L] += x[L] / Double(env.count) }
        }
        var peaks: [(L: Int, v: Double)] = []
        for L in avg.indices
        where (L == 0 || avg[L] >= avg[L - 1]) && (L == avg.count - 1 || avg[L] > avg[L + 1]) && avg[L] > 0 {
            peaks.append((L, avg[L]))
        }
        peaks = stableSorted(peaks) { $0.v > $1.v }
        let sep = Double(Int((0.25 * A.fps).rounded()))
        var out: [Candidate] = []
        for pk in peaks {
            if out.count == keep { break }
            let pos = Double(x0 + pk.L) / A.fps
            if out.contains(where: { abs($0.pos - pos) * A.fps < sep }) { continue }
            out.append(Candidate(pos: pos, off: pos - Double(p) / A.fps / g.r, score: pk.v))
        }
        return out
    }

    /// Turns the traced path into pieces, each refitted on its own probes.
    func piecesOf(_ t: A.Item, _ starts: [Int], _ path: [State?]) {
        let g = t.global!
        final class Run {
            var off: Double
            var probes: [A.Probe] = []
            var from: Double
            var match = 0.0
            init(off: Double, from: Double) { (self.off, self.from) = (off, from) }
        }
        var runs: [Run] = []
        var heard = 0
        for (k, s) in path.enumerated() {
            guard let s, s.kind == .real else { continue }
            heard += 1
            let p = starts[k]
            if runs.isEmpty || abs(runs[runs.count - 1].off - s.off) > A.continuous {
                runs.append(Run(off: s.off, from: s.pos))
            }
            let r = runs[runs.count - 1]
            r.probes.append(t.probeAt(p, m))
            r.match += s.match
        }
        t.heard = runs.filter { $0.match / Double($0.probes.count) >= A.runScore }.map(\.probes.count).max() ?? 0
        if !starts.isEmpty {
            t.entry.matched = (Double(heard) / Double(starts.count) * 1e3).rounded() / 1e3
        }
        if runs.isEmpty {
            t.pieces = [A.Piece(fit: g, from: -.infinity)]
            return
        }
        t.pieces = []
        for (i, r) in runs.enumerated() {
            let pc = Double(r.probes.reduce(0) { $0 + $1.start }) / Double(r.probes.count)
            let f = refine(r.probes, pc, r.off + pc / A.fps / g.r, g.r)
            var from = r.from
            if i == 0 {
                from = -.infinity
            } else {
                let prev = t.pieces[i - 1].fit
                if abs(prev.track(from) - f.track(from)) > 0.5 {  // a change of tempo also starts a piece
                    t.entry.notes.append(
                        "jumps at \(A.formatTime(from)) from \(A.formatTime(prev.track(from))) to "
                            + "\(A.formatTime(f.track(from))) of the track (a loop or hot cue)")
                }
            }
            t.pieces.append(A.Piece(fit: f, from: from))
        }
    }
}
