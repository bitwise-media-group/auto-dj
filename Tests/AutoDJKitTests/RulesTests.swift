// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import AutoDJKit

@Suite struct RulesTests {
    @Test func hotCuesFollowTemplate() {
        let h = CueRules.hotCues(TestTrack.synth(), .default)
        #expect(h["IN"] == 65 && h["BRIDGE"] == 257 && h["DROP"] == 321)
        #expect(
            h["IN"]! < h["BRIDGE"]! && h["BRIDGE"]! < h["DROP"]! && h["DROP"]! < h["OUT"]!
                && h["OUT"]! < h["EMERGENCY"]!)
        #expect(h["EMERGENCY"]! + 32 <= 625)  // the loop ends before the bass does
        let d = h["EMERGENCY"]! - h["OUT"]!
        #expect(d >= 32 && d <= 128)
    }

    @Test func shortBreakdownMeansNoBridge() {
        var t = TestTrack.synth(TestTrack.Options(breakdown: (257, 265)))
        t.phrases.removeAll { $0.label == "Down" }
        let h = CueRules.hotCues(t, .default)
        #expect(h["BRIDGE"] == nil)
        #expect(h["DROP"] != nil)
    }

    @Test func memoryCues() {
        let t = TestTrack.synth()
        let h = CueRules.hotCues(t, .default)
        let m = CueRules.memoryCues(t, h, .default)
        #expect(m.start == 1)
        #expect(m.drops.contains(h["DROP"]!))
        #expect(m.bassSwap == 0 || m.bassSwap >= h["IN"]! + 16)
    }

    @Test func phraseOnlyFallback() {
        var t = TestTrack.synth()
        t.fb = nil
        let h = CueRules.hotCues(t, .default)
        let m = CueRules.memoryCues(t, h, .default)
        #expect(h["IN"] == 65 && h["BRIDGE"] == 257 && m.drops.contains(h["DROP"]!))
    }

    @Test func planEncoding() throws {
        let x = CuePlan.plan(TestTrack.synth(), .default)
        #expect(!x.hot.contains { ["E", "F", "G"].contains($0.slot) })  // never E/F/G
        let em = try #require(x.hot.first { $0.name == "EMERGENCY" })
        #expect(em.kind == 9 && em.loop == 32 && em.outMS! > em.ms)
        #expect(
            CueWriter.hotRow(PlanHot(kind: 9, name: "EMERGENCY", ms: 0, loop: 32, outMS: 1), active: true).bls
                == 2_097_153)
        // the plan round-trips through its file
        let p = try tempDir() + "/plan.json"
        try CuePlan.save([x], to: p)
        #expect(try CuePlan.load(p) == [x])
    }

    @Test func evaluateScoresOwnCues() {
        var t = TestTrack.synth()
        t.category = "manual"
        let h = CueRules.hotCues(t, .default)
        t.cues = [TestTrack.cue(t, h["IN"]!, "IN", 1), TestTrack.cue(t, h["DROP"]! + 16, "DROP", 3)]
        let rep = Evaluate.score([t], .default, verbose: true)
        #expect(rep.cues["IN"]!.exact == 1 && rep.cues["DROP"]!.exact == 0 && rep.cues["DROP"]!.within16 == 1)
        #expect(Evaluate.format(rep).contains("IN:65/65"))
    }
}

@Suite struct KeyTests {
    @Test func camelotAndKeyMoves() {
        let keys = ["Am": (8, "A"), "C": (8, "B"), "F#m": (11, "A"), "Abm": (1, "A"), "9A": (9, "A")]
        for (k, w) in keys {
            let c = Camelot(k)
            #expect(c?.n == w.0 && c?.letter == w.1, "\(k)")
        }
        #expect(Keys.move("F#m", "C#m").ok)
        #expect(Keys.move("Am", "C").ok)
        #expect(Keys.move("F#m", "Em").cost == 1)
        #expect(Keys.move("Am", "Bbm").cost == 2)
        #expect(!Keys.move("F#m", "Am").ok)
    }

