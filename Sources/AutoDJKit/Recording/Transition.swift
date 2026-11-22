// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

// Port of internal/mixalign/transition.go.
extension MixAlign.Item {
    /// Track series x as heard through the track's path, over recording frames [f0, f0+n): 0
    /// where the track has no audio.
    func mapped(_ x: [Double], _ f0: Int, _ n: Int) -> [Double] {
        (0..<n).map { i in
            let rec = Double(f0 + i) / MixAlign.fps
            return Signal.at(x, fitAt(rec).track(rec) * MixAlign.fps) ?? 0
        }
    }
}

extension MixAlign {
    /// Solves rec ≈ a·A + b·B with a, b >= 0 by least squares over a centred window of w frames
    /// at every frame (B may be nil: a alone).
    static func gains(_ rec: [Double], _ A: [Double], _ Bin: [Double]?, _ w: Int) -> ([Double], [Double]) {
        let n = rec.count
        let B = Bin ?? [Double](repeating: 0, count: n)
        func prod(_ x: [Double], _ y: [Double]) -> [Double] { Signal.prefix((0..<n).map { x[$0] * y[$0] }) }
        let aa = prod(A, A)
        let bb = prod(B, B)
        let ab = prod(A, B)
        let ar = prod(A, rec)
        let br = prod(B, rec)
        var ga = [Double](repeating: 0, count: n)
        var gb = ga
        let h = max(w / 2, 1)
        for i in 0..<n {
            let lo = max(i - h, 0)
            let hi = min(i + h + 1, n)
            func s(_ p: [Double]) -> Double { p[hi] - p[lo] }
            var saa = s(aa)
            var sbb = s(bb)
            let sab = s(ab)
            let sar = s(ar)
            let sbr = s(br)
            let ridge = 1e-6 * (saa + sbb)
            saa += ridge + 1e-12
            sbb += ridge + 1e-12
            let det = saa * sbb - sab * sab
            var a = (sbb * sar - sab * sbr) / det
            var b = (saa * sbr - sab * sar) / det
            if a < 0 || b < 0 {  // one of them alone: the better fit of the two
                let a1 = max(sar / saa, 0)
                let b1 = max(sbr / sbb, 0)
                if a1 * sar >= b1 * sbr { (a, b) = (a1, 0) } else { (a, b) = (0, b1) }
            }
            ga[i] = a
            gb[i] = b
        }
        return (ga, gb)
    }

    /// The first index i in [lo, hi) where ok holds for every index up to i+w (clipped to
    /// hi), or nil.
    static func sustained(_ lo: Int, _ hi: Int, _ w: Int, _ ok: (Int) -> Bool) -> Int? {
        if hi <= lo { return nil }
        var run = [Int](repeating: 0, count: hi - lo + 1)  // how many indices from i on hold ok
        for i in stride(from: hi - 1, through: lo, by: -1) where ok(i) { run[i - lo] = run[i - lo + 1] + 1 }
        for i in lo..<hi where run[i - lo] > 0 && run[i - lo] >= min(w, hi - i) { return i }
        return nil
    }

    /// n beats of t at its playing tempo, in frames (4 s per 8 beats without a grid).
    static func beatFrames(_ t: Item, _ f: Fit, _ n: Double) -> Int {
        let bpm = t.bpm
        if bpm <= 0 { return Int(n / 2 * fps) }
        return Int(n * 60 / (bpm * f.r) * fps)
    }

    /// The incoming track's nearest phrase start to beat b within [b+lo, b+hi] (the earlier on
    /// a tie), or 0.
    static func snapPhrase(_ t: Track, _ b: Int, _ lo: Int, _ hi: Int) -> Int {
        var best = 0
        if max(1, b + lo) <= min(t.beats.count, b + hi) {
            for x in max(1, b + lo)...min(t.beats.count, b + hi)
            where SetPlanner.onPhrase(t, x) && (best == 0 || abs(x - b) < abs(best - b)) {
                best = x
            }
        }
        return best
    }

    /// A cue as the report names it: "C DROP" for a hot cue, "mem DROP" for a memory cue.
    static func cueName(_ c: Cue) -> String {
        let slot = Config.kind.first { $0.value == c.kind && $0.value > 0 }?.key ?? "mem"
        return (slot + " " + c.name).trimmingCharacters(in: .whitespaces)
    }

    /// t's hot cue nearest beat g, as "<cue> +n beats", and whether it is within `snapBeats`.
    static func nearHotCue(_ t: Track, _ g: Int) -> (String, Bool) {
        var best = snapBeats + 1
        var name = ""
        for c in t.cues where c.kind != 0 {
            let d = g - Track.beatOf(t.beats, c.t)
            if abs(d) < abs(best) || (abs(d) == abs(best) && d > best) {
                best = d
                name = "\(cueName(c)) \(d >= 0 ? "+" : "")\(d) beats"
            }
        }
        return (name, abs(best) <= snapBeats)
    }

