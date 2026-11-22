// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Accelerate
import Foundation
import Testing

@testable import AutoDJKit

@Suite struct PreviewTests {
    typealias T = TestTrack

    func near(_ a: Double?, _ b: Double) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= 1e-6 * max(1, abs(b))
    }

    func nearAll(_ a: [Double], _ b: [Double]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { near($0, $1) } }

    /// A (120 BPM) -> B (125 BPM), 160 beats each, 80 s of audio.
    func mixPair(_ exit: Exit?) -> (Track, Track, [PlaylistTrack], [SetAction]) {
        var a = T.synth(T.Options(nb: 160, bpm: 120))
        var b = T.synth(T.Options(nb: 160, bpm: 125))
        a.path = "/a.wav"
        b.path = "/b.wav"
        a.length = 80
        b.length = 80
        b.id = "2"
        let order = [
            PlaylistTrack(no: 1, id: "1", title: "A", bpm: 120, key: ""),
            PlaylistTrack(no: 2, id: "2", title: "B", bpm: 125, key: ""),
        ]
        var x = SetAction(id: "1", title: "A")
        x.e = Slot(name: "START", beat: 1, status: .new)
        x.g = Slot(name: "B", beat: 97, status: .new)
        x.exit = exit
        var y = SetAction(id: "2", title: "B")
        y.e = Slot(name: "A", beat: 17, status: .new)
        y.swap = 33
        return (a, b, order, [x, y])
    }

    let all: (Track?) -> Bool = { $0 != nil }

    @Test func mixTimelineFilter() {
        let (a, b, order, acts) = mixPair(Exit(name: "FILTER", a: 113, b: 33, side: "out"))
        let segs = Timeline.mix(order, acts, ["1": a, "2": b], bpm: 0, audioExists: all)
        let (sa, sb) = (segs[0], segs[1])
        let spb = 0.5  // 120 BPM
        #expect(near(sb.start, 96 * spb))  // B's E plays at A's G
        #expect(sa.exit.kind == .filter)
        #expect(nearAll(sa.exit.xs, [112 * spb, 120 * spb, 124 * spb]))  // 8-beat sweep, 4-beat fade
        #expect(sa.end == sa.exit.xs[2] && sb.clock.split == sa.end)  // B back to its own tempo after
        #expect(near(sb.fadeIn?.0, 96 * spb) && near(sb.fadeIn?.1, 104 * spb) && !sb.sync)
        #expect(near(sb.clock.rate, 120.0 / 125))
        #expect(near(sa.swapT, (96 + 16) * spb) && near(sb.bassIn, sa.swapT!))
        #expect(near(sa.bassOut, sa.swapT!))
        #expect(sb.exit.kind == .end && sb.exit.xs[0] == sb.end)
    }

    @Test func mixTimelineFixedTempo() {
        let (a, b, order, acts) = mixPair(Exit(name: "FILTER", a: 113, b: 33, side: "out"))
        let recs = ["1": a, "2": b]
        let segs = Timeline.mix(order, acts, recs, bpm: 128, audioExists: all)
        let (sa, sb) = (segs[0], segs[1])
        let spb = 60.0 / 128
        #expect(near(sa.clock.rate, 128.0 / 120) && near(sa.clock.own, 128.0 / 120))
        #expect(near(sb.clock.rate, 128.0 / 125) && near(sb.clock.own, 128.0 / 125) && sb.clock.split == sb.start)
        #expect(near(sb.start, 96 * spb))
        #expect(nearAll(sa.exit.xs, [112 * spb, 120 * spb, 124 * spb]))
        #expect(near(sa.swapT, (96 + 16) * spb))
        #expect(near(sb.end, sb.start + (80 - 16 * 60.0 / 125) * 125 / 128))  // B's audio from E, at 128
        let (pa, pb) = Timeline.pair(order, acts, recs, bpm: 128, audioExists: all)
        #expect(near(pb.start, Double(Mix.lead) * spb) && near(pb.end, pa.end + Mix.tail * spb))
    }

    @Test func mixTimelineCutAndMissingAudio() {
        let (a, b, order, acts) = mixPair(Exit(name: "CUT", a: 105, b: 25, side: "out"))
        let recs = ["1": a, "2": b]
        var segs = Timeline.mix(order, acts, recs, bpm: 0) { $0?.id == "1" }
        #expect(segs[1].missing && segs[0].exit.kind == .end && segs[0].exit.xs[0] == segs[0].end)  // A plays out
        segs = Timeline.mix(order, acts, recs, bpm: 0, audioExists: all)
        let (sa, sb) = (segs[0], segs[1])
        #expect(sa.exit.kind == .cut && sa.exit.xs == [52, 52] && sa.bassOut == nil)  // cut before the swap
        #expect(near(sb.bassIn, 52))  // B gets its bass when A is cut
    }

    @Test func mixTimelineSyncStartsAtFullVolume() {
        var (a, b, order, acts) = mixPair(nil)
        acts[1].sync = true
        _ = (a, b)
        let segs = Timeline.mix(order, acts, ["1": a, "2": b], bpm: 0, audioExists: all)
        #expect(segs[1].sync && segs[1].fadeIn == nil && near(segs[1].start, 48))
        #expect(segs[0].exit.kind == .fade && nearAll(segs[0].exit.xs, [56, 60]))  // no exit marker: fade from the swap
    }

    @Test func jumpRoute() {
        var t = T.synth(T.Options(nb: 160, bpm: 120))  // beat n at (n - 1) / 2 s
        t.length = 80
        typealias P = Route.Piece
        t.cues = [T.cue(t, 33, "JUMP", 0), T.cue(t, 97, "JUMP TO DROP", 7)]
        let r = Route.jumpRoute(t, start: 0)
        #expect(r.pieces == [P(s0: 0, s1: 16), P(s0: 48, s1: 80)] && r.jumps == [16])
        #expect(r.play(20) == nil)  // skipped
        #expect(near(r.play(50), 18))
        #expect(Route.jumpRoute(t, start: 20).pieces == [P(s0: 20, s1: 80)])  // starts after the JUMP
        #expect(Route.jumpRoute(t, start: 0, keep: [30]).pieces == [P(s0: 0, s1: 80)])  // jumping would skip G
        t.cues = [T.cue(t, 33, "JUMP", 7), T.cue(t, 33, "JUMP", 0), T.cue(t, 97, "JUMP", 0)]  // landing + jump back
        #expect(Route.jumpRoute(t, start: 0).pieces == [P(s0: 0, s1: 48), P(s0: 16, s1: 80)])
        t.cues = [
            T.cue(t, 17, "JUMP", 0), T.cue(t, 65, "JUMP", 0), T.cue(t, 41, "JUMP", 7), T.cue(t, 81, "JUMP AGAIN", 6),
        ]
        #expect(Route.jumpRoute(t, start: 0).pieces == [P(s0: 0, s1: 8), P(s0: 20, s1: 32), P(s0: 40, s1: 80)])
        t.cues = [T.cue(t, 33, "JUMP", 0)]
        #expect(Route.jumpRoute(t, start: 0).pieces == [P(s0: 0, s1: 80)])  // no JUMP hot cue
    }

    @Test func mixTimelineFollowsJumps() {
        var (a, b, order, acts) = mixPair(Exit(name: "FILTER", a: 113, b: 33, side: "out"))
        a.cues = [T.cue(a, 33, "JUMP", 0), T.cue(a, 49, "JUMP", 7)]  // skips 16 beats (8 s) before G
        var recs = ["1": a, "2": b]
        let segs = Timeline.mix(order, acts, recs, bpm: 0, audioExists: all)
        #expect(nearAll(segs[0].jumps, [16]))
        #expect(near(segs[1].start, 40) && near(segs[0].exit.xs[0], 48))  // all 8 s earlier
        var (pa, pb) = Timeline.pair(order, acts, recs, bpm: 0, audioExists: all)  // from 8 beats before G: no jump
        #expect(pa.start == 0 && near(pb.start, 4) && pa.jumps.isEmpty)
        #expect(near(pb.end, pa.end + Mix.tail * 0.5) && pb.exit.kind == .end)
        a.cues = [T.cue(a, 93, "JUMP", 0), T.cue(a, 33, "JUMP", 7)]  // 4 beats before G, back 60 beats
        recs["1"] = a
        (pa, pb) = Timeline.pair(order, acts, recs, bpm: 0, audioExists: all)
        #expect(near(pb.start, 4) && pa.jumps.isEmpty)
        #expect(near(pa.clock.src0, 46 + (48 - 16) - 4))  // G (48 s) played at 78 s, from 4 s before
    }

    /// Mean |FFT| above 4 kHz of x (left channel), over a power-of-two prefix.
    func hf(_ x: [Float]) -> Double {
        var n = 1
        while n * 2 <= x.count { n *= 2 }
        let fft = DSP.RealFFT(n)
        var y = Array(x.prefix(n))
        var re = [Float](repeating: 0, count: n / 2)
        var im = re
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var z = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                y.withUnsafeMutableBytes {
                    vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &z, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(fft.setup, &z, 1, fft.log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        var s = 0.0
        var c = 0
        for k in 1..<n / 2 where Double(k) * Mix.sampleRate / Double(n) > 4000 {
            s += Double((re[k] * re[k] + im[k] * im[k]).squareRoot())
            c += 1
        }
        return s / Double(c)
    }

    @Test func lowpassSweepClosesDown() {
        var g = SystemRandomNumberGenerator()
        let n = Int(Mix.sampleRate) * 4
        let y = Stereo(
            l: (0..<n).map { _ in Float.random(in: -1...1, using: &g) },
            r: (0..<n).map { _ in Float.random(in: -1...1, using: &g) })
        let z = DSP.lowpassSweep(y, sweep: 0)
        let q = n / 16
        #expect(hf(Array(z.l[0..<q])) > 0.5 * hf(Array(y.l[0..<q])))  // still open at the start
        #expect(hf(Array(z.l[(n - q)...])) < 0.05 * hf(Array(y.l[(n - q)...])))  // closed by the end
    }

    @Test func lowCutKeepsHighs() {
        let n = 10007
        let v = (0..<n).map { i in
            Float(sin(2 * .pi * 50 * Double(i) / Mix.sampleRate) + sin(2 * .pi * 1000 * Double(i) / Mix.sampleRate))
        }
        let z = DSP.lowCut(Stereo(l: v, r: v))
        var e50 = 0.0
        var e1k = 0.0
        for i in 2000..<(n - 2000) {  // away from the edges: the 1 kHz sine alone
            let hi = sin(2 * .pi * 1000 * Double(i) / Mix.sampleRate)
            e1k += abs(Double(z.l[i]) - hi)
            e50 += abs(Double(v[i]) - hi)
        }
        #expect(e1k <= 0.05 * e50)
    }

    @Test func timeStretchKeepsPitchAndLevel() {
        let sr = Int(Mix.sampleRate)
        let v = (0..<sr * 3).map { Float(sin(2 * .pi * 440 * Double($0) / Mix.sampleRate)) * 0.5 }
        for rate in [0.9, 1.1] {
            let y = TimeStretch.stretch(Stereo(l: v, r: v), rate: rate, frames: sr * 2)
            var zc = 0
            for i in (sr / 2)..<(sr * 3 / 2) where (y.l[i - 1] < 0) != (y.l[i] < 0) { zc += 1 }
            #expect(abs(zc / 2 - 440) <= 2)
            let rms = (y.l[(sr / 2)..<(sr * 3 / 2)].reduce(0) { $0 + $1 * $1 } / Float(sr)).squareRoot()
            #expect(abs(rms - 0.3536) < 0.01)
        }
    }

    @Test func renderSetStreamsTheWholeMix() async throws {
        let dir = try tempDir()
        var (a, b, order, acts) = mixPair(Exit(name: "FILTER", a: 113, b: 33, side: "out"))
        a.cues = [T.cue(a, 33, "JUMP", 0), T.cue(a, 49, "JUMP", 7)]  // rendered through the jump
        for (t, hz) in [(a, 220.0), (b, 330.0)] {
            let v = (0..<Int(Mix.sampleRate) * 80).map { Float(sin(2 * .pi * hz * Double($0) / Mix.sampleRate)) * 0.5 }
            try PCMFile.write(Stereo(l: v, r: v), to: dir + t.path)
        }
        a.path = dir + a.path
        b.path = dir + b.path
        let recs = ["1": a, "2": b]
        for bpm in [0.0, 128] {
            let res = SetResult(
                playlist: "Test", report: "", order: order, actions: acts, recs: recs, clashes: 0, keyChecks: [],
                suggested: [0, 1],
                suggestedCost: 0, cache: TransitionCache())
            let plan = PreviewPlan(res, bpm: bpm)
            let renderer = SetRenderer(cacheDir: dir + "/renders", workers: 4)
            var chunks: [MixChunk] = []
            var ready: [Int] = []
            var clips: [Int: String] = [:]
            var total = 0
            for try await ev in renderer.render(plan) {
                switch ev {
                case .mixChunk(let c): chunks.append(c)
                case .pairReady(let i, let f, _):
                    ready.append(i)
                    clips[i] = f
                case .mixDone(let f): total = f
                default: break
                }
            }
            let (dur, _) = PageData.mixInfo(plan.mix)
            #expect(abs(Double(total) / Mix.sampleRate - dur) < 0.02, "bpm \(bpm)")
            #expect(chunks.map(\.index) == [0, 1] && chunks[0].start == 0 && chunks[1].start == chunks[0].frames)
            #expect(ready == [0])
            // a second render finds every segment in the cache
            let t0 = Date()
            for try await _ in renderer.render(plan) {}
            #expect(Date().timeIntervalSince(t0) < 5)
            let out = dir + "/out\(Int(bpm))"
            let page = try PreviewExport.write(plan, clips: clips, mixChunks: chunks.map(\.file), to: out, format: .wav)
            let html = String(decoding: FileManager.default.contents(atPath: page)!, as: UTF8.self)
            #expect(html.contains("<title>Test Set</title>") && !html.contains("__DATA__"))
            for f in ["01-02.wav", "set.wav", "set.json"] {
                #expect(FileManager.default.fileExists(atPath: out + "/" + f), "\(f)")
            }
            let mixFile = try AudioDecoder.info(out + "/set.wav")
            #expect(abs(mixFile.duration - dur) < 0.02)
        }
    }

    @Test func pageEscapesTitleAndScriptData() {
        #expect(PreviewExport.htmlEscape("<b>&\"") == "&lt;b&gt;&amp;&quot;")
        #expect(Review.scriptSafe("\"</script>\"") == "\"\\u003c/script\\u003e\"")
    }
}
