// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// Renders simple, original house tracks for the demo set: kick, clap and hats, an off-beat
/// bass, chord stabs, a breakdown pad and a pluck lead, arranged in 16-bar phrases the way a
/// DJ-friendly extended mix is (port of internal/demo/synth). Rendering is deterministic: the
/// same Song gives the same samples.
public enum Synth {
    /// The sample rate.
    public static let sr = 44100.0

    /// A track's arrangement in bars, in order: intro (drums), groove (+ stabs, and the bass
    /// from its ninth bar), main (+ lead at the end), breakdown (no kick or bass; build over
    /// the last 4 bars), drop (everything) and outro (drums; the bass stops 8 bars before the
    /// end).
    public struct Layout: Sendable, Equatable {
        public var intro, groove, main, breakdown, drop, outro: Int

        public init(intro: Int, groove: Int, main: Int, breakdown: Int, drop: Int, outro: Int) {
            (self.intro, self.groove, self.main, self.breakdown, self.drop, self.outro) =
                (intro, groove, main, breakdown, drop, outro)
        }

        /// The arranged length in bars.
        public var bars: Int { intro + groove + main + breakdown + drop + outro }

        /// The section starts.
        public var sections: Sections {
            let g = intro
            let m = g + groove
            let b = m + main
            let d = b + breakdown
            let o = d + drop
            return Sections(groove: g, main: m, breakdown: b, drop: d, outro: o, end: o + outro)
        }
    }

    /// A Layout's bar boundaries.
    public struct Sections: Sendable, Equatable {
        public var groove, main, breakdown, drop, outro, end: Int
    }

    /// A bass root and a voicing (MIDI notes).
    public struct Chord: Sendable, Equatable {
        public var root: Double
        public var notes: [Double]
    }

    /// A lead note: step counts 16ths from the start of a 4-bar loop.
    public struct Note: Sendable, Equatable {
        public var step, midi, len: Double
    }

    /// A bass hit within a bar: step (16ths), interval above the octave-up root, length in 16ths
    /// and gain.
    public struct Hit: Sendable, Equatable {
        public var step, interval, len, gain: Double
    }

    /// Everything that makes one track.
    public struct Song: Sendable, Equatable {
        public var bpm: Double
        /// Semitones applied to every note.
        public var transpose = 0.0
        public var seed: UInt64
        /// One chord per bar, looped.
        public var prog: [Chord]
        /// A 4-bar loop.
        public var lead: [Note]
        /// Per bar.
        public var bass: [Hit]
        public var stabs: [Double]
        /// Stab low-pass when fully open (Hz), 0 for 1800.
        public var stabCut = 0.0
        public var layout: Layout
    }

    /// Renders the song as two channels, peak-normalised to -1 dBFS.
    public static func render(_ s: Song) -> Stereo {
        var r = Renderer(s)
        return r.render()
    }

    static func mtof(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
}

/// A seeded random source (SplitMix64): the same seed gives the same song.
struct SeededRandom {
    var state: UInt64

    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in [0, 1).
    mutating func float() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// A pair of sample buffers.
final class Bus {
    var l: [Double]
    var r: [Double]

    init(_ n: Int) {
        l = [Double](repeating: 0, count: n)
        r = l
    }

    /// Mixes v into sample i with an equal-power pan (-1 left .. 1 right).
    func add(_ i: Int, _ v: Double, _ pan: Double) {
        if i < 0 || i >= l.count { return }
        l[i] += v * cos((pan + 1) * .pi / 4)
        r[i] += v * sin((pan + 1) * .pi / 4)
    }
}

/// A TPT state-variable filter (Zavalishin).
struct SVF {
    var ic1 = 0.0
    var ic2 = 0.0

    mutating func run(_ x: Double, _ fcIn: Double, _ q: Double) -> (lp: Double, bp: Double, hp: Double) {
        let fc = min(max(fcIn, 20), Synth.sr * 0.45)
        let g = tan(.pi * fc / Synth.sr)
        let k = 1 / q
        let a1 = 1 / (1 + g * (g + k))
        let a2 = g * a1
        let a3 = g * a2
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, v1, x - k * v1 - v2)
    }
}

/// A band-limited saw (polyBLEP keeps the aliasing down).
struct Saw {
    var ph = 0.0

    static func polyblep(_ t: Double, _ dt: Double) -> Double {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1
        }
        if t > 1 - dt {
            let x = (t - 1) / dt
            return x * x + x + x + 1
        }
        return 0
    }

    mutating func next(_ f: Double) -> Double {
        let dt = f / Synth.sr
        let v = 2 * ph - 1 - Self.polyblep(ph, dt)
        ph += dt
        if ph >= 1 { ph -= 1 }
        return v
    }
}