    /// The transition as played. E: where B started, at or before it became audible (the
    /// fader may come up much later). A DJ starts the incoming track on one of its cues,
    /// usually within a phrase of one of the outgoing track's hot cues: the latest of B's cues
    /// up to `cueBeats` before it was heard that falls that close to one of A's hot cues; else
    /// its latest cue up to a phrase before; else a phrase start. G is A's beat at that same
    /// moment, BASS SWAP the cut's beat (else the takeover's).
    static func played(_ A: Item, _ B: Item, _ swap: Int, _ takeover: Double) -> Transition {
        let ar = A.input.rec!
        let br = B.input.rec!
        let heard = Track.beatOf(br.beats, B.fitAt(B.start).track(B.start))
        func gAt(_ eb: Int) -> Int {
            let te = B.fitAt(B.start).rec(br.beats[eb - 1])
            return Track.beatOf(ar.beats, A.fitAt(te).track(te))
        }
        var tr = Transition(fromID: A.input.id, fromTitle: A.input.title)
        var cueAt = 0
        for c in br.cues {
            let cb = Track.beatOf(br.beats, c.t)
            if cb > heard + SetPlanner.phrase / 4 || cb < heard - cueBeats || cb < 1 { continue }
            let (name, near) = nearHotCue(ar, gAt(cb))
            if near && (tr.gCue == nil || cb > tr.e) {
                (tr.e, tr.eCue, tr.gCue) = (cb, cueName(c), name)
            } else if tr.gCue == nil && cb <= heard && cb >= heard - snapBeats && cb > cueAt {
                (cueAt, tr.eCue) = (cb, cueName(c))
            }
        }
        if tr.gCue != nil {
        } else if cueAt > 0 {
            tr.e = cueAt
        } else {
            tr.e = heard
            tr.eCue = nil
            for x in stride(from: heard, through: max(1, heard - snapBeats), by: -1) where SetPlanner.onPhrase(br, x) {
                tr.e = x
                break
            }
        }
        tr.g = gAt(tr.e)
        if tr.gCue == nil {
            B.entry.notes.append(
                "started at beat \(tr.e), on beat \(tr.g) of the previous track: not within \(snapBeats) beats of one "
                    + "of its hot cues, check this transition")
        }
        tr.bassSwap = swap != 0 ? swap : Track.beatOf(br.beats, B.fitAt(takeover).track(takeover))
        return tr
    }
}

extension MixAlign.Aligner {
    /// How loud the track is in the recording while playing alone: the least-squares gain of
    /// its series x against the recording's rec over its global probes.
    func refGain(_ t: A.Item, _ x: [Double], _ rec: [Double]) -> Double {
        let g = t.global!
        var f0 = Int(g.rec(Double(t.probes[0].start) / A.fps) * A.fps)
        var f1 = Int(g.rec(Double(t.probes[t.probes.count - 1].start + m) / A.fps) * A.fps)
        f0 = max(f0, 0)
        f1 = min(f1, rec.count)
        if f1 <= f0 { return 1 }
        var sxy = 0.0
        var sxx = 0.0
        for i in f0..<f1 {
            let v = Signal.at(x, g.track(Double(i) / A.fps) * A.fps) ?? 0
            sxy += v * rec[i]
            sxx += v * v
        }
        return sxy <= 0 || sxx <= 0 ? 1 : sxy / sxx
    }

    /// Where the first track becomes audible.
    func firstAudible(_ t: A.Item) -> Double {
        let f = t.pieces[0].fit
        let f0 = max(0, Int(f.rec(0) * A.fps))
        let f1 = min(full.count, Int(t.last.rec(t.dur) * A.fps))
        if f1 <= f0 { return max(f.rec(0), 0) }
        let mp = t.mapped(t.full, f0, f1 - f0)
        let (g, _) = A.gains(Array(full[f0..<f1]), mp, nil, A.beatFrames(t, f, 4))
        let ref = refGain(t, t.full, full)
        guard let i = A.sustained(0, g.count, A.beatFrames(t, f, 4), { g[$0] / ref > A.audible }) else {
            return Double(f0) / A.fps
        }
        return Double(f0 + i) / A.fps
    }

    /// Where the last track stops being audible.
    func lastAudible(_ t: A.Item) -> Double {
        let f = t.last
        let f0 = max(0, Int(t.start * A.fps))
        let f1 = min(full.count, Int(f.rec(t.dur) * A.fps))
        if f1 <= f0 { return min(f.rec(t.dur), dur) }
        let mp = t.mapped(t.full, f0, f1 - f0)
        let (g, _) = A.gains(Array(full[f0..<f1]), mp, nil, A.beatFrames(t, f, 4))
        let ref = refGain(t, t.full, full)
        for i in stride(from: g.count - 1, through: 0, by: -1) where g[i] / ref > A.audible {
            return Double(f0 + i + 1) / A.fps
        }
        return Double(f1) / A.fps
    }

