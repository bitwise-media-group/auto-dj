// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import AutoDJKit

/// The cue template on tracks a write touches (ADR 0022).
@Suite struct TemplateTests {
    @Test func setOwnedCuesDontChangeTheState() {
        func cat(_ cs: [Cue], rating: Int = 0) -> String { Category.classify(rating: rating, cues: cs, auto: false) }
        let e = Cue(kind: 6, t: 8, name: "LOLEATTA")
        let g = Cue(kind: 8, t: 300, name: "RUSHING IN")
        let marker = Cue(kind: 0, t: 30, name: "BASS SWAP IN")
        #expect(cat([e, g, marker]) == "nohot")  // a set written before the template
        #expect(cat([Cue(kind: 6, t: 0, name: "START")]) == "nohot")  // the first track's E
        #expect(cat([Cue(kind: 1, t: 1, name: "Energy 5"), g, marker]) == "mik")
        #expect(cat([Cue(kind: 7, t: 9, name: "JUMP"), e]) == "other")  // F is the DJ's
        #expect(cat([Cue(kind: 1, t: 1, name: "MY IN"), e]) == "other")
        #expect(cat([e, g], rating: 2) == "manual")
    }

    @Test func missingSkipsRatedAndCuedTracks() {
        var ts = ["new", "mik", "rated", "auto", "other"].map { SetBuilderTests.track($0) }
        (ts[0].category, ts[1].category, ts[2].category, ts[3].category, ts[4].category) = (
            "nohot", "mik", "nohot", "auto", "other"
        )
        (ts[0].rating, ts[1].rating, ts[2].rating, ts[3].rating, ts[4].rating) = (0, 0, 3, 0, 0)
        #expect(CueTemplate.missing(ts + [ts[0]]).map(\.id) == ["new", "mik"])
    }

    @Test func setsArePlannedWithTheTemplate() throws {
        var a = SetBuilderTests.track("a")
        var b = SetBuilderTests.track("b")
        (a.rating, a.category) = (0, "nohot")
        (b.rating, b.category) = (4, "manual")
        let recs = SetBuilderTests.lib([a, b])
        let order = [a, b].enumerated().map {
            PlaylistTrack(no: $0.offset + 1, id: $0.element.id, title: $0.element.title, bpm: 128, key: "8A")
        }
        let res = try SetRun.plan("S", order, recs, TransitionCache(), order: .playlist, freeStart: false)
        #expect(res.template.map(\.id) == ["a"])
        let names = Set(res.recs["a"]!.cues.map(\.name))
        #expect(names.isSuperset(of: ["IN", "DROP", "OUT", "EMERGENCY", "START"]))
        #expect(res.recs["b"]!.cues.isEmpty)
        #expect(res.report.contains("Cue template (written first, as apply --write would) on 1 track(s)"))
        // G on a's OUT: where the set will find it once written
        let out = res.recs["a"]!.cues.first { $0.name == "OUT" }!
        #expect(res.actions[0].g.map { a.beats[$0.beat - 1] } == out.t)
    }
}
