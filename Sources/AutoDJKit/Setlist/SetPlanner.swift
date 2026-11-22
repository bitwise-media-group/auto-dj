// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// An E or G hot cue decision. Status: existing (left as is) | new (empty slot) | replace
/// (slot overwritten; `old` cached) | clear (last track's G removed).
public struct Slot: Codable, Sendable, Equatable {
    public var name: String
    public var beat: Int
    public var status: SetSlot.Status
    public var old: Old?

    /// The cue a slot replaces.
    public struct Old: Codable, Sendable, Equatable {
        public var name: String
        public var beat: Int
    }
}

/// The planned BASS SWAP IN beat (nil = none) and why.
public struct BassSwap: Codable, Sendable, Equatable {
    public var beat: Int?
    public var why: String
}

/// Where the outgoing track leaves the mix: FILTER | CUT, its beat in the outgoing track (a),
/// the same moment in the incoming one (b), and which track has the cue (out | in).
public struct Exit: Codable, Sendable, Equatable {
    public var name: String
    public var a: Int
    public var b: Int
    public var side: String
}

/// Everything `set` decides for one track.
public struct SetAction: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var e: Slot?
    public var g: Slot?
    public var bassSwap: BassSwap?
    public var warnings: [String] = []
    public var exit: Exit?
    public var sync = false
    public var markers: [SetMarker] = []
    /// Stale memory cues the write deletes; `status` holds the reason.
    public var remove: [Removal] = []
    /// The incoming track's bass swap beat for the previews: the BASS SWAP, else the drop it
    /// would sit on. Set (possibly nil) on every track a transition comes into.
    public var swap: Int?
    public var hasIncoming = false
    /// Beats of the transition into this track where both tracks' vocals play (ADR 0020); set
    /// when 8 or more, nil otherwise.
    public var vocalOverlap: Int?
    /// When vocals overlap: a vocal-free stretch of the outgoing track to loop (4, 8 or 16
    /// bars, on a phrase start) so it can hold while the incoming track's vocals play.
    public var vocalLoop: Loop?

    public struct Loop: Codable, Sendable, Equatable {
        /// The outgoing track's first beat of the loop.
        public var beat: Int
        public var beats: Int
    }

    public struct Removal: Codable, Sendable, Equatable {
        public var name: String
        public var beat: Int
        public var why: String
    }

    enum CodingKeys: String, CodingKey {
        case id, title, e = "E", g = "G", bassSwap = "bass_swap", warnings, exit, sync, markers, remove, swap
        case hasIncoming = "has_incoming"
        case vocalOverlap = "vocal_overlap"
        case vocalLoop = "vocal_loop"
    }

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Plans set-specific cues for a Rekordbox playlist (port of internal/setlist, ADRs 0007-0012).
///
/// For each transition A -> B in the playlist order:
///   - A gets G = reserved OUT point, named after B (default: A's OUT hot cue)
///   - B gets E = reserved IN point, named after A (default: B's IN hot cue, moved earlier if
///     needed so B's bass swap lands before A runs out)
///   - B gets a BASS SWAP IN memory cue on a phrase, inside the overlap, unless it would sit on
///     a drop
///   - every transition marker is on both tracks, named by side: BASS SWAP IN / OUT, and where
///     A leaves the mix (its FILTER or CUT memory cue, or B's) FILTER IN / OUT or CUT IN / OUT,
///     and for an instant mashup (a SYNC memory cue on A's G or B's E) SYNC IN / OUT
///
/// First track: E = START (first downbeat). Last track: no G.
///
/// Mixing model: tracks are beat-matched, so positions are compared in beats (each track's own
/// grid). When A reaches G, B is started at E. B beat = E + (A beat - G). A "phrase" is 16 beats
/// counted from the track's first downbeat.
///
/// A transition is aligned when E and G sit at the same position in their phrase, or when B
/// starts a new phrase exactly as A finishes (letting A play to the end).
public enum SetPlanner {
    /// The phrase length in beats.
    public static let phrase = 16

    static func pyMod(_ a: Int, _ b: Int) -> Int { ((a % b) + b) % b }

    // ---------------------------------------------------------------- names

    /// 'The Lost Hawk (Original Mix)' -> 'LOST HAWK' (no mix name, no 'The').
    public static func cueName(_ title: String) -> String { Track.titleStem(title).uppercased() }

    /// A fuzzy match: hand-typed set cues have typos ('DIALOG', 'RAJ').
    public static func namesMatch(_ cue: String, _ title: String) -> Bool {
        let a = Track.titleStem(cue)
        let b = Track.titleStem(title)
        if a.isEmpty || b.isEmpty { return false }
        return a == b || b.hasPrefix(a) || a.hasPrefix(b) || SequenceMatcher.ratio(a, b) >= 0.6
    }

    // ---------------------------------------------------------------- geometry

    static func beatOf(_ t: Track, _ sec: Double) -> Int { Track.beatOf(t.beats, sec) }