/// A small stereo Freeverb.
struct Reverb {
    struct Comb {
        var buf: [Double]
        var i = 0
        var fb: Double
        var damp: Double
        var lp = 0.0

        mutating func run(_ x: Double) -> Double {
            let y = buf[i]
            lp = y * (1 - damp) + lp * damp
            buf[i] = x + lp * fb
            i = (i + 1) % buf.count
            return y
        }
    }

    struct Allpass {
        var buf: [Double]
        var i = 0

        mutating func run(_ x: Double) -> Double {
            let b = buf[i]
            buf[i] = x + b * 0.5
            i = (i + 1) % buf.count
            return -x + b
        }
    }

    var cl: [Comb] = []
    var cr: [Comb] = []
    var al: [Allpass] = []
    var ar: [Allpass] = []

    init(room: Double, damp: Double) {
        for n in [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617] {
            cl.append(Comb(buf: [Double](repeating: 0, count: n), fb: room, damp: damp))
            cr.append(Comb(buf: [Double](repeating: 0, count: n + 23), fb: room, damp: damp))
        }
        for n in [556, 441, 341, 225] {
            al.append(Allpass(buf: [Double](repeating: 0, count: n)))
            ar.append(Allpass(buf: [Double](repeating: 0, count: n + 23)))
        }
    }

    mutating func run(_ xIn: Double) -> (Double, Double) {
        let x = xIn * 0.015
        var l = 0.0
        var r = 0.0
        for i in cl.indices {
            l += cl[i].run(x)
            r += cr[i].run(x)
        }
        for i in al.indices {
            l = al[i].run(l)
            r = ar[i].run(r)
        }
        return (l, r)
    }
}

/// Renders one song into its buses.
struct Renderer {
    let s: Synth.Song
    let sec: Synth.Sections
    var rng: SeededRandom
    let stepLen: Double
    let cut: Double
    let n: Int
    let drums, bass, stabs, pads, lead, fx: Bus
    var kicks: [Int] = []

    init(_ s: Synth.Song) {
        self.s = s
        sec = s.layout.sections
        rng = SeededRandom(s.seed)
        stepLen = Synth.sr * 60 / s.bpm / 4
        cut = s.stabCut == 0 ? 1800 : s.stabCut
        n = Int(Double(sec.end) * 16 * stepLen) + Int(2 * Synth.sr)
        (drums, bass, stabs, pads, lead, fx) = (Bus(n), Bus(n), Bus(n), Bus(n), Bus(n), Bus(n))
    }

    func at(_ bar: Double, _ step: Double) -> Int { Int((bar * 16 + step) * stepLen) }

    static func within(_ bar: Int, _ a: Int, _ b: Int) -> Bool { bar >= a && bar < b }

    mutating func render() -> Stereo {
        // one bar at a time, every part in a fixed order: the parts share the random source
        for bar in 0..<sec.end {
            drumBar(bar)
            bassBar(bar)
            stabBar(bar)
            padBar(bar)
            leadBar(bar)
        }
        build()
        return mixdown()
    }

    /// The kick (not in the breakdown), claps from bar 8, off-beat hats (back for the build),
    /// 16th hats from bar 4 and an open hat where the groove is full.
    mutating func drumBar(_ bar: Int) {
        let fb = Double(bar)
        if !Self.within(bar, sec.breakdown, sec.drop) {
            for beat in 0..<4 {
                let p = at(fb, Double(beat * 4))
                kick(drums, p, 0.8)
                kicks.append(p)
            }
        }
        if Self.within(bar, 8, sec.breakdown) || Self.within(bar, sec.drop, sec.end) {
            clap(drums, at(fb, 4), 0.55, 0)
            clap(drums, at(fb, 12), 0.55, 0)
        }
        if !Self.within(bar, sec.breakdown, sec.drop - 4) {
            for beat in 0..<4 { hat(drums, at(fb, Double(beat * 4 + 2)), 0.045, 0.32, 0.25) }
        }
        if Self.within(bar, 4, sec.breakdown) || Self.within(bar, sec.drop, sec.end) {
            for st in 0..<16 where st % 4 != 2 {
                hat(drums, at(fb, Double(st)), 0.018, st % 2 == 1 ? 0.11 : 0.07, -0.3)
            }
        }
        if Self.within(bar, sec.groove, sec.breakdown) || Self.within(bar, sec.drop, sec.end - 8) {
            hat(drums, at(fb, 14), 0.16, 0.13, 0.4)
        }
    }

    /// The bass comes in 8 bars after the groove starts, so a DJ has room to swap it in, and
    /// stops 8 bars before the end.
    mutating func bassBar(_ bar: Int) {
        if !Self.within(bar, sec.groove + 8, sec.breakdown) && !Self.within(bar, sec.drop, sec.end - 8) { return }
        let c = s.prog[bar % 4]
        for h in s.bass {
            bassNote(
                bass, at(Double(bar), h.step), c.root + 12 + h.interval + s.transpose, h.len * stepLen / Synth.sr,
                h.gain)
        }
    }

