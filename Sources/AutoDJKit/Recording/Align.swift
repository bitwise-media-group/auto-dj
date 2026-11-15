// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// Lines the tracks of a play history up against a recording of the set (port of
/// internal/mixalign, docs/decisions/0017-split-recordings-by-alignment.md). The history gives
/// the order, the audio gives the timing: each track is found by matching its onset envelope
/// against the recording over a grid of CDJ tempo ratios, refitted locally at each transition,
/// and the cut between two tracks goes where the incoming track takes the bass over, snapped
/// to its nearest phrase start.
public enum MixAlign {
    /// Probe window length (s).
    public static let probeSec = 8.0
    /// Probes per fit, of which ...
    public static let maxProbes = 12
    /// ... the best this many score it (sets play parts of tracks, and mashups).
    public static let agree = 3
    /// Tempo ratios searched (the CDJ's ±10% range) ...
    public static let rMin = 0.90
    public static let rMax = 1.10
    /// ... in 0.25% steps.
    public static let rStep = 0.0025
    /// How far past the previous track's end the next one is searched for (s).
    public static let maxGapSec = 600.0
    /// How far a transition's local fit may move from the global one (a loop, s).
    public static let localSec = 40.0
    /// The score (the `agree` best probes' mean correlation) below which a track counts as not
    /// played. On a real hour-long set, the 20 tracks played scored 0.83-0.98 and 35 tracks from
    /// other sessions 0.14-0.73.
    public static let notFound = 0.78
    /// The score below which a fit is flagged for review.
    public static let lowConfidence = 0.88
    /// The full-band gain (relative to the track playing alone) above which a track counts as
    /// audible.
    public static let audible = 0.2
    /// The lowest score at which a track is traced anyway, in case it was played only briefly:
    /// it counts as found when `runProbes` probes in a row match at `runScore` or better.
    public static let rescue = 0.6
    public static let runProbes = 4
    public static let runScore = 0.85
    /// The spacing of the probes a track's path is traced with.
    public static let traceBeats = 16
    /// What a jump (loop, hot cue) costs a traced path, in probe correlation.
    public static let jumpPenalty = 0.6
    /// How far (s) two probes' offsets may differ and still be one straight play.
    public static let continuous = 0.06
    /// How far before the moment a track became audible its E may be on one of its cues.
    public static let cueBeats = 64
    /// How far the cut may move to reach the incoming track's phrase start.
    public static let snapBeats = SetPlanner.phrase

    static let fps = Features.fps

    /// Statuses.
    public static let ok = "ok"
    public static let lowConf = "low-confidence"
    public static let notFoundState = "not-found"
    public static let noAudio = "no-audio"

    /// One history entry to locate in the recording.
    public struct Input: Sendable {
        public var no: Int
        public var id: String
        public var title: String
        /// The beat grid and phrases (nil without Rekordbox analysis: the cut is then not
        /// snapped and no transition is recorded).
        public var rec: Track?
        /// The track's frame features, nil when its audio isn't here.
        public var frames: Features.Frames?

        public init(no: Int, id: String, title: String, rec: Track?, frames: Features.Frames?) {
            (self.no, self.id, self.title, self.rec, self.frames) = (no, id, title, rec, frames)
        }
    }

    /// Maps track time to recording time: rec = offset + track / r (seconds). r is the tempo
    /// ratio the track played at (1.02 = 2% faster).
    public struct Fit: Codable, Sendable, Equatable {
        public var offset: Double
        public var r: Double
        public var score: Double

        /// The recording second where track second t plays.
        public func rec(_ t: Double) -> Double { offset + t / r }
        /// The track second playing at recording second rec.
        public func track(_ rec: Double) -> Double { (rec - offset) * r }
    }

    /// The transition into a track as it was played, in track beats: G on the outgoing track
    /// (where the incoming one came in), E and BASS SWAP on the incoming one.
    public struct Transition: Codable, Sendable, Equatable {
        public var fromID: String
        public var fromTitle: String
        public var g = 0
        public var e = 0
        public var bassSwap = 0
        /// The incoming track's cue E is on.
        public var eCue: String?
        /// The outgoing track's hot cue G is near, "<name> +n beats".
        public var gCue: String?

        enum CodingKeys: String, CodingKey {
            case fromID = "from_id", fromTitle = "from_title", g = "g_beat", e = "e_beat"
            case bassSwap = "bass_swap_beat", eCue = "e_cue", gCue = "g_cue"
        }
    }