    /// Beats since the last 16-beat boundary counted from the first downbeat.
    public static func gridPhase(_ t: Track, _ b: Int) -> Int { pyMod(b - CueRules.firstDownbeat(t), phrase) }

    /// Python's xs[i] with negative indexing (0 when out of range).
    static func pyIndex(_ xs: [Int], _ i: Int) -> Int {
        let j = i < 0 ? i + xs.count : i
        return j >= 0 && j < xs.count ? xs[j] : 0
    }

    /// Beats since the current Rekordbox phrase started. It catches tracks whose phrasing shifts
    /// by half a phrase mid-track. Only phrase starts on a bar downbeat count.
    public static func phrasePhase(_ t: Track, _ b: Int) -> Int {
        var base = CueRules.firstDownbeat(t)
        for p in t.phrases where p.beat <= b && p.beat <= t.bnum.count && pyIndex(t.bnum, p.beat - 1) == 1 {
            base = p.beat
        }
        return pyMod(b - base, phrase)
    }

    static let models: [@Sendable (Track, Int) -> Int] = [gridPhase, phrasePhase]

    /// Whether beat ya in a and beat yb in b sit at the same place in a phrase (either model).
    public static func samePhase(_ a: Track, _ ya: Int, _ b: Track, _ yb: Int) -> Bool {
        models.contains { $0(a, ya) == $0(b, yb) }
    }

    /// Whether both beats start a phrase under the same model.
    public static func bothOnPhrase(_ a: Track, _ ya: Int, _ b: Track, _ yb: Int) -> Bool {
        models.contains { $0(a, ya) == 0 && $0(b, yb) == 0 }
    }

    /// Whether beat b starts a phrase under either model.
    public static func onPhrase(_ t: Track, _ b: Int) -> Bool { models.contains { $0(t, b) == 0 } }

    /// "" on a phrase start, else how far into the phrase b is (Rekordbox's phrases).
    public static func offPhrase(_ t: Track, _ b: Int) -> String {
        onPhrase(t, b) ? "" : "\(phrasePhase(t, b)) beats into a phrase"
    }

    /// The last beat with audio within 20 dB of the track's loud parts.
    public static func lastAudioBeat(_ t: Track) -> Int {
        guard t.fb != nil else { return t.beats.count }
        return t.loudEnd ?? t.beats.count
    }

    /// Where the track's bass ends.
    public static func bassEndBeat(_ t: Track) -> Int {
        let nb = t.beats.count
        guard t.hasFB else { return nb }
        let lo = t.bassLevel
        var b = nb
        while b > nb / 2 {
            let i = max(0, b - 17)
            let j = max(b - 1, 0)
            if Num.mean(lo[min(i, j)..<j]) >= 0.45 { return b }
            b -= 1
        }
        return nb
    }

    /// How a transition lines up.
    public struct Alignment: Sendable, Equatable {
        public var phraseAligned: Bool
        public var endsOnPhrase: Bool
        public var offset: Int
    }

    /// How transition a (out at beat g) -> b (in at beat e) lines up.
    public static func align(_ a: Track, _ g: Int, _ b: Track, _ e: Int) -> Alignment {
        let last = lastAudioBeat(a)
        // B's beat at A's final beat (or just after it): a new phrase there = 'play to the end'
        let ends = onPhrase(b, e + (last - g)) || onPhrase(b, e + (last + 1 - g))
        let off = models.map { pyMod($0(b, e) - $0(a, g), phrase) }.min()!
        return Alignment(phraseAligned: samePhase(a, g, b, e), endsOnPhrase: ends, offset: off)
    }

    // ---------------------------------------------------------------- planning

    /// The bass level (`Track.normLevel`) both sides of a bass swap need: a's over the 16 beats
    /// before it, b's over the 16 after (the level `bassEndBeat` treats as bass).
    static let swapBass = 0.45

    /// Mean of a level over beats [s, t) (1-based; 0 when empty).
    static func meanLevel(_ lo: [Double], _ s: Int, _ t: Int) -> Double {
        let s = max(s, 1)
        let t = min(t, lo.count + 1)
        return t > s ? Num.mean(lo[(s - 1)..<(t - 1)]) : 0
    }

    /// Whether a bass swap at b's beat x (a's beat x - e + g) has bass on both sides: a has bass
    /// going into it and b coming out of it (ADR 0020). True without the audio analysis.
    public static func bassBoth(_ a: Track, _ g: Int, _ b: Track, _ e: Int, _ x: Int) -> Bool {
        guard a.hasFB, b.hasFB else { return true }
        let y = x - e + g
        return meanLevel(a.bassLevel, y - 16, y) >= swapBass
            && meanLevel(b.bassLevel, x, x + 16) >= swapBass
    }