    @Test func suggestOrderFixesClashMinimally() {
        let keys = ["F#m", "Am", "F#m", "C#m", "G#m"]
        let (order, cost) = Keys.suggestOrder(keys.map { Keys.Item(key: $0, bpm: 124) }, keepFirst: true)
        #expect(order[0] == 0 && cost < 100)
        for (i, j) in zip(order, order.dropFirst()) { #expect(Keys.move(keys[i], keys[j]).ok) }
        let big = (0..<16).map { Keys.Item(key: keys[$0 % keys.count], bpm: 124) }  // local search above 14
        let (o2, _) = Keys.suggestOrder(big, keepFirst: true)
        #expect(o2[0] == 0 && o2.count == 16 && Set(o2).count == 16)
    }

    @Test func sequenceMatcherMatchesDifflib() {
        // difflib.SequenceMatcher(None, a, b).ratio()
        #expect(abs(SequenceMatcher.ratio("abcd", "bcde") - 0.75) < 1e-12)
        #expect(abs(SequenceMatcher.ratio("dialog", "dialogue") - 0.857142857142857) < 1e-9)
        #expect(SequenceMatcher.ratio("", "") == 1)
    }

    @Test func transitionCacheRecordsHistory() {
        var c = TransitionCache()
        c.record(outID: "1", outTitle: "A", inID: "2", inTitle: "B", source: "library", gMS: 1000)
        c.record(outID: "1", outTitle: "A", inID: "2", inTitle: "B", source: "set:x", gMS: 1010, eMS: 500)
        #expect(c.get("1", "2")?.history.isEmpty == true)  // 10 ms: unchanged; e_ms was unset
        c.record(outID: "1", outTitle: "A", inID: "2", inTitle: "B", source: "set:y", gMS: 2000)
        let e = c.get("1", "2")!
        #expect(e.gMS == 2000 && e.eMS == 500 && e.history.count == 1 && e.history[0].gMS == 1000)
    }
}

@Suite struct SetPlannerTests {
    typealias T = TestTrack

    @Test func alignmentPhraseAndPlayOut() {
        let a = T.synth()
        let b = T.synth()
        #expect(SetPlanner.align(a, 513, b, 65).phraseAligned)
        #expect(!SetPlanner.align(a, 513, b, 61).phraseAligned)
    }

    @Test func namesMatchTypos() {
        #expect(SetPlanner.namesMatch("DIALOG", "Dialogue (Original Mix)"))
        #expect(SetPlanner.namesMatch("RAJ", "Rej (Original Mix)"))
        #expect(SetPlanner.namesMatch("LOST HAWK", "The Lost Hawk (Original Mix)"))
        #expect(SetPlanner.cueName("Don't Wake Up (Original Mix)") == "DONT WAKE UP")
    }