    /// One history track's alignment. Times are recording times as h:mm:ss.sss.
    public struct Entry: Codable, Sendable, Equatable {
        public var no: Int
        public var id: String
        public var title: String
        public var status = ""
        public var confidence = 0.0
        public var peakRatio: Double?
        /// Share of its probes heard where expected.
        public var matched: Double?
        /// The whole track.
        public var fit: Fit?
        /// How it played at its start ...
        public var inFit: Fit?
        /// ... and at its end (they differ after a loop or jump).
        public var outFit: Fit?
        /// Audible from ...
        public var start: String?
        /// ... until.
        public var end: String?
        public var takeover: String?
        /// Where its file starts; edit to move, clear to leave it out.
        public var cut = ""
        public var cutSample: Int64 = 0
        public var transition: Transition?
        public var notes: [String] = []

        enum CodingKeys: String, CodingKey {
            case no, id, title, status, confidence, peakRatio = "peak_ratio", matched, fit, inFit = "in_fit"
            case outFit = "out_fit", start, end, takeover, cut, cutSample = "cut_sample", transition, notes
        }

        public init(no: Int, id: String, title: String) {
            (self.no, self.id, self.title) = (no, id, title)
        }

        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            no = try c.decode(Int.self, forKey: .no)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
            peakRatio = try c.decodeIfPresent(Double.self, forKey: .peakRatio)
            matched = try c.decodeIfPresent(Double.self, forKey: .matched)
            fit = try c.decodeIfPresent(Fit.self, forKey: .fit)
            inFit = try c.decodeIfPresent(Fit.self, forKey: .inFit)
            outFit = try c.decodeIfPresent(Fit.self, forKey: .outFit)
            start = try c.decodeIfPresent(String.self, forKey: .start)
            end = try c.decodeIfPresent(String.self, forKey: .end)
            takeover = try c.decodeIfPresent(String.self, forKey: .takeover)
            cut = try c.decodeIfPresent(String.self, forKey: .cut) ?? ""
            cutSample = try c.decodeIfPresent(Int64.self, forKey: .cutSample) ?? 0
            transition = try c.decodeIfPresent(Transition.self, forKey: .transition)
            notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        }