    /// A phrase-aligned bass swap point in b inside the overlap: where b's bass comes in and/or
    /// a's bass drops out, on a phrase start in both tracks, with bass in both (a's before it,
    /// b's after). nil = none.
    static func bassSwap(_ a: Track, _ g: Int, _ b: Track, _ e: Int, _ drops: [Int], _ existing: [Int]) -> (
        Int?, String
    ) {
        let overlapEnd = e + (bassEndBeat(a) - g)  // b's beat when a's bass ends
        let hardEnd = max(overlapEnd, e + (lastAudioBeat(a) - g))  // ... and when a has finished
        // the user's own BASS SWAP wins inside the overlap, phrase-aligned or not, where both
        // tracks have bass
        if let x = existing.first(where: { e + 16 <= $0 && $0 <= hardEnd && bassBoth(a, g, b, e, $0) }) {
            return (x, "existing")
        }
        guard b.hasFB, a.hasFB else { return (nil, "no audio analysis") }
        let lb = b.bassLevel
        let la = a.bassLevel
        let mean = meanLevel
        var bestX = 0
        var bestScore = 0.0
        for limit in [overlapEnd, hardEnd] {
            var x = e + 16
            while x <= min(limit, b.beats.count - 16) {
                defer { x += 1 }
                if !bothOnPhrase(b, x, a, x - e + g) { continue }
                let y = x - e + g  // same moment in a
                if mean(la, y - 16, y) < swapBass || mean(lb, x, x + 16) < swapBass { continue }  // bass both sides
                let score =
                    (mean(lb, x, x + 16) - mean(lb, x - 16, x))
                    + CueRules.pyMax(0, mean(la, y - 16, y) - mean(la, y, y + 16))
                if score >= 0.3 && (bestX == 0 || score > bestScore + 0.15) { (bestX, bestScore) = (x, score) }
            }
            if bestX != 0 { break }
        }
        if bestX == 0 { return (nil, "no clear bass change inside the overlap where both tracks have bass") }
        if drops.contains(where: { abs(bestX - $0) <= 1 }) {
            return (nil, "bass comes in on a drop (beat \(bestX)); no BASS SWAP needed")
        }
        return (bestX, "new")
    }

    /// E for incoming u: the nearest beat at/before e0 with the same phrase position as G in t,
    /// moving earlier only when that is what makes a bass swap fit, or (ADR 0020) when an
    /// earlier one has less vocal overlap or ends the transition before t's last 16 bars:
    /// the candidate with the lowest `cost`.
    static func chooseE(
        _ t: Track, _ g: Int, _ u: Track, _ e0: Int, _ drops: [Int], _ bss: [Int],
        cost: ((Int) -> Double)? = nil
    ) -> Int {
        var cands: [Int] = []
        var c = e0
        while c > CueRules.firstDownbeat(u) - 1 && cands.count < 8 {
            if samePhase(t, g, u, c) { cands.append(c) }
            c -= 1
        }
        if cands.isEmpty, let c = (e0..<e0 + phrase).first(where: { samePhase(t, g, u, $0) }) { cands = [c] }
        if cands.isEmpty { cands = [e0] }
        let fits = cands.filter { c in
            let (bs, why) = bassSwap(t, g, u, c, drops, bss)
            return bs != nil || why.contains("drop")
        }
        guard let first = fits.first else { return cands[0] }
        guard let cost else { return first }
        return fits.min { cost($0) < cost($1) } ?? first  // ties: the first, nearest e0
    }

    // ---------------------------------------------------------------- transition length and vocals (ADR 0020)

    /// A vocal-free loop in a for a transition at g whose vocals clash from beat `clash`: the
    /// longest of 16, 8 or 4 bars that starts on a phrase between 16 bars before g and the clash,
    /// ends by the clash (so a is looping before its vocals come), and has no vocals in a; the
    /// latest such start.
    public static func vocalLoop(_ a: Track, _ g: Int, clash: Int) -> SetAction.Loop? {
        for len in [64, 32, 16] {
            var s = clash - len
            while s >= max(g - 64, 1) {
                if onPhrase(a, s), !(s..<s + len).contains(where: { vocal(a, $0) }) {
                    return SetAction.Loop(beat: s, beats: len)
                }
                s -= 1
            }
        }
        return nil
    }

    /// A transition finishing within this many beats of the outgoing track's end (its last
    /// 16 bars) is late: reported, and costs the most (`endingCost`).
    public static let lateBeats = 64

    /// Where a transition should finish, in bars before the outgoing track's last audible beat
    /// (ADR 0023): anywhere in this range costs nothing.
    public static let bestEnding = 24.0...40.0

    /// What finishing barsLeft bars before the outgoing track's last audible beat costs (ADR
    /// 0023): 2 per bar closer than 24 bars, 4 per bar inside the last 16 (16 at 16 bars, 80
    /// at the end), so tracks aren't played to the end; and, to a lesser degree, 1 per bar
    /// earlier than 40 bars, so they aren't cut short either.
    public static func endingCost(barsLeft l: Double) -> Double {
        let late = Double(lateBeats) / 4
        if l < late { return 2 * (bestEnding.lowerBound - late) + 4 * (late - max(l, 0)) }
        if l < bestEnding.lowerBound { return 2 * (bestEnding.lowerBound - l) }
        return max(l - bestEnding.upperBound, 0)
    }

