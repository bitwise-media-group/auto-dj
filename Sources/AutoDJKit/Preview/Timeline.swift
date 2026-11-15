// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// Mix parameters (beats unless noted). See ADR 0012 / 0019.
public enum Mix {
    public static let sampleRate = 44100.0
    public static let lead = 8
    public static let fadeIn = 8.0
    public static let fadeOut = 8.0
    public static let tail = 8.0
    /// FILTER exit: low-pass sweep to silence, then a fade out.
    public static let filterBeats = 8.0
    public static let filterFadeBeats = 4.0
    public static let lowCutHz = 180.0
    /// Silence (s) where a track's audio is missing.
    public static let gapS = 1.0
    public static let swapXFS = 0.03
    public static let splitXFS = 0.02
    public static let jumpXFS = 0.01
    public static let cutRampS = 0.005
}

/// The source second of (possibly fractional / out-of-range) beat b on t's grid.
public func beatTime(_ t: Track, _ b: Double) -> Double {
    let B = t.beats
    let spb = 60 / max(t.bpm, 1)
    if b < 1 { return B[0] + (b - 1) * spb }
    if b > Double(B.count) { return B[B.count - 1] + (b - Double(B.count)) * spb }
    let i = Int(b.rounded(.down)) - 1
    let frac = b - b.rounded(.down)
    let nxt = i + 1 < B.count ? B[i + 1] : B[i] + spb
    return B[i] + frac * (nxt - B[i])
}

public func beatTime(_ t: Track, _ b: Int) -> Double { beatTime(t, Double(b)) }

/// A track's playback from its start point, through its jumps: playback seconds (0 = the start
/// point, at the track's own tempo) <-> source seconds. The first piece extends back before the
/// start point and the last past the end of the file as needed.
public struct Route: Sendable, Hashable, Codable {
    /// Stretches of source seconds [s0, s1) played in one go.
    public var pieces: [Piece]

    public struct Piece: Sendable, Hashable, Codable {
        public var s0: Double
        public var s1: Double
    }

    /// A piece playing from playback second q, source [s0, s1).
    public struct SpanPiece: Sendable, Equatable {
        public var q: Double
        public var s0: Double
        public var s1: Double
    }

    /// The playback length.
    public var dur: Double { pieces.reduce(0) { $0 + $1.s1 - $1.s0 } }

    /// The playback seconds of each jump.
    public var jumps: [Double] {
        var q = 0.0
        return pieces.dropLast().map { p in
            q += p.s1 - p.s0
            return q
        }
    }

    /// The playback second where source second src plays first at or after `after`; nil when
    /// it never plays.
    public func play(_ src: Double, after: Double = 0) -> Double? {
        var q = 0.0
        for (k, p) in pieces.enumerated() {
            if p.s0 <= src && (src < p.s1 || k == pieces.count - 1) && q + src - p.s0 >= after - 1e-6 {
                return q + src - p.s0
            }
            q += p.s1 - p.s0
        }
        return nil
    }

    /// The pieces playing within playback [p0, p1).
    public func span(_ p0: Double, _ p1: Double) -> [SpanPiece] {
        var out: [SpanPiece] = []
        var q = 0.0
        for (k, p) in pieces.enumerated() {
            let lo = k == 0 ? -Double.infinity : q
            let hi = k == pieces.count - 1 ? Double.infinity : q + p.s1 - p.s0
            let a = max(p0, lo)
            let b = min(p1, hi)
            if a < b { out.append(SpanPiece(q: a, s0: p.s0 + a - q, s1: p.s0 + b - q)) }
            q += p.s1 - p.s0
        }
        return out
    }

    /// The source second where t's audio ends.
    public static func trackEnd(_ t: Track) -> Double { t.length != 0 ? t.length : beatTime(t, t.beats.count + 1) }

    /// How t plays from source second start. On reaching a JUMP memory cue playback goes to a
    /// hot cue named JUMP... : the n-th jump to the n-th of those in time order, the last one
    /// again after that. Each memory cue jumps once, so a jump back doesn't loop forever; one
    /// within a beat of a JUMP hot cue marks where a jump lands. Jumps that would skip a source
    /// second in keep (the track's G) aren't taken: the track plays straight through.
    public static func jumpRoute(_ t: Track, start: Double, keep: [Double] = []) -> Route {
        let end = trackEnd(t)
        let spb = 60 / max(t.bpm, 1)
        func isJump(_ c: Cue) -> Bool {
            let n = Config.renameTo(c.name, hot: c.kind > 0)
            return (n.isEmpty ? Config.norm(c.name) : n) == "JUMP"
        }
        let hot = t.cues.filter { $0.kind > 0 && isJump($0) }.map(\.t).sorted()
        var trig = t.cues.filter { c in c.kind == 0 && isJump(c) && !hot.contains { abs(c.t - $0) <= spb } }.map(\.t)
            .sorted()
        let straight = Route(pieces: [Piece(s0: start, s1: max(end, start))])
        if hot.isEmpty { return straight }
        var pieces: [Piece] = []
        var cur = start
        while let i = trig.firstIndex(where: { cur + 1e-3 < $0 && $0 < end }) {
            let nxt = trig.remove(at: i)
            pieces.append(Piece(s0: cur, s1: nxt))
            cur = hot[min(pieces.count, hot.count) - 1]
        }
        if pieces.isEmpty { return straight }
        let route = Route(pieces: pieces + [Piece(s0: cur, s1: max(end, cur))])
        for k in keep where k >= start && route.play(k) == nil { return straight }
        return route
    }
}

