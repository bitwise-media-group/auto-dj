// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

@testable import AutoDJKit

/// Synthetic tracks for tests: no Rekordbox library needed (port of internal/testtrack).
enum TestTrack {
    struct Options {
        var nb = 640
        var bpm = 128.0
        /// No-bass stretch [start, end).
        var breakdown = (257, 321)
        var outro = 577
        /// First beat of the bassless tail.
        var bassEnd = 625
    }

    /// A typical 4/4 extended mix: intro (no bass) 1-64, groove, breakdown, drop, outro.
    static func synth(_ o: Options = Options()) -> Track {
        var t = Track(id: "1", title: "Synthetic (Extended Mix)")
        t.path = "/x.aiff"
        t.bpm = o.bpm
        t.category = "mik"
        t.beats = (0..<o.nb).map { Double($0) * 60 / o.bpm }
        t.bnum = (0..<o.nb).map { $0 % 4 + 1 }
        t.phrases = [
            Phrase(beat: 1, label: "Intro"), Phrase(beat: 65, label: "Up"), Phrase(beat: 129, label: "Chorus"),
            Phrase(beat: 193, label: "Chorus"), Phrase(beat: o.breakdown.0, label: "Down"),
            Phrase(beat: 289, label: "Up"),
            Phrase(beat: o.breakdown.1, label: "Chorus"), Phrase(beat: 385, label: "Chorus"),
            Phrase(beat: 449, label: "Chorus"), Phrase(beat: 513, label: "Chorus"),
            Phrase(beat: o.outro, label: "Outro"),
        ]
        t.fb = (0..<o.nb).map { i in
            let quiet = i < 64 || (i >= o.breakdown.0 - 1 && i < o.breakdown.1 - 1) || i >= o.bassEnd - 1
            let sub = quiet ? 1e-4 : 1.0  // intro, breakdown and tail: no bass
            return [sub, sub, 1, 1, 1, 1]
        }
        return t
    }

    /// A cue on beat b of t.
    static func cue(_ t: Track, _ b: Int, _ name: String, _ kind: Int) -> Cue {
        Cue(kind: kind, t: t.beats[b - 1], name: name)
    }

    /// Two synthetic tracks: a (id 1) -> b (id 2).
    static func pair(_ ao: Options = Options()) -> (Track, Track) {
        var b = synth()
        b.id = "2"
        b.title = "Other (Original Mix)"
        return (synth(ao), b)
    }

    static func order(_ ts: [Track]) -> [PlaylistTrack] {
        ts.enumerated().map { PlaylistTrack(no: $0 + 1, id: $1.id, title: $1.title, bpm: 128, key: "8A") }
    }

    static func plan(_ a: Track, _ b: Track) -> [SetAction] {
        SetPlanner.plan(order([a, b]), ["1": a, "2": b], TransitionCache())
    }
}