    /// What a leaving the mix at its beat `end` costs (`endingCost`).
    public static func endingCost(_ a: Track, _ end: Int) -> Double {
        endingCost(barsLeft: Double(lastAudioBeat(a) - end) / 4)
    }

    /// How far G may move (in phrases, either way) from where it starts to finish better or
    /// avoid vocals.
    static let movePhrases = 8

    /// What moving G / E a phrase from where it starts costs: a mild preference for OUT / IN or
    /// the DJ's own cue (ADR 0023); where the transition finishes decides.
    static let gMoveCost = 2.0
    static let eMoveCost = 4.0

    /// The beat of a where it has left the mix (as the previews mix it): its FILTER exit plus the
    /// sweep and fade, its CUT, else 8 beats after the bass swap, else 40 beats after G.
    public static func leaveBeat(_ a: Track, _ g: Int, _ b: Track, _ e: Int, swap: Int?) -> Int {
        let end: Int
        if let ex = exitMarker(a, g, b, e) {
            end = ex.name == "FILTER" ? ex.a + Int(Mix.filterBeats + Mix.filterFadeBeats) : ex.a
        } else if let sw = swap, sw > e {
            end = g + sw - e + Int(Mix.fadeOut)
        } else {
            end = g + 32 + Int(Mix.fadeOut)
        }
        return min(end, max(lastAudioBeat(a), g))
    }

    /// Whether beat b of t has vocals (its bar's confidence at least `Vocals.threshold`).
    static func vocal(_ t: Track, _ b: Int) -> Bool {
        guard let v = t.vocals, b >= 1, b <= v.count else { return false }
        return v[b - 1] >= Vocals.threshold
    }

    /// The beats of a in [g, end) where a's and b's vocals play together, and the first of them.
    public static func vocalOverlap(_ a: Track, _ g: Int, _ b: Track, _ e: Int, until end: Int) -> (
        beats: Int, from: Int?
    ) {
        guard a.vocals != nil, b.vocals != nil, end > g else { return (0, nil) }
        var n = 0
        var from: Int?
        for y in g..<end where vocal(a, y) && vocal(b, e + y - g) {
            n += 1
            if from == nil { from = y }
        }
        return (n, from)
    }

    /// The memory cues where the outgoing track leaves the mix.
    static let exitNames = ["FILTER", "CUT"]

    /// A memory cue's name as `set --write` leaves it (`Config.renameTo` applied).
    public static func memName(_ c: Cue) -> String {
        let to = Config.renameTo(c.name, hot: false)
        return to.isEmpty ? Config.norm(c.name) : to
    }

    /// 'CUT' for 'CUT OUT' on side 'OUT'; plain 'CUT' counts for either side.
    static func markerBase(_ name: String, _ side: String) -> String {
        ["BASS SWAP", "FILTER", "CUT"].first { name == $0 || name == $0 + " " + side } ?? ""
    }

    /// Where a leaves the mix: the first FILTER / CUT (or ... OUT) memory cue at or after G in a,
    /// or FILTER / CUT (or ... IN) at or after E in b while a is still playing. A CUT in b beats
    /// any CUT in a.
    static func exitMarker(_ a: Track, _ g: Int, _ b: Track, _ e: Int) -> Exit? {
        let last = a.beats.count
        var fs: [(beat: Int, name: String, side: String)] = []
        for c in a.cues where c.kind == 0 {
            let n = markerBase(memName(c), "OUT")
            if exitNames.contains(n), beatOf(a, c.t) >= g { fs.append((beatOf(a, c.t), n, "out")) }
        }
        for c in b.cues where c.kind == 0 {
            let n = markerBase(memName(c), "IN")
            let y = beatOf(b, c.t)
            if exitNames.contains(n), e <= y, y <= e + last - g { fs.append((g + y - e, n, "in")) }
        }
        if fs.contains(where: { $0.name == "CUT" && $0.side == "in" }) {
            fs.removeAll { $0.name == "CUT" && $0.side == "out" }
        }
        guard let m = fs.min(by: { ($0.beat, $0.name, $0.side) < ($1.beat, $1.name, $1.side) }) else { return nil }
        return Exit(name: m.name, a: m.beat, b: e + m.beat - g, side: m.side)
    }

    /// An instant mashup: a SYNC (or SYNC OUT) memory cue on a's G, or SYNC (or SYNC IN) on b's
    /// E, within a beat.
    static func sync(_ a: Track, _ g: Int, _ b: Track, _ e: Int) -> Bool {
        func on(_ t: Track, _ beat: Int, _ side: String) -> Bool {
            t.cues.contains { c in
                let n = memName(c)
                return c.kind == 0 && (n == "SYNC" || n == "SYNC " + side) && abs(beatOf(t, c.t) - beat) <= 1
            }
        }
        return on(a, g, "OUT") || on(b, e, "IN")
    }

