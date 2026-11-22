// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import AutoDJKit

/// What the app's set timeline draws: the 3-band waveform and the cues in mix time.
@Suite struct SetTimelineTests {
    typealias T = TestTrack

    func tone(_ hz: Double, seconds: Double) -> Stereo {
        let n = Int(seconds * Mix.sampleRate)
        let x = (0..<n).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / Mix.sampleRate)) }
        return Stereo(l: x, r: x)
    }

    @Test func waveformBands() {
        let low = Waveform.of(tone(60, seconds: 2), start: 10)
        let high = Waveform.of(tone(6000, seconds: 2), start: 10)
        #expect(low.count == Int((2 * Waveform.rate).rounded(.up)))
        #expect(abs(low.end - 12) < 0.02)
        let l = low.mean(10.5, 11.5)
        let h = high.mean(10.5, 11.5)
        #expect(l.low > 5 * l.mid && l.low > 5 * l.high)
        #expect(h.high > 5 * h.mid && h.high > 5 * h.low)
        #expect(low.mean(0, 5) == (0, 0, 0))  // before it starts
        #expect(low.level(0.97).low > 0.2)
    }

    @Test func cueMarksAsTheWriteLeavesThem() {
        var t = T.synth()
        t.cues = [
            T.cue(t, 65, "IN", Config.kind["A"]!),
            T.cue(t, 17, "OLD E", Config.kind["E"]!),  // the plan's E replaces it
            T.cue(t, 257, "LOW PASS", 0),  // renamed
            T.cue(t, 300, "STALE", 0),  // removed
            T.cue(t, 33, "BASS SWAP IN", 0),  // also a marker: listed once
        ]
        var act = SetAction(id: "1", title: "x")
        act.e = Slot(name: "NEXT", beat: 17, status: .replace, old: Slot.Old(name: "OLD E", beat: 17))
        act.g = Slot(name: "LAST", beat: 545, status: .new)
        act.markers = [SetMarker(name: "BASS SWAP IN", beat: 33, status: .existing)]
        act.remove = [SetAction.Removal(name: "STALE", beat: 300, why: "no longer used")]
        let m = CueMarks.of(t, act)
        #expect(m.map(\.t) == m.map(\.t).sorted())
        #expect(m.compactMap(\.slot).sorted() == ["A", "E", "G"])
        let e = m.first { $0.slot == "E" }!
        #expect(e.name == "NEXT" && e.change == .replace && e.was == "OLD E" && e.beat == 17)
        let filter = m.first { $0.beat == 257 }!
        #expect(filter.name == "FILTER" && filter.change == .rename && filter.memoryColor == 7)
        let stale = m.first { $0.name == "STALE" }!
        #expect(stale.change == .remove && !stale.kept && stale.why == "no longer used")
        #expect(m.filter { $0.name == "BASS SWAP IN" }.count == 1)
        #expect(CueMarks.slot(Config.kind["D"]!) == "D" && CueMarks.slot(0) == nil)
        #expect(CueMarks.beat(t, t.beats[99] + 0.01) == 100)
    }

    @Test func plannedCues() {
        var t = T.synth()
        t.cues = [
            T.cue(t, 1, "START", Config.kind["A"]!),  // generated: replaced by the plan's A
            T.cue(t, 33, "Energy 5", 0),  // generated: removed
            T.cue(t, 65, "MY SPOT", 0),  // the user's own: kept
            T.cue(t, 129, "DROP", 0),  // the user's DROP: kept, so the plan's isn't added again
        ]
        t.category = "mik"
        let x = CuePlan.plan(t, .default)
        let m = CueMarks.planned(t, x)
        #expect(m.map(\.t) == m.map(\.t).sorted())
        #expect(m.first { $0.name == "Energy 5" }?.change == .remove)
        #expect(m.first { $0.name == "MY SPOT" }?.change == .existing)
        #expect(m.filter { $0.slot == nil && $0.name == "DROP" && abs($0.t - beatTime(t, 129)) < 0.5 }.count == 1)
        let a = m.first { $0.slot == "A" }!
        #expect(
            a.change == .replace && a.was == "START"
                && !m.contains { $0.name == "START" && $0.slot != nil && $0.change == .remove })
        #expect(m.filter { $0.slot != nil && $0.kept }.count == x.hot.count)
    }

    @Test func vocalsPerBeatAndCache() throws {
        // windows every 0.75 s: vocals from 6 s to 12 s
        let conf: [Float] = (0..<40).map { i in Double(i) * Vocals.hop >= 6 && Double(i) * Vocals.hop < 12 ? 0.9 : 0 }
        let beats = (0..<60).map { Double($0) * 0.5 }  // 120 BPM
        let v = Vocals.perBeat(conf, beats: beats, bpm: 120)
        #expect(v.count == 60)
        #expect(v[5] < 0.05 && v[18] > 0.8 && v[40] < 0.05)  // 2.5 s and 20 s: none; 9 s: vocals
        #expect(v[18] > Vocals.threshold && v[8] < Vocals.threshold)
        let p = try tempDir() + "/x.vox"
        try Vocals.save(p, conf)
        #expect(try Vocals.load(p) == conf)
        #expect(try Vocals.load(p + ".missing") == nil)
    }

    @Test func cueMixTimes() {
        var a = T.synth(T.Options(nb: 160, bpm: 120))
        var b = T.synth(T.Options(nb: 160, bpm: 120))
        (a.path, b.path, a.length, b.length, b.id) = ("/a.wav", "/b.wav", 80, 80, "2")
        let order = T.order([a, b])
        var x = SetAction(id: "1", title: "A")
        x.e = Slot(name: "START", beat: 1, status: .new)
        x.g = Slot(name: "B", beat: 97, status: .new)
        var y = SetAction(id: "2", title: "B")
        y.e = Slot(name: "A", beat: 17, status: .new)
        let segs = Timeline.mix(order, [x, y], ["1": a, "2": b], bpm: 0, audioExists: { $0 != nil })
        // B's E plays as A reaches G; A's beat 1 before the set starts, B's beat 1 before B comes in
        #expect(CueMarks.mixTimes(segs[1], beatTime(b, 17)).map { abs($0 - segs[1].start) < 1e-6 } == [true])
        #expect(CueMarks.mixTimes(segs[0], beatTime(a, 97)).map { abs($0 - 48) < 1e-6 } == [true])
        #expect(CueMarks.mixTimes(segs[1], beatTime(b, 1)).isEmpty)
    }
}