/// Maps source seconds to mix seconds for one track: stretched by `rate` (source s per mix s)
/// until mix time `split` (when the previous track has left), by `own` after (1 at its own
/// tempo, else the stretch to the set's fixed tempo).
public struct Clock: Sendable, Hashable, Codable {
    public var out0: Double
    public var src0: Double
    public var rate: Double
    public var split: Double
    public var own: Double

    /// Plays at rate throughout.
    public init(out0: Double, src0: Double, rate: Double) {
        (self.out0, self.src0, self.rate, split, own) = (out0, src0, rate, out0, rate)
    }

    /// The source second playing at `split`.
    public var srcSplit: Double { src0 + (split - out0) * rate }

    /// The mix second where source second src plays.
    public func out(_ src: Double) -> Double {
        src < srcSplit ? out0 + (src - src0) / rate : split + (src - srcSplit) / own
    }

    /// The stretch at mix second t.
    public func rateAt(_ t: Double) -> Double { t < split ? rate : own }
}

/// How a track leaves the mix (mix seconds):
///
///     end    [end]                               plays to its end
///     fade   [from, to]                          fades out
///     filter [sweep from, sweep to, end]         low-pass sweep to silence, then a fade out
///     cut    [at, at]                            cut
public struct ExitPlan: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case end, fade, filter, cut }
    public var kind: Kind
    public var xs: [Double]
}

/// One track in the mix timeline (mix seconds).
public struct Seg: Sendable, Identifiable {
    public var id: Int { n }
    /// 1-based position in the set.
    public var n: Int
    public var title: String
    /// No local audio: the mix leaves a short gap.
    public var missing: Bool
    public var rec: Track?
    public var e = 0
    public var route = Route(pieces: [])
    public var clock = Clock(out0: 0, src0: 0, rate: 1)
    public var start = 0.0
    public var end = 0.0
    public var exit = ExitPlan(kind: .end, xs: [0])
    public var fadeIn: (Double, Double)?
    /// No bass until then.
    public var bassIn: Double?
    /// Bass gone after then.
    public var bassOut: Double?
    /// When it reaches G; the bass swap into the next track.
    public var gT: Double?
    public var swapT: Double?
    public var estimatedSwap = false
    public var sync = false
    public var jumps: [Double] = []
    /// The playback second the track starts from (transition clips).
    var p0 = 0.0

    /// The mix time when the track's audio runs out.
    var length: Double { clock.out(route.dur) }

    mutating func playOut() -> Double {
        end = max(length, start)
        exit = ExitPlan(kind: .end, xs: [end])
        return end
    }
}