    /// Finds where B (incoming) takes over from A, cuts there (snapped to B's phrase start) and
    /// works out the transition as played.
    func transition(_ A_: A.Item, _ B: A.Item, sampleRate: Int) {
        let prevCut = Double(A_.entry.cutSample) / Double(sampleRate)
        let takeover = self.takeover(A_, B, prevCut)
        B.entry.takeover = A.formatTime(takeover)
        let (cut, swap) = cutAt(B, takeover, prevCut)
        B.entry.cutSample = Int64((cut * Double(sampleRate)).rounded())
        B.entry.cut = A.formatTime(Double(B.entry.cutSample) / Double(sampleRate))
        if let ar = A_.input.rec, let br = B.input.rec, !ar.beats.isEmpty, !br.beats.isEmpty {
            B.entry.transition = A.played(A_, B, swap, takeover)
        }
    }

    /// Where B takes over from A: over their overlap, the first sustained stretch where B
    /// explains the recording's bass better than A (each relative to its level playing alone).
    /// It also sets B's audible start and A's audible end.
    func takeover(_ a: A.Item, _ b: A.Item, _ prevCut: Double) -> Double {
        let fa = a.last
        let fb = b.pieces[0].fit
        let oStart = fb.rec(0)
        let oEnd = min(fa.rec(a.dur), dur)
        let r0 = max(max(prevCut, a.start), min(oStart, oEnd) - 10)
        let r1 = min(dur, max(oStart, oEnd) + 10)
        let f0 = max(Int(r0 * A.fps), 0)
        let f1 = min(Int(r1 * A.fps), bass.count)
        let n = f1 - f0
        var takeover = oStart
        var startB = oStart
        var endA = oEnd
        if n > 0 {
            let w = A.beatFrames(a, fa, 8)
            let (ga, gb) = A.gains(Array(bass[f0..<f1]), a.mapped(a.bass, f0, n), b.mapped(b.bass, f0, n), w)
            let a0 = refGain(a, a.bass, bass)
            let b0 = refGain(b, b.bass, bass)
            let (gaf, gbf) = A.gains(Array(full[f0..<f1]), a.mapped(a.full, f0, n), b.mapped(b.full, f0, n), w / 2)
            let a0f = refGain(a, a.full, full)
            let b0f = refGain(b, b.full, full)
            func idx(_ t: Double) -> Int { min(max(Int(t * A.fps) - f0, 0), n) }
            func sec(_ i: Int) -> Double { Double(f0 + i) / A.fps }
            let lo = idx(oStart)
            let hi = idx(oEnd)
            if lo >= hi {
                b.entry.notes.append("no overlap with the previous track")
            } else if let i = A.sustained(lo, hi, w / 2, { gb[$0] / b0 > ga[$0] / a0 && gb[$0] / b0 > A.audible }) {
                takeover = sec(i)
            } else {
                takeover = oEnd
                b.entry.notes.append("no clear bass swap: cut where the previous track ends")
            }
            startB = takeover
            if let i = A.sustained(lo, idx(takeover), w / 2, { gbf[$0] / b0f > A.audible }) { startB = sec(i) }
            endA = takeover
            for i in stride(from: idx(min(oEnd, r1)) - 1, through: idx(takeover), by: -1) where gaf[i] / a0f > A.audible
            {
                endA = sec(i + 1)
                break
            }
        }
        startB = max(startB, 0)
        takeover = max(takeover, 0)
        b.start = min(startB, takeover)
        a.end = max(endA, takeover)
        return takeover
    }

    /// Where B's file starts: the takeover moved to B's nearest phrase start (within
    /// `snapBeats`), and that beat (0 when not snapped). It stays after the previous cut.
    func cutAt(_ b: A.Item, _ takeover: Double, _ prevCut: Double) -> (Double, Int) {
        var cut = takeover
        var swap = 0
        if let r = b.input.rec, !r.beats.isEmpty {
            let fb = b.fitAt(takeover)
            var beat = Track.beatOf(r.beats, fb.track(takeover))
            let s = A.snapPhrase(r, beat, -A.snapBeats, A.snapBeats)
            if s > 0 { beat = s }
            swap = beat
            cut = fb.rec(r.beats[beat - 1])
        }
        if cut <= prevCut + 1 || cut >= dur {
            (cut, swap) = (takeover, 0)
            b.entry.notes.append("the phrase start is outside the previous track's span: cut at the takeover")
        }
        if cut <= prevCut + 1 {
            cut = min(prevCut + 1, dur)
            b.entry.status = A.lowConf
            b.entry.notes.append("the takeover falls inside the previous track's file: check the cut")
        }
        return (cut, swap)
    }
}