    /// The transition marker '<base> <side>' that should be on t at beat.
    static func marker(_ t: Track, _ base: String, _ side: String, _ beat: Int) -> SetMarker {
        let near = t.cues.filter { $0.kind == 0 && abs(beatOf(t, $0.t) - beat) <= 1 }.map(memName)
        let name = base + " " + side
        if near.contains(name) { return SetMarker(name: name, beat: beat, status: .existing) }
        if near.contains(base) { return SetMarker(name: name, beat: beat, status: .rename) }
        return SetMarker(name: name, beat: beat, status: .new)
    }

    /// A slot's current cue: the first cue of that kind, with its beat.
    static func slotOf(_ t: Track, _ kind: Int) -> (name: String, beat: Int)? {
        t.cues.first { $0.kind == kind }.map { ($0.name, beatOf(t, $0.t)) }
    }

    static func decideSlot(_ name: String, _ beat: Int, _ cur: (name: String, beat: Int)?, _ matches: Bool) -> Slot {
        guard let cur else { return Slot(name: name, beat: beat, status: .new) }
        if matches && cur.beat == beat { return Slot(name: cur.name, beat: beat, status: .existing) }
        return Slot(name: name, beat: beat, status: .replace, old: Slot.Old(name: cur.name, beat: cur.beat))
    }

    /// Hot cue kinds to the track's last cue of that kind.
    static func lastByKind(_ t: Track) -> [Int: Cue] {
        var m: [Int: Cue] = [:]
        for c in t.cues where c.kind > 0 { m[c.kind] = c }
        return m
    }

    /// Plans the set cues. order: playlist tracks in play order; recs: id -> track; cache: the
    /// transition cache.
    public static func plan(_ order: [PlaylistTrack], _ recs: [String: Track], _ cache: TransitionCache) -> [SetAction]
    {
        var out = order.map { SetAction(id: $0.id, title: $0.title) }
        for (i, x) in order.enumerated() {
            guard let t = recs[x.id] else {
                out[i].warnings.append("no Rekordbox analysis for this track; skipped")
                continue
            }
            out[i].warnings += trackWarnings(t)
            if i == 0 {  // first track: E = START
                let cur = slotOf(t, 6)
                out[i].e = decideSlot("START", CueRules.firstDownbeat(t), cur, cur?.name.uppercased() == "START")
            }
            if i == order.count - 1 {  // last track: no G
                if let cur = slotOf(t, 8) {
                    out[i].g = Slot(
                        name: cur.name, beat: cur.beat, status: .clear, old: Slot.Old(name: cur.name, beat: cur.beat))
                }
                continue
            }
            let nxt = order[i + 1]
            guard let u = recs[nxt.id] else { continue }
            var tr = Transition(
                i: i, x: x, nxt: nxt, t: t, u: u, cached: cache.get(x.id, nxt.id) ?? TransitionCache.Entry())
            tr.plan(&out)
        }
        for (i, x) in order.enumerated() {
            guard let t = recs[x.id], i == order.count - 1 || recs[order[i + 1].id] != nil else { continue }
            out[i].remove = staleCues(t, out[i].markers)
            if !out[i].remove.isEmpty {
                out[i].warnings.append(
                    "memory cue(s) removed on write: "
                        + out[i].remove.map { "\($0.name) @ beat \($0.beat) (\($0.why))" }
                        .joined(separator: ", "))
            }
        }
        return out
    }

    /// Flags a shifted bar 1, cues `set` renames and memory cues with no colour rule.
    static func trackWarnings(_ t: Track) -> [String] {
        var w: [String] = []
        let ps = t.phrases.filter { $0.beat <= t.bnum.count }
        let onBar = ps.filter { pyIndex(t.bnum, $0.beat - 1) == 1 }.count
        if !ps.isEmpty && Double(onBar) / Double(ps.count) < 0.5 {
            w.append(
                "Rekordbox's phrases don't start on this track's bar downbeats: the beat grid's bar 1 is probably shifted; "
                    + "check the downbeat in Rekordbox")
        }
        var renamed: [String] = []
        var odd: [String] = []
        for c in t.cues {
            let to = Config.renameTo(c.name, hot: c.kind > 0)
            if !to.isEmpty {
                renamed.append("'\(c.name)' (\(c.kind != 0 ? "hot cue" : "memory")) @ beat \(beatOf(t, c.t)) -> \(to)")
            }
            if c.kind == 0 && Config.memoryColor[memName(c)] == nil {
                odd.append("'\(c.name.isEmpty ? "(unnamed)" : c.name)' @ beat \(beatOf(t, c.t))")
            }
        }
        if !renamed.isEmpty { w.append("cue(s) renamed on write: " + renamed.joined(separator: ", ")) }
        if !odd.isEmpty {
            w.append(
                "memory cue(s) with no colour rule (expected \(Config.memoryColorOrder.joined(separator: ", "))): "
                    + odd.joined(separator: ", "))
        }
        return w
    }