    /// The chord stabs. Their filter opens through the groove and the end of the breakdown,
    /// and closes over the last 8 bars.
    mutating func stabBar(_ bar: Int) {
        if !Self.within(bar, sec.groove, sec.breakdown) && !Self.within(bar, sec.drop - 8, sec.end) { return }
        var fc = cut
        if bar < sec.main { fc = 500 + (cut - 500) * Double(bar - sec.groove) / Double(sec.main - sec.groove) }
        if Self.within(bar, sec.drop - 8, sec.drop) { fc = 400 + (cut - 400) * Double(bar - (sec.drop - 8)) / 8 }
        if bar >= sec.end - 8 { fc = cut - (cut - 500) * Double(bar - (sec.end - 8)) / 8 }
        for st in s.stabs {
            let d = (st == 0 ? 2.5 : 1.2) * stepLen / Synth.sr
            for m in s.prog[bar % 4].notes {
                synthNote(stabs, at(Double(bar), st), m + s.transpose, d, 0.30, fc, 1.1, 0.002, 0.12, 2, 9)
            }
        }
    }

    /// The pad holds the chord through the breakdown, and quietly under the drop.
    mutating func padBar(_ bar: Int) {
        if !Self.within(bar, sec.breakdown - 4, sec.outro) { return }
        let g = Self.within(bar, sec.breakdown, sec.drop) ? 0.32 : 0.13
        for m in s.prog[bar % 4].notes {
            synthNote(
                pads, at(Double(bar), 0), m + s.transpose, 16 * stepLen / Synth.sr, g, 2600, 0.8, 0.35, 0.8, 3, 14)
        }
    }

    /// The lead is teased over the end of the main section, then plays through the breakdown
    /// and the drop.
    mutating func leadBar(_ bar: Int) {
        if !Self.within(bar, sec.breakdown - 8, sec.breakdown) && !Self.within(bar, sec.breakdown + 4, sec.outro) {
            return
        }
        let g = bar < sec.breakdown ? 0.12 : 0.24
        for m in s.lead where Int(m.step) / 16 == bar % 4 {
            let p = at(Double(bar), m.step.truncatingRemainder(dividingBy: 16))
            synthNote(lead, p, m.midi + s.transpose, m.len * stepLen / Synth.sr * 0.7, g, 3800, 1.6, 0.003, 0.25, 2, 6)
        }
    }

    /// A noise riser and a clap roll over the last 4 bars of the breakdown.
    mutating func build() {
        let drop = sec.drop
        var f = SVF()
        let a = at(Double(drop - 4), 0)
        let b = at(Double(drop), 0)
        for i in a..<b {
            let p = Double(i - a) / Double(b - a)
            let bp = f.run(rng.float() * 2 - 1, 300 * pow(30, p), 2).bp
            fx.add(i, bp * p * p * 0.5, 0)
        }
        for k in 0..<4 {
            let div = [4, 4, 2, 1][k]
            for st in stride(from: 0, to: 16, by: div) {
                clap(fx, at(Double(drop - 4 + k), Double(st)), 0.2 + 0.3 * Double(k * 16 + st) / 64, 0)
            }
        }
    }

    /// Sidechains the music to the kick, adds a ping-pong delay to the lead and reverb to
    /// everything melodic, soft-clips and normalises.
    mutating func mixdown() -> Stereo {
        let beatLen = stepLen * 4
        var duck = [Double](repeating: 1, count: n)
        let rel = Int(beatLen * 0.6)
        for k in kicks {
            for i in 0..<rel where k + i < n {
                let x = 1 - Double(i) / Double(rel)
                duck[k + i] = min(duck[k + i], 1 - 0.7 * x * x)
            }
        }
        let dl = Int(beatLen * 0.75)
        if dl < n {
            for i in dl..<n {
                lead.l[i] += lead.r[i - dl] * 0.38
                lead.r[i] += lead.l[i - dl] * 0.38
            }
        }
        var rv = Reverb(room: 0.86, damp: 0.35)
        var hpL = SVF()
        var hpR = SVF()
        var outL = [Double](repeating: 0, count: n)
        var outR = outL
        let norm = tanh(1.1)
        for i in 0..<n {
            let d = duck[i]
            let send =
                (stabs.l[i] + stabs.r[i]) * 0.5 + (pads.l[i] + pads.r[i]) * 0.9 + (lead.l[i] + lead.r[i]) * 0.6
                + (drums.l[i] + drums.r[i]) * 0.08 + fx.l[i] * 0.4
            let (wl, wr) = rv.run(send)
            var l =
                drums.l[i] + bass.l[i] * d + (stabs.l[i] + pads.l[i]) * d + lead.l[i] * (0.4 + 0.6 * d) + fx.l[i]
                + wl * 1.1 * d
            var r =
                drums.r[i] + bass.r[i] * d + (stabs.r[i] + pads.r[i]) * d + lead.r[i] * (0.4 + 0.6 * d) + fx.r[i]
                + wr * 1.1 * d
            l = hpL.run(l, 25, 0.7).hp
            r = hpR.run(r, 25, 0.7).hp
            outL[i] = tanh(l * 1.1) / norm
            outR[i] = tanh(r * 1.1) / norm
        }
        var peak = 0.0
        for i in 0..<n { peak = max(peak, abs(outL[i]), abs(outR[i])) }
        let g = 0.89 / peak
        return Stereo(l: outL.map { Float($0 * g) }, r: outR.map { Float($0 * g) })
    }