    @Test func warnsOnMemoryCuesWithoutColourRule() {
        var (a, b) = T.pair()
        a.cues = [
            T.cue(a, 1, "START", 0), T.cue(a, 97, "EARLY", 0), T.cue(a, 161, "Low Pass", 0),
            T.cue(a, 321, "filter", 0), T.cue(a, 577, "OUT", 0),
        ]
        let acts = T.plan(a, b)
        let warn = acts[0].warnings.filter { $0.contains("no colour rule") }
        #expect(
            warn.count == 1 && warn[0].contains("'EARLY' @ beat 97") && !warn[0].contains("Low Pass")
                && !warn[0].contains("START'"))
        #expect(
            acts[0].warnings.contains {
                $0.contains("'Low Pass' (memory) @ beat 161 -> FILTER")
                    && $0.contains("'OUT' (memory) @ beat 577 -> CUT OUT")
            })
        #expect(!acts[1].warnings.contains { $0.contains("no colour rule") })
        #expect(SetPlanner.memName(Cue(kind: 0, t: 0, name: "Filter Out Out")) == "FILTER OUT")
        #expect(SetPlanner.memName(Cue(kind: 0, t: 0, name: "FILTER OUT IN")) == "FILTER IN")
    }

    @Test func swapAndExitMarkersOnBothTracks() throws {
        var (a, b) = T.pair()
        a.cues = [T.cue(a, 577, "OUT", 5), T.cue(a, 601, "Low Pass", 0)]
        b.cues = [T.cue(b, 65, "IN", 1)]
        let acts = T.plan(a, b)
        let g = acts[0].g!.beat
        let e = acts[1].e!.beat
        #expect(acts[0].exit == Exit(name: "FILTER", a: 601, b: e + 601 - g, side: "out"))
        #expect(acts[0].markers.contains(SetMarker(name: "FILTER OUT", beat: 601, status: .rename)))
        #expect(acts[1].markers.contains(SetMarker(name: "FILTER IN", beat: e + 601 - g, status: .new)))
        let sw = try #require(acts[1].swap)
        #expect(acts[0].markers.contains(SetMarker(name: "BASS SWAP OUT", beat: g + sw - e, status: .new)))
        #expect(acts[1].markers.contains(SetMarker(name: "BASS SWAP IN", beat: sw, status: .new)))
    }

    @Test func keepsExistingBassSwapOffTheOutgoingPhrasing() {
        var (a, b) = T.pair(T.Options(nb: 632))
        a.cues = [T.cue(a, 585, "OTHER", 8)]
        b.cues = [T.cue(b, 65, "SYNTHETIC", 6), T.cue(b, 97, "BASS SWAP", 0)]
        let acts = T.plan(a, b)
        #expect(acts[0].g?.beat == 585 && acts[1].e?.beat == 65)
        #expect(acts[1].bassSwap == BassSwap(beat: 97, why: "existing") && acts[1].swap == 97)
        #expect(acts[1].markers.contains(SetMarker(name: "BASS SWAP IN", beat: 97, status: .rename)))
        #expect(acts[0].markers.contains(SetMarker(name: "BASS SWAP OUT", beat: 617, status: .new)))
        #expect(
            acts[0].warnings.contains("G 'OTHER' at beat 585 is off-phrase (8 beats into a phrase); kept, check it"))
        #expect(
            acts[1].warnings.contains {
                $0.contains("BASS SWAP at beat 97 is off-phrase in Synthetic (Extended Mix) (8 beats")
            })
        #expect(!acts[1].warnings.contains { $0.contains("E 'SYNTHETIC'") })
    }

    @Test func keepsHandPlacedEOffThePhrase() {
        var (a, b) = T.pair()
        a.cues = [T.cue(a, 577, "OTHER", 8)]
        b.cues = [T.cue(b, 73, "SYNTHETIC", 6)]
        let acts = T.plan(a, b)
        #expect(acts[1].e == Slot(name: "SYNTHETIC", beat: 73, status: .existing))
        #expect(
            acts[1].warnings.contains("E 'SYNTHETIC' at beat 73 is off-phrase (8 beats into a phrase); kept, check it"))
        #expect(acts[1].warnings.contains { $0.contains("E at beat 73 is 8 beats off G's phrase position; kept") })
        #expect(!acts[0].warnings.contains { $0.contains("off-phrase") })
    }

    @Test func removesStaleCutOutsAndDuplicateJumps() {
        var (a, b) = T.pair()
        a.cues = [T.cue(a, 577, "OUT", 5)]
        b.cues = [T.cue(b, 65, "IN", 1)]
        let g = T.plan(a, b)[0].g!.beat
        a.cues += [
            T.cue(a, g - 64, "CUT OUT", 0), T.cue(a, g + 16, "Cut-Out RES", 0), T.cue(a, g + 48, "CUT OUT", 0),
            T.cue(a, 129, "JUMP TO DROP", 7), T.cue(a, 129, "JUMP", 0), T.cue(a, 33, "JUMP", 0),
        ]
        b.cues.append(T.cue(b, 600, "CUT OUT", 0))
        var acts = T.plan(a, b)
        #expect(acts[0].exit?.name == "CUT" && acts[0].exit?.a == g + 16)
        #expect(acts[0].markers.contains(SetMarker(name: "CUT OUT", beat: g + 16, status: .existing)))
        let got = acts[0].remove.sorted { ($0.name, $0.beat) < ($1.name, $1.beat) }
        #expect(
            got == [
                .init(name: "CUT OUT", beat: g - 64, why: "no CUT IN on the next track there"),
                .init(name: "CUT OUT", beat: g + 48, why: "no CUT IN on the next track there"),
                .init(name: "JUMP", beat: 129, why: "same beat as the JUMP hot cue"),
            ])
        #expect(acts[1].remove == [.init(name: "CUT OUT", beat: 600, why: "no CUT IN on the next track there")])
        #expect(acts[0].warnings.contains { $0.contains("'JUMP TO DROP' (hot cue) @ beat 129 -> JUMP") })
        #expect(acts[0].warnings.contains { $0.contains("'Cut-Out RES' (memory) @ beat ") })
        b.cues.append(T.cue(b, acts[1].e!.beat + 32, "CUT-IN A", 0))  // the next track's CUT IN wins
        acts = T.plan(a, b)
        #expect(acts[0].exit == Exit(name: "CUT", a: g + 32, b: acts[1].e!.beat + 32, side: "in"))
        #expect(acts[0].markers.contains(SetMarker(name: "CUT OUT", beat: g + 32, status: .new)))
        #expect(acts[0].remove.contains(.init(name: "CUT OUT", beat: g + 16, why: "no CUT IN on the next track there")))
    }

    @Test func syncMarkersOnBothTracks() {
        var (a, b) = T.pair()
        a.cues = [T.cue(a, 577, "OUT", 5)]
        b.cues = [T.cue(b, 65, "IN", 1)]
        var acts = T.plan(a, b)
        let g = acts[0].g!.beat
        let e = acts[1].e!.beat
        #expect(!acts[1].sync)
        b.cues.append(T.cue(b, e, "sync", 0))
        acts = T.plan(a, b)
        #expect(acts[1].sync)
        #expect(acts[0].markers.contains(SetMarker(name: "SYNC OUT", beat: g, status: .new)))
        #expect(acts[1].markers.contains(SetMarker(name: "SYNC IN", beat: e, status: .rename)))
        b.cues[b.cues.count - 1] = T.cue(b, e + 16, "SYNC IN", 0)
        #expect(!T.plan(a, b)[1].sync)
    }

    @Test func pickOrderChecksNumbers() throws {
        let o = T.order([T.synth(), T.pair().1])
        #expect(try SetRun.pick(o, [2, 1]).map(\.id) == ["2", "1"])
        #expect(throws: SetError.self) { try SetRun.pick(o, [1, 1]) }
        #expect(throws: SetError.self) { try SetOrder("1,x") }
        #expect(try SetOrder("suggested") == .suggested)
    }
}