/// The mix and transition timelines (port of internal/preview/timeline.go): pure data, known
/// before any audio exists, so the app can draw the whole set at once.
public enum Timeline {
    public static func audioOK(_ t: Track?) -> Bool {
        guard let t, !t.path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: t.path)
    }

    /// t's stretch to the set's fixed tempo bpm (1, its own tempo, when bpm is 0).
    static func tempoRate(_ t: Track, _ bpm: Double) -> Double { bpm <= 0 ? 1 : bpm / max(t.bpm, 1) }

    /// Plans the full-set mix. One Seg per track in order; tracks without local audio are
    /// missing and the mix leaves a short gap (the previous track plays to its end). leadIn > 0
    /// starts the first track this many beats before it reaches its G (transition clips). bpm > 0
    /// plays every track at that fixed tempo (key kept); 0 keeps each track at its own tempo
    /// once the previous one has gone.
    public static func mix(
        _ order: [PlaylistTrack], _ actions: [SetAction], _ recs: [String: Track], leadIn: Int = 0, bpm: Double,
        audioExists: (Track?) -> Bool = audioOK
    ) -> [Seg] {
        var segs: [Seg] = []
        var prev: Int?  // the playing track's segment, while the next one can still mix into it
        var tFree = 0.0  // where the next track starts when there's no transition into it
        for (i, x) in order.enumerated() {
            let t = recs[x.id]
            let act = actions[i]
            var seg = Seg(n: i + 1, title: x.title, missing: !audioExists(t))
            if seg.missing {
                if let p = prev { tFree = segs[p].playOut() + Mix.gapS }
                prev = nil
                segs.append(seg)
                continue
            }
            setRoute(&seg, t!, act, lead: i == 0 && leadIn > 0, leadIn: leadIn)
            var pg: Double?
            if i > 0, let p = prev, let gp = actions[i - 1].g, gp.status != .clear {
                pg = segs[p].route.play(beatTime(segs[p].rec!, gp.beat))
            }
            guard let pg, let p = prev else {
                if let p = prev { tFree = segs[p].playOut() + Mix.gapS }
                seg.start = tFree
                seg.clock = Clock(out0: tFree, src0: seg.p0, rate: tempoRate(t!, bpm))
                segs.append(seg)
                prev = segs.count - 1
                continue
            }
            transition(&segs[p], &seg, actions[i - 1], act, pg, bpm)
            segs.append(seg)
            prev = segs.count - 1
        }
        if let p = prev { _ = segs[p].playOut() }
        for i in segs.indices where !segs[i].missing {
            let s = segs[i]
            segs[i].jumps = s.route.jumps.map { s.clock.out($0) }.filter { s.start <= $0 && $0 < s.end }
        }
        return segs
    }

    /// Sets the track's E (the first downbeat without one) and its route from E, keeping its
    /// own G reachable. With lead, it starts lead beats before it reaches G.
    static func setRoute(_ s: inout Seg, _ t: Track, _ act: SetAction, lead: Bool, leadIn: Int) {
        let keep = act.g.flatMap { $0.status != .clear ? [beatTime(t, $0.beat)] : nil } ?? []
        s.rec = t
        s.e = act.e?.beat ?? CueRules.firstDownbeat(t)
        s.route = Route.jumpRoute(t, start: beatTime(t, s.e), keep: keep)
        if lead, let k = keep.first, let q = s.route.play(k) {
            s.p0 = max(0, q - Double(leadIn) * 60 / t.bpm)
        }
    }

    /// Beat-matches seg into prev, which reaches its G at playback second pg.
    static func transition(
        _ prev: inout Seg, _ seg: inout Seg, _ pact: SetAction, _ act: SetAction, _ pg: Double, _ bpm: Double
    ) {
        let a = prev.rec!
        let ca = prev.clock
        let ra = prev.route
        let t = seg.rec!
        let route = seg.route
        let e = seg.e
        let tg = ca.out(pg)
        var clock = Clock(out0: tg, src0: 0, rate: tempoRate(t, bpm))  // a fixed tempo: already beat-matched
        if bpm <= 0 {  // stretched to the playing tempo until the outgoing track has left (set below)
            clock.rate = a.bpm * ca.rateAt(tg) / t.bpm
            clock.split = .infinity
        }
        func spb(_ m: Double) -> Double { 60 / (a.bpm * ca.rateAt(m)) }  // one beat in mix seconds
        let c = clock
        func outB(_ b: Int) -> Double? { route.play(beatTime(t, b)).map { c.out($0) } }
        var ts = tg + 32 * spb(tg)
        var est = true
        if let sw = act.swap, sw > e, let v = outB(sw) { (ts, est) = (v, false) }
        var x0: Double?
        if let ex = pact.exit {
            if ex.side == "out" {
                x0 = ra.play(beatTime(a, ex.a), after: pg).map { ca.out($0) }
            } else {
                x0 = outB(ex.b)
            }
        }
        let exit: ExitPlan
        if let x0, let ex = pact.exit {
            if ex.name == "FILTER" {
                let xs = x0 + Mix.filterBeats * spb(x0)
                let x1 = max(tg, min(x0 + (Mix.filterBeats + Mix.filterFadeBeats) * spb(x0), prev.length))
                exit = ExitPlan(kind: .filter, xs: [min(x0, x1), min(xs, x1), x1])
            } else {
                let x1 = max(tg, min(x0, prev.length))
                exit = ExitPlan(kind: .cut, xs: [x1, x1])
            }
        } else {
            let x1 = max(tg, min(ts + Mix.fadeOut * spb(ts), prev.length))
            exit = ExitPlan(kind: .fade, xs: [min(ts, x1), x1])
        }
        let x1 = exit.xs.last!
        prev.end = x1
        prev.exit = exit
        prev.gT = tg
        prev.swapT = ts
        prev.estimatedSwap = est
        prev.bassOut = ts < x1 ? ts : nil
        clock.split = min(clock.split, x1)
        seg.sync = act.sync  // instant mashup: in at full volume
        if !seg.sync { seg.fadeIn = (tg, min(tg + Mix.fadeIn * spb(tg), x1)) }
        seg.start = tg
        seg.clock = clock
        seg.bassIn = min(ts, x1)
    }

    /// One transition clip: the mix of A -> B with A from `Mix.lead` beats before it reaches G
    /// (after its jumps from E), ending `Mix.tail` beats after A has left.
    public static func pair(
        _ order: [PlaylistTrack], _ actions: [SetAction], _ recs: [String: Track], bpm: Double,
        audioExists: (Track?) -> Bool = audioOK
    ) -> (Seg, Seg) {
        let segs = mix(order, actions, recs, leadIn: Mix.lead, bpm: bpm, audioExists: audioExists)
        let sa = segs[0]
        var sb = segs[1]
        let end = sa.end + Mix.tail * 60 / (sa.rec!.bpm * sa.clock.own)
        if sb.end > end {
            sb.end = end
            sb.exit = ExitPlan(kind: .end, xs: [end])
            sb.jumps = sb.jumps.filter { $0 < end }
        }
        return (sa, sb)
    }
}