        /// Whether the track gets a file: it has a cut.
        public var kept: Bool { !cut.isEmpty }
        /// Whether the track was found in the recording.
        public var located: Bool { status == ok || status == lowConf }
    }

    /// A stretch of a track's channels, from track frame start.
    struct Probe {
        var start: Int
        var q: [[Double]]
    }

    /// A stretch of the recording, from recording second `from`, where a track played straight
    /// through (between loops or hot cue jumps).
    struct Piece {
        var fit: Fit
        var from: Double
    }

    /// One input's working state.
    final class Item {
        let input: Input
        var entry: Entry
        var env: [[Double]] = []
        var bass: [Double] = []
        var full: [Double] = []
        var dur = 0.0
        var global: Fit?
        var probes: [Probe] = []
        /// How it played, in recording order.
        var pieces: [Piece] = []
        /// The longest straight run of probes matching at `runScore`.
        var heard = 0
        /// Audible span (recording seconds).
        var start = 0.0
        var end = 0.0

        init(_ input: Input) {
            self.input = input
            entry = Entry(no: input.no, id: input.id, title: input.title)
        }

        var hasAudio: Bool { !env.isEmpty }

        /// The mapping at recording second rec: the last piece starting at or before it.
        func fitAt(_ rec: Double) -> Fit {
            var f = pieces[0].fit
            for p in pieces.dropFirst() {
                if p.from > rec { break }
                f = p.fit
            }
            return f
        }

        /// The mapping of the last piece.
        var last: Fit { pieces[pieces.count - 1].fit }

        /// The probe of m frames from track frame start.
        func probeAt(_ start: Int, _ m: Int) -> Probe {
            Probe(start: start, q: env.map { Array($0[start..<start + m]) })
        }

        /// The track's BPM (0 without a grid).
        var bpm: Double { input.rec?.bpm ?? 0 }
    }

    /// The recording's envelopes.
    final class Aligner {
        let env: [[Double]]
        let bass: [Double]
        let full: [Double]
        var dur: Double
        /// Probe length (frames).
        let m: Int

        init(_ rec: Features.Frames) {
            env = Signal.channels(rec)
            bass = Signal.amp(rec, [0])
            full = Signal.amp(rec, [1, 2, 3])
            dur = Double(rec.count) / fps
            m = Int((probeSec * fps).rounded())
        }
    }

    /// Locates each input in the recording (its frame features) and plans the cuts. sampleRate
    /// and samples are the recording's own, for the cut samples.
    public static func align(
        _ rec: Features.Frames, _ inputs: [Input], sampleRate: Int, samples: Int64,
        progress: (String) -> Void = { _ in }
    ) -> [Entry] {
        let a = Aligner(rec)
        if sampleRate > 0 && samples > 0 { a.dur = Double(samples) / Double(sampleRate) }
        let ts = inputs.map { Item($0) }
        for t in ts {
            guard let F = t.input.frames, F.count >= 2 * a.m else {
                t.entry.status = noAudio
                t.entry.notes.append("no audio file here (streaming or missing): set its cut by hand")
                continue
            }
            t.env = Signal.channels(F)
            t.bass = Signal.amp(F, [0])
            t.full = Signal.amp(F, [1, 2, 3])
            t.dur = Double(F.count) / fps
        }
        a.locateAll(ts, progress: progress)
        var found: [Item] = []
        for t in ts where t.global != nil {
            if t.pieces.isEmpty { a.trace(t) }
            found.append(t)
        }
        for (i, t) in found.enumerated() {
            if i == 0 {
                t.start = a.firstAudible(t)
                t.entry.cut = formatTime(0)
                t.entry.cutSample = 0
                continue
            }
            a.transition(found[i - 1], t, sampleRate: sampleRate)
        }
        if let l = found.last { l.end = a.lastAudible(l) }
        return ts.map { t in
            var e = t.entry
            if let g = t.global {
                e.fit = round(g)
                e.inFit = round(t.pieces[0].fit)
                e.outFit = round(t.last)
                e.start = formatTime(t.start)
                e.end = formatTime(t.end)
            }
            return e
        }
    }

    static func round(_ f: Fit) -> Fit {
        Fit(
            offset: (f.offset * 1e4).rounded() / 1e4, r: (f.r * 1e6).rounded() / 1e6,
            score: (f.score * 1e3).rounded() / 1e3)
    }

    static func tempoGrid(_ lo: Double, _ hi: Double) -> [Double] {
        var rs: [Double] = []
        var k = 0
        while true {
            let r = lo + Double(k) * rStep
            if r > hi + 1e-9 { return rs }
            rs.append(r)
            k += 1
        }
    }

    /// How many of n probes score a fit.
    static func agreeOf(_ n: Int) -> Int { min(n, agree) }

    /// The mean of the k largest of xs (-inf when fewer than k are finite).
    static func topMean(_ xs: [Double], _ k: Int) -> Double {
        let ys = xs.filter { $0.isFinite }
        if ys.count < k || k == 0 { return -.infinity }
        return ys.sorted().suffix(k).reduce(0, +) / Double(k)
    }

    // ---------------------------------------------------------------- times

    /// Seconds as h:mm:ss.sss.
    public static func formatTime(_ s: Double) -> String {
        let ms = Int64((s * 1000).rounded())
        return String(format: "%d:%02d:%02d.%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// Reads h:mm:ss.sss, m:ss.sss or plain seconds.
    public static func parseTime(_ v: String) throws -> Double {
        let parts = v.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        if parts.count > 3 { throw AutoDJError("not a time like 1:02:03.456: \"\(v)\"") }
        var s = 0.0
        for (i, p) in parts.enumerated() {
            guard let x = Double(p), x >= 0, i == 0 || x < 60 else {
                throw AutoDJError("not a time like 1:02:03.456: \"\(v)\"")
            }
            s = s * 60 + x
        }
        return s
    }
}

// MARK: - locating

extension MixAlign.Aligner {
    typealias A = MixAlign

    /// Finds each track in turn, searching from the previous track's position.
    func locateAll(_ ts: [A.Item], progress: (String) -> Void) {
        var lo = 0.0
        var hi = 0.0  // recording seconds the next track's middle is searched in
        var first = true
        for t in ts where t.hasAudio {
            progress("locating \(t.input.no). \(t.input.title)")
            hi = first ? t.dur + A.maxGapSec : hi + t.dur
            t.probes = pickProbes(t, 0.1, 0.9)
            let res = locate(t, t.probes, lo, hi, A.tempoGrid(A.rMin, A.rMax), late: false)
            var rescued = false
            if let (fit, _) = res, fit.score >= A.rescue && fit.score < A.notFound {  // played only briefly?
                t.global = fit
                trace(t)
                rescued = t.heard >= A.runProbes
                if !rescued {
                    t.global = nil
                    t.pieces = []
                }
            }
            guard let (fit, ratio) = res, fit.score >= A.notFound || rescued else {
                t.entry.status = A.notFoundState
                if let (fit, _) = res { t.entry.confidence = (fit.score * 1e3).rounded() / 1e3 }
                t.entry.notes.append("not heard in the recording: left out")
                continue
            }
            first = false
            t.global = fit
            t.entry.confidence = (fit.score * 1e3).rounded() / 1e3
            t.entry.peakRatio = (ratio * 1e3).rounded() / 1e3
            t.entry.status = fit.score < A.lowConfidence ? A.lowConf : A.ok
            if rescued {
                var sec = Double(t.heard) * A.probeSec  // probes every 8 s without a grid
                if t.bpm > 0 { sec = Double(t.heard * A.traceBeats) * 60 / t.bpm / fit.r }
                t.entry.notes.append(String(format: "heard straight for only about %.0f s (a short excerpt?)", sec))
            }
            if fit.r <= A.rMin + A.rStep / 2 || fit.r >= A.rMax - A.rStep / 2 {
                t.entry.status = A.lowConf
                t.entry.notes.append(String(format: "tempo ratio %.3f is at the edge of the CDJ range", fit.r))
            }
            lo = max(fit.offset, 0)  // where its beat 1 would play: the next track's middle comes later
            hi = fit.rec(t.dur) + A.maxGapSec
        }
    }

    /// The places a probe may start (track frames): the phrase starts and every 32 beats with
    /// a beat grid, and every 4 s regardless (a phrase grid can miss what was played).
    func probeStarts(_ t: A.Item, _ n: Int) -> [Int] {
        var starts: [Int] = []
        if let r = t.input.rec, !r.beats.isEmpty {
            for p in r.phrases where p.beat >= 1 && p.beat <= r.beats.count {
                starts.append(Int((r.beats[p.beat - 1] * A.fps).rounded()))
            }
            for b in stride(from: 1, through: r.beats.count, by: 32) {
                starts.append(Int((r.beats[b - 1] * A.fps).rounded()))
            }
        }
        let step = Int((4 * A.fps).rounded())
        starts += Array(stride(from: 0, to: n, by: step))
        return starts
    }

    static func variance(_ x: ArraySlice<Double>) -> Double {
        let m = x.reduce(0, +) / Double(x.count)
        return x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count)
    }

    /// Up to `maxProbes` probe windows between fractions lo and hi of the track: the busiest
    /// (largest channel variance) in each of `maxProbes` equal stretches, at least a probe
    /// length apart. A set plays only part of a track, so they must cover it all.
    func pickProbes(_ t: A.Item, _ lo: Double, _ hi: Double) -> [A.Probe] {
        let n = t.env[0].count
        let from = Int(lo * Double(n))
        let to = Int(hi * Double(n))
        var cs: [(start: Int, v: Double)] = []
        for s in probeStarts(t, n) where s >= from && s + m <= to && s + m <= n {
            cs.append((s, t.env.reduce(0) { $0 + Self.variance($1[s..<s + m]) }))
        }
        if cs.isEmpty { cs.append((max(0, min(n - m, (from + to) / 2 - m / 2)), 1)) }  // a short track: its middle
        let strata = max(1, min(A.maxProbes, (to - from) / m))
        let span = Double(to - from) / Double(strata)
        var best = [(start: Int, v: Double)?](repeating: nil, count: strata)
        for c in cs {
            let k = min(strata - 1, max(0, Int(Double(c.start - from) / span)))
            if best[k] == nil || c.v > best[k]!.v { best[k] = c }
        }
        var out: [A.Probe] = []
        for c in best.compactMap({ $0 }) where !out.contains(where: { abs($0.start - c.start) < m }) {
            out.append(t.probeAt(c.start, m))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// The probes' mean start frame and the furthest any is from it.
    static func centre(_ probes: [A.Probe]) -> (Double, Double) {
        let pc = Double(probes.reduce(0) { $0 + $1.start }) / Double(probes.count)
        return (pc, probes.map { abs(Double($0.start) - pc) }.max() ?? 0)
    }

    /// Fits the probes against the recording, with the probes' centre playing between recording
    /// seconds lo and hi, over tempo ratios rs: the mean (max-filtered) correlation of the
    /// `agree` best probes, then a fine refinement of the best couple of dozen peaks. Returns
    /// the fit and the ratio of the best score to the best one at least half a beat away; nil
    /// when there was nowhere to search. Equal scores go to the earliest position, or the
    /// latest with late (a looped stretch plays twice).
    func locate(_ t: A.Item, _ probes: [A.Probe], _ lo: Double, _ hi: Double, _ rs: [Double], late: Bool)
        -> (A.Fit, Double)?
    {
        if probes.isEmpty { return nil }
        let (pc, maxDist) = Self.centre(probes)
        let span = maxDist / A.rMin + Double(m) / A.rMin
        let x0 = max(0, Int(lo * A.fps - span) - 1)
        let x1 = min(env[0].count, Int(hi * A.fps + span) + 2)
        if x1 - x0 < 2 * m { return nil }
        let res = coarse(t, probes, pc, x0, x1, rs, Int((A.rStep / 2 * maxDist).rounded(.up)) + 1)
        let cLo = max(Int(lo * A.fps) - x0, 0)
        let cHi = Int(hi * A.fps) - x0
        let cands = Self.bestPeaks(res, cLo, cHi, late: late)
        if cands.isEmpty { return nil }
        var fits = [A.Fit](repeating: A.Fit(offset: 0, r: 1, score: -.infinity), count: cands.count)
        fits.withUnsafeMutableBufferPointer { fp in
            nonisolated(unsafe) let fp = fp
            DispatchQueue.concurrentPerform(iterations: cands.count) { k in
                fp[k] = refine(probes, pc, Double(x0 + cands[k].c) / A.fps, rs[cands[k].i])
            }
        }
        var bk = 0
        for (k, f) in fits.enumerated() where f.score > fits[bk].score + 1e-9 { bk = k }
        let bp = cands[bk]
        var second = -Double.infinity
        let excl = Int((0.25 * A.fps).rounded())
        if cLo <= min(cHi, res[bp.i].count - 1) {
            for c in cLo...min(cHi, res[bp.i].count - 1) where abs(c - bp.c) > excl {
                second = max(second, res[bp.i][c])
            }
        }
        let ratio = second > 1e-6 ? min(bp.v / second, 10) : 10
        return (fits[bk], ratio)
    }

    /// The consensus curve of every tempo ratio over recording frames [x0, x1), in parallel.
    func coarse(_ t: A.Item, _ probes: [A.Probe], _ pc: Double, _ x0: Int, _ x1: Int, _ rs: [Double], _ w: Int)
        -> [[Double]]
    {
        let base = env.map { Correlator(Array($0[x0..<x1])) }
        var res = [[Double]](repeating: [], count: rs.count)
        let workers = min(ProcessInfo.processInfo.activeProcessorCount, rs.count)
        res.withUnsafeMutableBufferPointer { rp in
            nonisolated(unsafe) let rp = rp
            DispatchQueue.concurrentPerform(iterations: workers) { wk in
                let cs = base.map { $0.fork() }
                var i = wk
                while i < rs.count {
                    rp[i] = consensus(cs, t, probes, pc, rs[i], w)
                    i += workers
                }
            }
        }
        return res
    }

    /// A local maximum of tempo ratio i's consensus curve, at centre frame c.
    struct Peak {
        var i: Int
        var c: Int
        var v: Double
    }

    /// Pools each tempo ratio's best four peaks (half a second apart) between centre frames
    /// cLo and cHi and returns the best 24 places.
    static func bestPeaks(_ res: [[Double]], _ cLo: Int, _ cHi: Int, late: Bool) -> [Peak] {
        let sep = Int((0.5 * A.fps).rounded())
        var peaks: [Peak] = []
        for (i, r) in res.enumerated() {
            var local: [Peak] = []
            if cLo <= min(cHi, r.count - 1) {
                for c in cLo...min(cHi, r.count - 1) {
                    let v = r[c]
                    if v != -.infinity && (c == cLo || r[c - 1] <= v) && (c == r.count - 1 || r[c + 1] <= v) {
                        local.append(Peak(i: i, c: c, v: v))
                    }
                }
            }
            local = stableSorted(local) { x, y in
                if x.v == y.v && late { return x.c > y.c }
                return x.v > y.v
            }
            var kept = 0
            for (k, pk) in local.enumerated() {
                if kept == 4 { break }
                if !local[..<k].contains(where: { abs($0.c - pk.c) < sep && $0.v >= pk.v }) {
                    peaks.append(pk)
                    kept += 1
                }
            }
        }
        peaks = stableSorted(peaks) { $0.v > $1.v }
        var out: [Peak] = []
        for pk in peaks {
            if out.count == 24 { break }
            if !out.contains(where: { abs($0.c - pk.c) < 3 }) { out.append(pk) }
        }
        return out
    }

    /// For tempo ratio r, the mean max-filtered correlation of the `agree` best probes by the
    /// recording frame (segment-relative) where the probes' centre pc plays; -inf where too few
    /// probes fall inside the segment.
    func consensus(_ cs: [Correlator], _ t: A.Item, _ probes: [A.Probe], _ pc: Double, _ r: Double, _ w: Int)
        -> [Double]
    {
        let n = cs[0].x.count
        var per = [[Double]](repeating: [], count: probes.count)
        let mm = Int(Double(m) / r)
        var q = [Double](repeating: 0, count: mm)
        for (pi, p) in probes.enumerated() {
            per[pi] = [Double](repeating: -.infinity, count: n)
            var avg: [Double] = []
            for (k, c) in cs.enumerated() {
                for j in 0..<mm { q[j] = Signal.at(t.env[k], Double(p.start) + Double(j) * r) ?? 0 }
                if !Signal.normalise(&q) { continue }
                let x = c.ncc(q)
                if avg.isEmpty { avg = [Double](repeating: 0, count: x.count) }
                let inv = 1 / Double(cs.count)
                for L in x.indices { avg[L] += x[L] * inv }
            }
            if avg.isEmpty { continue }
            let ncc = Signal.maxFilter(avg, w)
            let shift = Int(((pc - Double(p.start)) / r).rounded())
            for (L, v) in ncc.enumerated() {
                let k = L + shift
                if k >= 0 && k < n { per[pi][k] = v }
            }
        }
        var out = [Double](repeating: 0, count: n)
        var vals = [Double](repeating: 0, count: probes.count)
        let ag = A.agreeOf(probes.count)
        for k in 0..<n {
            for pi in per.indices { vals[pi] = per[pi][k] }
            out[k] = A.topMean(vals, ag)
        }
        return out
    }

    /// The mean correlation of the `agree` best probes with the recording when the probes'
    /// centre pc plays at recording second rc at tempo ratio r (no max filter: the fine fit).
    func score(_ probes: [A.Probe], _ pc: Double, _ rc: Double, _ r: Double) -> Double {
        var y = [Double](repeating: 0, count: m)
        var per = [Double](repeating: 0, count: probes.count)
        for (pi, p) in probes.enumerated() {
            for (k, ch) in env.enumerated() {
                for j in 0..<m { y[j] = Signal.at(ch, rc * A.fps + (Double(p.start + j) - pc) / r) ?? 0 }
                per[pi] += Signal.pearson(p.q[k], y) / Double(env.count)
            }
        }
        return A.topMean(per, A.agreeOf(probes.count))
    }

    /// Searches centre positions within three frames of rc (quarter frames), then tempo ratios
    /// within a grid step of r (tenth steps), then the positions again, for the best
    /// unfiltered fit.
    func refine(_ probes: [A.Probe], _ pc: Double, _ rc0: Double, _ r0: Double) -> A.Fit {
        var rc = rc0
        var r = r0
        var best = score(probes, pc, rc, r)
        func byPos() {
            let c0 = rc
            var dc = -3.0
            while dc <= 3 {
                let v = score(probes, pc, c0 + dc / A.fps, r)
                if v > best { (rc, best) = (c0 + dc / A.fps, v) }
                dc += 0.25
            }
        }
        byPos()
        let rBase = r
        var dr = -A.rStep
        while dr <= A.rStep + 1e-12 {
            let v = score(probes, pc, rc, rBase + dr)
            if v > best { (r, best) = (rBase + dr, v) }
            dr += A.rStep / 10
        }
        byPos()
        return A.Fit(offset: rc - pc / A.fps / r, r: r, score: best)
    }
}

/// A stable sort (Swift's sort isn't guaranteed stable for equal keys).
func stableSorted<T>(_ xs: [T], by less: (T, T) -> Bool) -> [T] {
    xs.enumerated().sorted { a, b in
        less(a.element, b.element) || (!less(b.element, a.element) && a.offset < b.offset)
    }.map(\.element)
}
