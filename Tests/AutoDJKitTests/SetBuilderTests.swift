// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import AutoDJKit

@Suite struct EnergyTests {
    @Test func mixedInKeyComments() {
        #expect(Energy.mik("126 - 10A - 7") == 7)
        #expect(Energy.mik("10A - 7") == 7)
        #expect(Energy.mik(" 10a - 126 - 10 ") == 10)
        #expect(Energy.mik("Energy 6") == 6)
        #expect(Energy.mik("9A") == nil)  // key only
        #expect(Energy.mik("126 - 10A") == nil)  // no energy
        #expect(Energy.mik("10A - 126") == nil)  // tempo last
        #expect(Energy.mik("126 - 10A - 11") == nil)  // out of range
        #expect(Energy.mik("126 - 7") == nil)  // no Camelot key
        #expect(Energy.mik("Purchased at Beatport.com") == nil)
        #expect(Energy.mik("") == nil)
    }

    @Test func ratingThenTagThenComment() {
        #expect(Energy.level(rating: 4, tag: 9, comment: "126 - 10A - 2") == .init(stars: 4, source: .rating))
        #expect(Energy.level(rating: 0, tag: 7, comment: "126 - 10A - 2") == .init(stars: 3.5, source: .mik))
        #expect(Energy.level(rating: 0, tag: nil, comment: "126 - 10A - 2") == .init(stars: 1, source: .mik))
        #expect(Energy.level(rating: 0, tag: nil, comment: "10A") == nil)
        #expect(Energy.Level(stars: 4, source: .rating).label == "4")
        #expect(Energy.Level(stars: 3.5, source: .mik).label == "~3.5")
    }

    @Test func agreementWithRatings() {
        func t(_ r: Int, _ tag: Int?) -> Track {
            var x = Track(id: UUID().uuidString, title: "T")
            (x.rating, x.mikEnergy) = (r, tag)
            return x
        }
        let a = Energy.agreement([t(3, 6), t(4, 7), t(1, 6), t(0, 9), t(2, nil)])
        #expect(a.compared == 3)
        #expect(a.half == 2)
        #expect(a.one == 2)
        #expect(a.far.map(\.mik) == [6])
    }
}

@Suite struct SetBuilderTests {
    @Test func pickPositions() {
        #expect(SetBuilder.pickPositions(n: 3, length: 14, opener: false, closer: false) == [3, 7, 11])
        #expect(SetBuilder.pickPositions(n: 3, length: 14, opener: true, closer: true) == [0, 7, 13])
        #expect(SetBuilder.pickPositions(n: 2, length: 6, opener: true, closer: false) == [0, 3])
        #expect(SetBuilder.pickPositions(n: 1, length: 1, opener: true, closer: true) == [0])
        #expect(SetBuilder.pickPositions(n: 2, length: 2, opener: false, closer: false) == [0, 1])
    }

    @Test func arcs() {
        #expect(SetBuilder.Arc.build.at(0, lo: 2, hi: 4) == 2)
        #expect(SetBuilder.Arc.build.at(1, lo: 2, hi: 4) == 4)
        #expect(SetBuilder.Arc.peak.at(0.65, lo: 2, hi: 4) == 4)
        #expect(SetBuilder.Arc.peak.at(1, lo: 2, hi: 4) == 3)
        #expect(SetBuilder.Arc.flat.at(0.5, lo: 2, hi: 4) == nil)
    }

    /// A synthetic analysed track: key, BPM, energy (stars, as a rating) and vocals everywhere or not.
    static func track(_ id: String, key: String = "8A", bpm: Double = 128, stars: Int = 3, vocals: Bool = false)
        -> Track
    {
        var t = TestTrack.synth(.init(bpm: bpm))
        (t.id, t.title, t.key, t.rating, t.local) = (id, "Track \(id) (Original Mix)", key, stars, true)
        t.vocals = [Double](repeating: vocals ? 1 : 0, count: t.beats.count)
        return t
    }

    static func lib(_ ts: [Track]) -> [String: Track] { Dictionary(uniqueKeysWithValues: ts.map { ($0.id, $0) }) }