    /// One A -> B transition: x/t outgoing (track i), nxt/u incoming.
    struct Transition {
        let i: Int
        let x: PlaylistTrack
        let nxt: PlaylistTrack
        let t: Track
        let u: Track
        let cached: TransitionCache.Entry
        var hot: [Int: Cue] = [:]
        var uhot: [Int: Cue] = [:]
        var gCur: (name: String, beat: Int)?
        var eCur: (name: String, beat: Int)?
        var gMatch = false
        var eMatch = false
        var drops: [Int] = []
        var bss: [Int] = []
        var note: [String] = []
        var g = 0
        var e = 0
        var al = Alignment(phraseAligned: false, endsOnPhrase: false, offset: 0)
        /// Where G and E start (the pair's own cue, else the cache, else OUT / IN) and where
        /// that came from ("" for OUT / IN). Any of them may move (ADR 0023).
        var gStart = 0
        var eStart = 0
        var gFrom = ""
        var eFrom = ""

        init(i: Int, x: PlaylistTrack, nxt: PlaylistTrack, t: Track, u: Track, cached: TransitionCache.Entry) {
            (self.i, self.x, self.nxt, self.t, self.u, self.cached) = (i, x, nxt, t, u, cached)
            hot = lastByKind(t)
            uhot = lastByKind(u)
            gCur = slotOf(t, 8)
            eCur = slotOf(u, 6)
            gMatch = gCur.map { namesMatch($0.name, nxt.title) } ?? false
            eMatch = eCur.map { namesMatch($0.name, x.title) } ?? false
            for c in u.cues where c.kind == 0 {
                if c.name.uppercased() == "DROP" { drops.append(beatOf(u, c.t)) }
                if markerBase(memName(c), "IN") == "BASS SWAP" { bss.append(beatOf(u, c.t)) }
            }
        }

        mutating func plan(_ out: inout [SetAction]) {
            chooseG(&out)
            chooseE(&out)
            moveG()
            slots(&out)
            markers(&out)
            vocals(&out)
        }

        /// The swap beat in u for transition (g, e): the BASS SWAP, else the drop it would sit on.
        func swapAt(_ g: Int, _ e: Int) -> Int? {
            let (bs, why) = bassSwap(t, g, u, e, drops, bss)
            if let bs { return bs }
            return why.firstMatch(of: /on a drop \(beat (\d+)\)/).flatMap { Int($0.1) }
        }

        /// What transition (g, e) costs (ADR 0020, 0023): beats of vocal overlap, where t leaves
        /// the mix (`endingCost`), and moving G or E from where they start.
        func cost(_ g: Int, _ e: Int, g0: Int, e0: Int) -> Double {
            let end = leaveBeat(t, g, u, e, swap: swapAt(g, e))
            let vox = Double(vocalOverlap(t, g, u, e, until: end).beats)
            return 2 * vox + endingCost(t, end) + gMoveCost * Double(abs(g0 - g)) / Double(phrase)
                + eMoveCost * Double(abs(e0 - e)) / Double(phrase)
        }

        /// Tries G up to 8 phrases either side of where it starts, and of the OUT hot cue (not
        /// before A's DROP hot cue + 8 bars nor its first half), when that finishes the
        /// transition nearer `bestEnding` or with less vocal overlap.
        mutating func moveG() {
            guard al.phraseAligned || al.endsOnPhrase else { return }
            let (g0, e0) = (g, e)
            let lowest = max(hot[3].map { beatOf(t, $0.t) + 32 } ?? 0, t.beats.count / 2)
            let highest = lastAudioBeat(t) - phrase
            var best = (g: g0, e: e0, cost: cost(g0, e0, g0: gStart, e0: eStart))
            let me = self
            var tried: Set<Int> = [g0]
            let starts = [g0] + (hot[5].map { [beatOf(t, $0.t)] } ?? [])
            for s in starts {
                for k in -SetPlanner.movePhrases...SetPlanner.movePhrases {
                    let gc = s + phrase * k
                    guard gc >= lowest, gc <= highest, tried.insert(gc).inserted else { continue }
                    let ec = SetPlanner.chooseE(t, gc, u, eStart, drops, bss) {
                        me.cost(gc, $0, g0: me.gStart, e0: me.eStart)
                    }
                    let a = align(t, gc, u, ec)
                    guard a.phraseAligned || a.endsOnPhrase else { continue }
                    let c = cost(gc, ec, g0: gStart, e0: eStart)
                    if c < best.cost - 1e-9 { best = (gc, ec, c) }
                }
            }
            guard best.g != g0 else { return }
            let before = leaveBeat(t, g0, u, e0, swap: swapAt(g0, e0))
            let after = leaveBeat(t, best.g, u, best.e, swap: swapAt(best.g, best.e))
            var why: [String] = []
            let last = lastAudioBeat(t)
            if before != after {
                why.append("finishes \((last - after) / 4) bars before the end (was \((last - before) / 4))")
            }
            let vb = vocalOverlap(t, g0, u, e0, until: before).beats
            let va = vocalOverlap(t, best.g, u, best.e, until: after).beats
            if va < vb { why.append(va == 0 ? "no vocal overlap" : "less vocal overlap (\(vb / 4) -> \(va / 4) bars)") }
            (g, e) = (best.g, best.e)
            al = align(t, g, u, e)
            let bars = abs(g0 - g) / 4
            let src = gFrom.isEmpty ? "" : " than \(gFrom)"
            note.append(
                "G moved \(bars) bars \(g < g0 ? "earlier" : "later")\(src) (beat \(g0) -> \(g))"
                    + (why.isEmpty ? "" : ": " + why.joined(separator: ", ")))
        }

