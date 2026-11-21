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
        a.cues = [T.cue(a, 577, "OTHER", 8)]  // a hand-placed G: the CUT cues added below don't move it
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

    // ADR 0020: finish before the outgoing track's last 16 bars, avoid vocal overlaps

    /// Vocal confidence 1 on beats in ranges (1-based, half-open), 0 elsewhere.
    func vocals(_ t: Track, _ ranges: [Range<Int>]) -> [Double] {
        (1...t.beats.count).map { b in ranges.contains { $0.contains(b) } ? 1 : 0 }
    }

    @Test func movesGSoTheTransitionFinishesBeforeTheLastBars() throws {
        var (a, b) = T.pair()
        a.cues = [T.cue(a, 577, "OUT", 5)]  // OUT 64 beats from the end: finishing would be in the last bars
        b.cues = [T.cue(b, 65, "IN", 1)]
        let acts = T.plan(a, b)
        let g = try #require(acts[0].g?.beat)
        let e = try #require(acts[1].e?.beat)
        #expect(g < 577 && (577 - g) % 16 == 0)
        let end = SetPlanner.leaveBeat(a, g, b, e, swap: acts[1].swap)
        #expect(end <= SetPlanner.lastAudioBeat(a) - SetPlanner.lateBeats)
        #expect(acts[1].warnings.contains { $0.contains("G moved") && $0.contains("finishes before the last 16 bars") })
    }

    @Test func movesAnEarlierRunsGOnOut() {
        var (a, b) = T.pair()
        // G on the OUT hot cue: written by the earlier rule (G = OUT), so it may move
        a.cues = [T.cue(a, 577, "OUT", 5), T.cue(a, 577, "OTHER", 8)]
        b.cues = [T.cue(b, 65, "IN", 1)]
        let acts = T.plan(a, b)
        #expect((acts[0].g?.beat ?? 0) < 577 && acts[0].g?.status == .replace && acts[0].g?.name == "OTHER")
        a.cues = [T.cue(a, 577, "OUT", 5), T.cue(a, 593, "OTHER", 8)]  // elsewhere: hand-placed, kept
        #expect(T.plan(a, b)[0].g == Slot(name: "OTHER", beat: 593, status: .existing))
    }

    @Test func keepsGAtTheEndWhenNothingEarlierWorks() {
        var (a, b) = T.pair()
        a.cues = [T.cue(a, 577, "OUT", 5), T.cue(a, 561, "DROP", 3)]  // G can't go before the drop + 8 bars
        b.cues = [T.cue(b, 65, "IN", 1)]
        let acts = T.plan(a, b)
        #expect(acts[0].g?.beat == 577)
        #expect(!acts[1].warnings.contains { $0.contains("G moved") })
    }

    @Test func avoidsVocalOverlap() throws {
        var (a, b) = T.pair()
        a.cues = [T.cue(a, 513, "OUT", 5)]  // finishes in time either way
        b.cues = [T.cue(b, 65, "IN", 1)]
        b.vocals = vocals(b, [1..<641])  // b sings throughout
        a.vocals = vocals(a, [513..<641])  // a's vocals start at its OUT
        let acts = T.plan(a, b)
        let g = try #require(acts[0].g?.beat)
        let e = try #require(acts[1].e?.beat)
        let end = SetPlanner.leaveBeat(a, g, b, e, swap: acts[1].swap)
        #expect(SetPlanner.vocalOverlap(a, g, b, e, until: end).beats == 0)
        #expect(acts[1].vocalOverlap == nil)
        #expect(acts[1].warnings.contains { $0.contains("no vocal overlap") })
    }

    @Test func warnsWhenVocalOverlapIsUnavoidable() {
        var (a, b) = T.pair()
        a.cues = [T.cue(a, 513, "OUT", 5)]
        b.cues = [T.cue(b, 65, "IN", 1)]
        a.vocals = vocals(a, [1..<641])
        b.vocals = vocals(b, [1..<641])
        let acts = T.plan(a, b)
        #expect((acts[1].vocalOverlap ?? 0) >= 8)
        #expect(
            acts[1].warnings.contains { $0.hasPrefix("vocal overlap:") && $0.contains("no nearby transition point") })
        var hand = (a, b)  // hand-placed E and G: kept, still flagged
        hand.0.cues = [T.cue(a, 513, "OTHER", 8)]
        hand.1.cues = [T.cue(b, 65, "SYNTHETIC", 6)]
        let kept = T.plan(hand.0, hand.1)
        #expect(kept[0].g?.beat == 513 && kept[1].e?.beat == 65)
        #expect(kept[1].warnings.contains { $0.contains("E and G are hand-placed; kept") })
    }

    @Test func suggestsAVocalFreeLoopWhenTheOverlapStays() throws {
        var (a, b) = T.pair()
        a.cues = [T.cue(a, 513, "OTHER", 8)]  // hand-placed: the overlap stays
        b.cues = [T.cue(b, 65, "SYNTHETIC", 6)]
        a.vocals = vocals(a, [1..<449, 545..<641])  // 449-544 is vocal-free, so A can loop there
        b.vocals = vocals(b, [1..<641])
        let acts = T.plan(a, b)
        let loop = try #require(acts[1].vocalLoop)
        #expect(loop == SetAction.Loop(beat: 481, beats: 64))  // 16 bars, ending where A's vocals start
        #expect(acts[1].warnings.contains { $0.contains("loop Synthetic (Extended Mix)'s beats 481-544 (16 bars") })
        a.vocals = vocals(a, [1..<641])
        #expect(T.plan(a, b)[1].vocalLoop == nil)
        #expect(T.plan(a, b)[1].warnings.contains { $0.contains("no vocal-free 4-bar stretch") })
    }

    @Test func bassSwapOnlyWhereBothTracksHaveBass() throws {
        var (a, b) = T.pair()
        a.cues = [T.cue(a, 513, "OTHER", 8)]  // hand-placed G and E: kept
        b.cues = [T.cue(b, 17, "SYNTHETIC", 6), T.cue(b, 49, "BASS SWAP", 0)]  // b has no bass until beat 65
        let acts = T.plan(a, b)
        let sw = try #require(acts[1].bassSwap?.beat)
        #expect(sw != 49 && sw >= 65)
        #expect(SetPlanner.bassBoth(a, 513, b, 17, sw) && !SetPlanner.bassBoth(a, 513, b, 17, 49))
        #expect(acts[1].warnings.contains { $0.hasPrefix("BASS SWAP at beat 49 not used: both tracks need bass") })
    }

    @Test func noVocalAnalysisNoVocalWarnings() {
        var (a, b) = T.pair()
        a.cues = [T.cue(a, 513, "OUT", 5)]
        b.vocals = vocals(b, [1..<641])  // a has no vocal analysis
        #expect(T.plan(a, b)[1].vocalOverlap == nil)
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