    @Test func fillsBetweenPicksWithoutClashesOrTempoJumps() throws {
        let recs = Self.lib([
            Self.track("a"), Self.track("b", key: "9A"),
            Self.track("c", key: "7A"), Self.track("d", key: "8B"), Self.track("e", key: "9A"),
            Self.track("clash", key: "3A"), Self.track("fast", bpm: 140), Self.track("half", bpm: 64),
        ])
        var o = SetBuilder.Options(picks: ["a", "b"], length: 5)
        (o.keepOrder, o.opener, o.closer, o.arc) = (true, true, true, .flat)
        let r = try SetBuilder.build(o, recs, TransitionCache())
        #expect(r.slots.count == 5)
        #expect(r.slots.first?.id == "a")
        #expect(r.slots.last?.id == "b")
        #expect(r.slots.first?.anchor == true && r.slots[1].anchor == false)
        let ids = r.slots.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains("clash"))
        #expect(!ids.contains("fast"))
        #expect(r.clashes == 0)
        #expect(r.pool == 5)  // not the picks; half time counts, 140 BPM is out of range
    }

    @Test func avoidsVocalOverlaps() throws {
        let recs = Self.lib([
            Self.track("a", vocals: true), Self.track("sung", vocals: true), Self.track("dub"),
        ])
        var o = SetBuilder.Options(picks: ["a"], length: 2)
        (o.opener, o.arc) = (true, .flat)
        let r = try SetBuilder.build(o, recs, TransitionCache())
        #expect(r.slots.map(\.id) == ["a", "dub"])
        #expect(r.vocalOverlaps == 0)
    }

    @Test func followsTheArc() throws {
        let recs = Self.lib([
            Self.track("p", stars: 1), Self.track("low", stars: 1), Self.track("mid", stars: 3),
            Self.track("high", stars: 5),
        ])
        var o = SetBuilder.Options(picks: ["p"], length: 4)
        (o.opener, o.arc) = (true, .build)
        let r = try SetBuilder.build(o, recs, TransitionCache())
        #expect(r.slots.map(\.id) == ["p", "low", "mid", "high"])
    }

    @Test func placesPicksAlongTheArcByEnergy() throws {
        let recs = Self.lib([Self.track("hot", stars: 5), Self.track("cool", stars: 1), Self.track("x", stars: 3)])
        var o = SetBuilder.Options(picks: ["hot", "cool"], length: 2)
        o.arc = .build
        let r = try SetBuilder.build(o, recs, TransitionCache())
        #expect(r.slots.map(\.id) == ["cool", "hot"])
        o.keepOrder = true
        #expect(try SetBuilder.build(o, recs, TransitionCache()).slots.map(\.id) == ["hot", "cool"])
    }

    @Test func poolAndRefill() throws {
        let recs = Self.lib([Self.track("a"), Self.track("b"), Self.track("c"), Self.track("d")])
        var o = SetBuilder.Options(picks: ["a"], length: 2)
        (o.opener, o.arc, o.pool) = (true, .flat, ["c"])
        #expect(try SetBuilder.build(o, recs, TransitionCache()).slots.map(\.id) == ["a", "c"])
        // re-roll slot 1 of a-b-c: anything but b, and the anchors stay
        let r = SetBuilder.refill(
            anchors: [0: "a", 2: "c"], length: 3, bpm: 128, arc: .flat, pool: nil, exclude: ["b"], recs,
            TransitionCache())
        #expect(r.slots.map(\.id) == ["a", "d", "c"])
    }

    @Test func refusesBadPicks() {
        let recs = Self.lib([Self.track("a")])
        #expect(throws: SetBuilder.BuildError.self) { try SetBuilder.build(.init(picks: [], length: 3), recs, .init()) }
        #expect(throws: SetBuilder.BuildError.self) {
            try SetBuilder.build(.init(picks: ["a", "a"], length: 3), recs, .init())
        }
        #expect(throws: SetBuilder.BuildError.self) {
            try SetBuilder.build(.init(picks: ["z"], length: 3), recs, .init())
        }
        #expect(throws: SetBuilder.BuildError.self) {
            try SetBuilder.build(.init(picks: ["a"], length: 0), recs, .init())
        }
    }
}