        /// Flags vocals that still overlap (8 beats or more) after the choice above.
        func vocals(_ out: inout [SetAction]) {
            let end = leaveBeat(t, g, u, e, swap: out[i + 1].swap)
            let (n, from) = vocalOverlap(t, g, u, e, until: end)
            guard n >= 8, let from else { return }
            out[i + 1].vocalOverlap = n
            let why = "no nearby transition point avoids it"
            let loop = vocalLoop(t, g, clash: from)
            out[i + 1].vocalLoop = loop
            let hint =
                loop.map {
                    "; loop \(x.title)'s beats \($0.beat)-\($0.beat + $0.beats - 1) (\($0.beats / 4) bars, no vocals) "
                        + "to hold it while \(nxt.title)'s vocals play"
                } ?? "; no vocal-free 4-bar stretch to loop near G"
            out[i + 1].warnings.append(
                "vocal overlap: \(x.title) and \(nxt.title) both have vocals for \(n / 4) bar(s) of the transition "
                    + "(from \(x.title)'s beat \(from)); \(why)\(hint)")
        }

        /// G's start: the pair's own G (in place, else cached), else the outgoing OUT. It may
        /// still move (`moveG`).
        mutating func chooseG(_ out: inout [SetAction]) {
            if gMatch, let gc = gCur {
                (g, gFrom) = (gc.beat, "G '\(gc.name)'")
            } else if let gms = cached.gMS {
                (g, gFrom) = (beatOf(t, Double(gms) / 1000), "the transition cache")
            } else if let d = hot[5] {
                g = beatOf(t, d.t)
            } else {
                g = CueRules.hotCues(t, .default)["OUT"]!
            }
            gStart = g
        }

        func inOf(_ fallback: () -> Int) -> Int { uhot[1].map { beatOf(u, $0.t) } ?? fallback() }

        /// E: from where it starts (the pair's own E, else cached, else IN), the nearest beat
        /// with G's phrase position where a bass swap fits, by the same cost.
        mutating func chooseE(_ out: inout [SetAction]) {
            if eMatch, let ec = eCur {
                (eStart, eFrom) = (ec.beat, "E '\(ec.name)'")
            } else if let ems = cached.eMS {
                (eStart, eFrom) = (beatOf(u, Double(ems) / 1000), "the transition cache")
            } else {
                let u = self.u
                eStart = inOf { CueRules.hotCues(u, .default)["IN"]! }
            }
            let g = self.g
            let me = self
            e = SetPlanner.chooseE(t, g, u, eStart, drops, bss) { me.cost(g, $0, g0: me.gStart, e0: me.eStart) }
            al = align(t, g, u, e)
            if al.phraseAligned || al.endsOnPhrase { return }
            let oldE = e
            let offset = al.offset
            e = SetPlanner.chooseE(t, g, u, inOf { oldE }, drops, bss)
            al = align(t, g, u, e)
            note.append(
                "E at beat \(oldE) was \(min(offset, phrase - offset)) beats off the phrase; fixed to beat \(e)")
            if !al.phraseAligned && !al.endsOnPhrase { note.append("still not phrase-aligned; check the beat grids") }
        }

        /// Notes where G and E ended up against an existing cue they started from, and flags
        /// one kept off the phrase.
        func origins(_ out: inout [SetAction]) -> [String] {
            var n: [String] = []
            for (name, from, start, now, track, who) in [
                ("G", gFrom, gStart, g, t, i), ("E", eFrom, eStart, e, u, i + 1),
            ] where !from.isEmpty {
                if now != start {
                    if name == "E" { n.append("E moved from \(from) (beat \(start) -> \(now))") }  // G: moveG's note
                    continue
                }
                if from == "the transition cache" { n.append("\(name) restored from the transition cache") }
                let off = offPhrase(track, now)
                if !off.isEmpty {
                    out[who].warnings.append("\(from) at beat \(now) is off-phrase (\(off)); kept, check it")
                }
            }
            if gFrom.isEmpty, let d = hot[5], beatOf(t, d.t) == g {
                let off = offPhrase(t, g)
                if !off.isEmpty {
                    out[i].warnings.append(
                        "OUT hot cue '\(d.name)' at beat \(g) is off-phrase (\(off)); kept, check it")
                }
            }
            return n
        }

        /// Decides the G and E slots and reports the notes.
        func slots(_ out: inout [SetAction]) {
            let gName = gMatch ? gCur!.name : cueName(nxt.title)
            out[i].g = decideSlot(gName, g, gCur, gMatch)
            let eName = eMatch && eCur!.beat == e ? eCur!.name : cueName(x.title)
            out[i + 1].e = decideSlot(eName, e, eCur, eMatch)
            for (slot, title, act, who) in [("G", nxt.title, out[i].g!, i), ("E", x.title, out[i + 1].e!, i + 1)]
            where act.status == .replace {
                if let old = act.old, !namesMatch(old.name, title) {
                    out[who].warnings.append(
                        "\(slot) '\(old.name)' (another set) replaced; saved in the transition cache")
                }
            }
            for n in origins(&out) + note { out[i + 1].warnings.append("\(x.title) -> \(nxt.title): \(n)") }
        }