    // ---------------------------------------------------------------- voices

    mutating func kick(_ b: Bus, _ start: Int, _ gain: Double) {
        var ph = 0.0
        for i in 0..<Int(0.3 * Synth.sr) {
            let t = Double(i) / Synth.sr
            ph += 2 * .pi * (50 + 110 * exp(-t * 30)) / Synth.sr
            let v = (sin(ph) * exp(-t * 14) + exp(-t * 900) * 0.6 * rng.float() * 0.2) * gain
            b.add(start + i, tanh(v * 1.6), 0)
        }
    }

    mutating func clap(_ b: Bus, _ start: Int, _ gain: Double, _ pan: Double) {
        var f = SVF()
        for i in 0..<Int(0.3 * Synth.sr) {
            let t = Double(i) / Synth.sr
            var env = exp(-t * 18)
            for o in [0, 0.011, 0.022] where t >= o && t < o + 0.01 { env += exp(-(t - o) * 300) * 0.8 }
            let bp = f.run(rng.float() * 2 - 1, 1300, 1.2).bp
            b.add(start + i, bp * env * gain, pan)
        }
    }

    mutating func hat(_ b: Bus, _ start: Int, _ decay: Double, _ gain: Double, _ pan: Double) {
        var f = SVF()
        for i in 0..<Int(decay * 6 * Synth.sr) {
            let t = Double(i) / Synth.sr
            let hp = f.run(rng.float() * 2 - 1, 7500, 0.9).hp
            b.add(start + i, hp * exp(-t / decay) * gain, pan)
        }
    }

    /// Detuned saws through a low-pass with an amp envelope.
    mutating func synthNote(
        _ b: Bus, _ start: Int, _ midi: Double, _ dur: Double, _ gain: Double, _ cutoff: Double, _ res: Double,
        _ attack: Double, _ release: Double, _ voices: Int, _ spread: Double
    ) {
        let count = Int((dur + release) * Synth.sr)
        var oscs = (0..<voices).map { _ in Saw(ph: rng.float()) }
        var fl = SVF()
        var fr = SVF()
        let f0 = Synth.mtof(midi)
        let detune = (0..<voices).map { f0 * pow(2, ((Double($0) - Double(voices - 1) / 2) * spread) / 1200) }
        let pans = (0..<voices).map { voices > 1 ? Double($0) / Double(voices - 1) : 0.5 }
        for i in 0..<count {
            let t = Double(i) / Synth.sr
            let env = t < attack ? t / attack : t < dur ? 1 : exp(-(t - dur) / (release / 4))
            var l = 0.0
            var r = 0.0
            for k in 0..<voices {
                let v = oscs[k].next(detune[k])
                l += v * (1 - pans[k])
                r += v * pans[k]
            }
            let fc = cutoff * (0.6 + 0.4 * exp(-t * 6))
            let ll = fl.run(l, fc, res).lp
            let rl = fr.run(r, fc, res).lp
            let g = env * gain / Double(voices)
            let j = i + start
            if j >= 0 && j < b.l.count {
                b.l[j] += ll * g
                b.r[j] += rl * g
            }
        }
    }

    func bassNote(_ b: Bus, _ start: Int, _ midi: Double, _ dur: Double, _ gain: Double) {
        var o = Saw()
        var f = SVF()
        let f0 = Synth.mtof(midi)
        var sub = 0.0
        for i in 0..<Int((dur + 0.05) * Synth.sr) {
            let t = Double(i) / Synth.sr
            var env = 1.0
            if t < 0.004 { env = t / 0.004 }
            if t > dur { env = exp(-(t - dur) * 60) }
            sub += .pi * f0 / Synth.sr  // an octave down: the weight below 100 Hz
            let lp = f.run(o.next(f0), 260 + 900 * exp(-t * 14), 1.4).lp
            b.add(start + i, (lp * 0.6 + sin(sub) * 1.4) * env * gain, 0)
        }
    }
}