        /// Places the bass swap and the BASS SWAP / exit / SYNC markers on both tracks.
        func markers(_ out: inout [SetAction]) {
            let (bs, why) = bassSwap(t, g, u, e, drops, bss)
            out[i + 1].bassSwap = BassSwap(beat: bs, why: why)
            let hardEnd = max(e + bassEndBeat(t) - g, e + lastAudioBeat(t) - g)
            for sw in bss where sw != bs && e + 16 <= sw && sw <= hardEnd && !bassBoth(t, g, u, e, sw) {
                out[i + 1].warnings.append(
                    "BASS SWAP at beat \(sw) not used: both tracks need bass there (\(x.title) before it, "
                        + "\(nxt.title) after it)")
            }
            out[i + 1].hasIncoming = true
            if let bs {
                out[i + 1].swap = bs
            } else if let m = why.firstMatch(of: /on a drop \(beat (\d+)\)/) {
                out[i + 1].swap = Int(m.1)
            }
            if let bs { out[i + 1].markers.append(marker(u, "BASS SWAP", "IN", bs)) }
            if why == "existing", let bs, !bothOnPhrase(u, bs, t, bs - e + g) {
                var offs: [String] = []
                let oa = offPhrase(t, bs - e + g)
                if !oa.isEmpty { offs.append("\(x.title) (\(oa))") }
                let ob = offPhrase(u, bs)
                if !ob.isEmpty { offs.append("\(nxt.title) (\(ob))") }
                if offs.isEmpty { offs = ["the two tracks' phrases don't line up there"] }
                out[i + 1].warnings.append(
                    "BASS SWAP at beat \(bs) is off-phrase in \(offs.joined(separator: ", ")); kept, check it")
            }
            if let sw = out[i + 1].swap {  // the outgoing track's bass leaves at the same moment
                out[i].markers.append(marker(t, "BASS SWAP", "OUT", g + sw - e))
            }
            if let ex = exitMarker(t, g, u, e) {
                out[i].exit = ex
                out[i].markers.append(marker(t, ex.name, "OUT", ex.a))
                out[i + 1].markers.append(marker(u, ex.name, "IN", ex.b))
            }
            if sync(t, g, u, e) {
                out[i + 1].sync = true
                out[i].markers.append(marker(t, "SYNC", "OUT", g))
                out[i + 1].markers.append(marker(u, "SYNC", "IN", e))
            }
            if let bs, why == "new", bs - e + g > bassEndBeat(t) {
                out[i + 1].warnings.append("BASS SWAP at beat \(bs) comes after \(x.title)'s bass has ended")
            }
            if !al.phraseAligned && al.endsOnPhrase {
                out[i + 1].warnings.append(
                    "\(x.title) -> \(nxt.title): not phrase-aligned during the overlap; works only if \(x.title) plays to "
                        + "the end (a new phrase starts on its last beat)")
            }
        }
    }

    /// The memory cues `set --write` deletes from t: a CUT OUT more than a beat from this set's
    /// CUT OUT marker, and a JUMP on the same beat as a JUMP hot cue (a duplicate).
    static func staleCues(_ t: Track, _ markers: [SetMarker]) -> [SetAction.Removal] {
        let cutOut = markers.filter { $0.name == "CUT OUT" }.map(\.beat)
        var pads = Set<Int>()
        for c in t.cues where c.kind > 0 {
            let to = Config.renameTo(c.name, hot: true)
            if (to.isEmpty ? Config.norm(c.name) : to) == "JUMP" { pads.insert(beatOf(t, c.t)) }
        }
        var out: [SetAction.Removal] = []
        for c in t.cues where c.kind == 0 {
            let n = memName(c)
            let b = beatOf(t, c.t)
            if n == "CUT OUT" && !cutOut.contains(where: { abs(b - $0) <= 1 }) {
                out.append(.init(name: n, beat: b, why: "no CUT IN on the next track there"))
            } else if n == "JUMP" && pads.contains(b) {
                out.append(.init(name: n, beat: b, why: "same beat as the JUMP hot cue"))
            }
        }
        return out
    }

    /// The actions as the cue writer takes them.
    public static func toDB(_ acts: [SetAction]) -> [SetCues] {
        acts.map { a in
            var c = SetCues(id: a.id, title: a.title)
            c.e = a.e.map { SetSlot(name: $0.name, beat: $0.beat, status: $0.status) }
            c.g = a.g.map { SetSlot(name: $0.name, beat: $0.beat, status: $0.status) }
            c.markers = a.markers
            c.remove = a.remove.map { SetMarker(name: $0.name, beat: $0.beat, status: .existing) }
            return c
        }
    }
}
