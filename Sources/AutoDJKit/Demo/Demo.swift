// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

@preconcurrency import AVFoundation
import Foundation

/// The demo set: ten original house tracks rendered by `Synth`, and the walkthrough built from
/// them (`auto-dj demo`, the app's Demo, and the docs). The tracks carry no third-party rights,
/// and because the generator knows each track's beat grid, phrases and key, the walkthrough
/// runs the real rules, set planner and preview without Rekordbox (port of internal/demo,
/// docs/decisions/0014-generated-demo-set.md).
public enum Demo {
    /// The demo playlist's name.
    public static let playlist = "auto-dj demo"

    /// One demo track.
    public struct DemoTrack: Sendable {
        /// Position in the demo playlist (1-based).
        public var no: Int
        public var title: String
        /// Rekordbox key notation, e.g. "F#m".
        public var key: String
        public var song: Synth.Song

        /// The track's file name.
        public var file: String { String(format: "%02d %@.aiff", no, title) }
    }

    // The chord progressions, voiced for A minor (transposed per track).
    static let am9: [Double] = [57, 60, 64, 67, 71]
    static let am7: [Double] = [57, 60, 64, 67]
    static let fmaj9: [Double] = [53, 57, 60, 64, 67]
    static let fmaj7: [Double] = [53, 57, 60, 64]
    static let cmaj7: [Double] = [55, 60, 64, 67, 71]
    static let em7: [Double] = [55, 59, 62, 64, 67]
    static let dm9: [Double] = [53, 57, 60, 62, 64]
    static let g6: [Double] = [55, 59, 62, 64, 67]
    static let gmaj: [Double] = [55, 59, 62, 67]
    static let cmaj7b: [Double] = [55, 60, 64, 71]
    static func ch(_ root: Double, _ notes: [Double]) -> Synth.Chord { Synth.Chord(root: root, notes: notes) }
    static let progDeep = [ch(33, am9), ch(29, fmaj9), ch(36, cmaj7), ch(28, em7)]  // i9 VI9 III7 v7
    static let progWalk = [ch(33, am7), ch(38, dm9), ch(31, g6), ch(36, cmaj7b)]  // i7 iv9 VII6 III7
    static let progLift = [ch(33, am9), ch(31, g6), ch(29, fmaj7), ch(31, gmaj)]  // i9 VII6 VI7 VII
    static let progHold = [ch(33, am7), ch(33, am9), ch(38, dm9), ch(28, em7)]  // i7 i9 iv9 v7
    static let progRise = [ch(29, fmaj7), ch(31, gmaj), ch(33, am7), ch(33, am9)]  // VI7 VII i7 i9

    static func hit(_ step: Double, _ interval: Double, _ len: Double, _ gain: Double) -> Synth.Hit {
        Synth.Hit(step: step, interval: interval, len: len, gain: gain)
    }

    static func note(_ step: Double, _ midi: Double, _ len: Double) -> Synth.Note {
        Synth.Note(step: step, midi: midi, len: len)
    }

    /// The first track's hand-written lead (A minor).
    static let lowSun = [
        note(0, 76, 2), note(3, 79, 1), note(4, 81, 3), note(8, 79, 2), note(11, 76, 1), note(12, 74, 4),
        note(16, 72, 2), note(19, 74, 1), note(20, 76, 3), note(24, 72, 2), note(27, 69, 1), note(28, 72, 4),
        note(32, 76, 2), note(35, 79, 1), note(36, 83, 3), note(40, 81, 2), note(43, 79, 1), note(44, 76, 4),
        note(48, 74, 2), note(51, 76, 1), note(52, 79, 3), note(56, 76, 4), note(60, 74, 2), note(62, 71, 2),
    ]

    /// A lead note as an index into the bar's chord voicing (sorted low to high; past the top
    /// it wraps an octave up), played an octave above the chord.
    typealias Tone = (step: Double, idx: Double, len: Double)

    static let motifArp: [Tone] = [
        (0, 0, 1.5), (2, 1, 1.5), (4, 2, 1.5), (6, 3, 1.5), (8, 4, 1.5), (10, 3, 1.5), (12, 2, 1.5), (14, 1, 1.5),
    ]
    static let motifCall: [Tone] = [(0, 4, 3), (3, 3, 1), (6, 2, 2), (10, 4, 2), (14, 3, 2)]
    static let motifLong: [Tone] = [(0, 4, 6), (8, 3, 4), (12, 2, 4)]
    static let motifPluck: [Tone] = [(0, 2, 1), (3, 4, 1), (6, 3, 1), (8, 2, 1), (11, 4, 1), (14, 3, 2)]

    /// Spells a per-bar motif over a progression.
    static func toneLead(_ prog: [Synth.Chord], _ motif: [Tone]) -> [Synth.Note] {
        prog.enumerated().flatMap { bar, c in
            let ns = c.notes.sorted()
            return motif.map { m in
                let i = Int(m.idx)
                return note(Double(bar * 16) + m.step, ns[i % ns.count] + 12 * Double(i / ns.count) + 12, m.len)
            }
        }
    }

    static let bassOffbeat = [
        hit(2, 0, 1.6, 0.55), hit(6, 0, 1.6, 0.55), hit(10, 0, 1.6, 0.55), hit(14, 12, 1.6, 0.55), hit(7, 7, 0.8, 0.35),
    ]
    static let bassRolling = [
        hit(2, 0, 0.9, 0.5), hit(3, 12, 0.9, 0.4), hit(6, 0, 0.9, 0.5), hit(7, 12, 0.9, 0.4),
        hit(10, 0, 0.9, 0.5), hit(11, 12, 0.9, 0.4), hit(14, 0, 0.9, 0.5), hit(15, 7, 0.9, 0.4),
    ]
    static let bassSync = [
        hit(3, 0, 2, 0.55), hit(6, 0, 1.5, 0.5), hit(10, 0, 2, 0.55), hit(13, 7, 1, 0.4), hit(14, 12, 1.5, 0.45),
    ]
    static let bassLong = [hit(2, 0, 3, 0.55), hit(6, 0, 3, 0.55), hit(10, 7, 3, 0.5), hit(14, 0, 1.6, 0.55)]

    static let stabsDeep: [Double] = [0, 3, 6, 10, 13]
    static let stabsOrgan: [Double] = [2, 6, 10, 14]
    static let stabsDotted: [Double] = [0, 6, 12]
    static let stabsPush: [Double] = [3, 7, 11, 14]

    static let standard = Synth.Layout(intro: 16, groove: 16, main: 16, breakdown: 16, drop: 32, outro: 16)
    static let longIn = Synth.Layout(intro: 32, groove: 16, main: 16, breakdown: 16, drop: 32, outro: 16)
    static let short = Synth.Layout(intro: 16, groove: 16, main: 8, breakdown: 16, drop: 32, outro: 16)

    /// The shift from A minor to the key's tonic, kept within -6..+5 semitones so every track
    /// sits in the same register.
    static func transpose(_ tonic: Int) -> Double { Double((tonic - 9 + 18) % 12 - 6) }

    static func song(
        _ bpm: Double, _ tonic: Int, _ seed: UInt64, _ prog: [Synth.Chord], _ lead: [Synth.Note], _ bass: [Synth.Hit],
        _ stabs: [Double], cut: Double = 0, _ layout: Synth.Layout
    ) -> Synth.Song {
        Synth.Song(
            bpm: bpm, transpose: transpose(tonic), seed: seed, prog: prog, lead: lead, bass: bass, stabs: stabs,
            stabCut: cut, layout: layout)
    }

    /// The demo playlist in its imported order. Its keys run round the Camelot wheel (8A →
    /// 12A), except that "Paper Lanterns" is filed third: a clash the key check finds and the
    /// suggested order fixes.
    public static let tracks: [DemoTrack] = [
        DemoTrack(
            no: 1, title: "Low Sun", key: "Am",
            song: song(124, 9, 1, progDeep, lowSun, bassOffbeat, stabsDeep, standard)),
        DemoTrack(
            no: 2, title: "Glasshouse", key: "Am",
            song: song(124, 9, 2, progWalk, toneLead(progWalk, motifCall), bassRolling, stabsOrgan, cut: 2200, standard)
        ),
        DemoTrack(
            no: 3, title: "Paper Lanterns", key: "F#m",
            song: song(125, 6, 7, progRise, toneLead(progRise, motifArp), bassOffbeat, stabsPush, standard)),
        DemoTrack(
            no: 4, title: "Night Bus", key: "Em",
            song: song(123, 4, 3, progLift, toneLead(progLift, motifPluck), bassSync, stabsDeep, cut: 1500, longIn)),
        DemoTrack(
            no: 5, title: "Copper Wire", key: "Em",
            song: song(124, 4, 4, progHold, toneLead(progHold, motifLong), bassLong, stabsDotted, standard)),
        DemoTrack(
            no: 6, title: "Slow Orbit", key: "Bm",
            song: song(124, 11, 5, progRise, toneLead(progRise, motifCall), bassRolling, stabsPush, cut: 2000, short)),
        DemoTrack(
            no: 7, title: "Tidewater", key: "Bm",
            song: song(125, 11, 6, progDeep, toneLead(progDeep, motifArp), bassOffbeat, stabsOrgan, longIn)),
        DemoTrack(
            no: 8, title: "Northbound", key: "F#m",
            song: song(125, 6, 8, progWalk, toneLead(progWalk, motifPluck), bassSync, stabsDeep, cut: 2400, standard)),
        DemoTrack(
            no: 9, title: "Afterglow", key: "C#m",
            song: song(126, 1, 9, progLift, toneLead(progLift, motifLong), bassLong, stabsDotted, short)),
        DemoTrack(
            no: 10, title: "Last Train Home", key: "C#m",
            song: song(126, 1, 10, progHold, toneLead(progHold, motifCall), bassOffbeat, stabsDeep, cut: 1600, standard)
        ),
    ]

    // ---------------------------------------------------------------- rendering

    /// A demo track on disk as a library track, with the analysis Rekordbox would find in it.
    public static func analyse(_ t: DemoTrack, path: String, frames: Int) -> Track {
        let s = t.song
        let length = Double(frames) / Synth.sr
        let nb = Int(length * s.bpm / 60)
        var r = Track(id: String(t.no), title: t.title)
        r.path = path
        r.bpm = s.bpm
        r.length = length
        r.beats = (0..<nb).map { Double($0) * 60 / s.bpm }
        r.bnum = (0..<nb).map { $0 % 4 + 1 }
        r.mood = 1
        r.category = "nohot"
        r.local = true
        let l = s.layout
        var bar = 0
        for (label, bars) in [
            ("Intro", l.intro), ("Up", l.groove), ("Chorus", l.main), ("Down", l.breakdown), ("Chorus", l.drop),
            ("Outro", l.outro),
        ] {
            for b in stride(from: 0, to: bars, by: 16) {
                r.phrases.append(Phrase(beat: (bar + b) * 4 + 1, label: label))
            }
            bar += bars
        }
        return r
    }

    /// Writes stereo audio as 24-bit AIFF.
    public static func writeAIFF(_ y: Stereo, to path: String) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Synth.sr, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true,
        ]
        try? FileManager.default.removeItem(atPath: path)
        let f = try AVAudioFile(
            forWriting: URL(fileURLWithPath: path), settings: settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        let fmt = f.processingFormat
        var i = 0
        while i < y.count {
            let k = min(1 << 16, y.count - i)
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(k))!
            b.frameLength = AVAudioFrameCount(k)
            y.l.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress! + i, count: k) }
            y.r.withUnsafeBufferPointer { b.floatChannelData![1].update(from: $0.baseAddress! + i, count: k) }
            try f.write(from: b)
            i += k
        }
    }

    /// Renders every demo track into dir as 24-bit AIFF (two at a time: a track needs about
    /// 1.5 GB while it renders) and returns them as library tracks. A track already there is
    /// reused.
    public static func render(into dir: String, progress: @Sendable (Int) -> Void = { _ in }) async throws -> [Track] {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var out = [Track?](repeating: nil, count: tracks.count)
        try await withThrowingTaskGroup(of: (Int, Track).self) { g in
            var next = 0
            func add() {
                let i = next
                next += 1
                g.addTask {
                    let t = tracks[i]
                    let path = (dir as NSString).appendingPathComponent(t.file)
                    if let info = try? AudioDecoder.info(path), info.duration > 0 {
                        return (i, analyse(t, path: path, frames: Int((info.duration * Synth.sr).rounded())))
                    }
                    let y = Synth.render(t.song)
                    try writeAIFF(y, to: path)
                    return (i, analyse(t, path: path, frames: y.count))
                }
            }
            for _ in 0..<min(2, tracks.count) { add() }
            var done = 0
            while let (i, t) = try await g.next() {
                out[i] = t
                done += 1
                progress(done)
                if next < tracks.count { add() }
            }
        }
        return out.map { $0! }
    }

    /// The demo playlist's tracks.
    public static var order: [PlaylistTrack] {
        tracks.map { PlaylistTrack(no: $0.no, id: String($0.no), title: $0.title, bpm: $0.song.bpm, key: $0.key) }
    }

    /// A plan item as the cues `apply --write` leaves on the track.
    static func cuesOf(_ it: CuePlan.Item) -> [Cue] {
        it.hot.map { h in
            var c = Cue(kind: h.kind, t: Double(h.ms) / 1000, name: h.name)
            if let loop = h.loop, let out = h.outMS {
                c.out = Double(out) / 1000
                c.activeLoop = 1
                c.beatLoopSize = loop << 16 + 1
            }
            return c
        } + it.mem.map { Cue(kind: 0, t: Double($0.ms) / 1000, name: $0.name) }
    }

    /// The demo set ready to plan: rendered, analysed, its features extracted, and cued by the
    /// plan as `apply --write` would (Rekordbox's analysis is replaced by the generator's own
    /// grid and phrases). The returned plan items are what `plan` printed.
    public static func library(tracksDir: String, progress: @Sendable (String) -> Void = { _ in }) async throws -> (
        recs: [String: Track], plan: [CuePlan.Item]
    ) {
        progress("rendering \(tracks.count) tracks")
        var ts = try await render(into: tracksDir) { progress("rendered \($0) of \(tracks.count)") }
        let featDir = (tracksDir as NSString).appendingPathComponent("features")
        progress("analysing the audio")
        let res = try await Features.extractMany(ts.map(\.path), featureDir: featDir, workers: 4)
        for (t, r) in zip(ts, res) {
            if case .error(let e) = r { throw AutoDJError("features \(t.path): \(e)") }
        }
        for i in ts.indices {
            ts[i].fb = try Features.perBeat(
                featureDir: featDir, audioPath: ts[i].path, beats: ts[i].beats, bpm: ts[i].bpm)
            ts[i].vocals = try Vocals.perBeat(
                featureDir: featDir, audioPath: ts[i].path, beats: ts[i].beats, bpm: ts[i].bpm)
        }
        let items = CuePlan.make(ts, ["nohot"], .default)  // freshly analysed tracks have no hot cues
        for i in ts.indices {  // apply --write: the planned cues land on the tracks, which become "auto"
            ts[i].cues = cuesOf(items[i])
            ts[i].category = "auto"
        }
        return (Dictionary(uniqueKeysWithValues: ts.map { ($0.id, $0) }), items)
    }

    // ---------------------------------------------------------------- walkthrough

    /// What a walkthrough printed, step by step, and the preview page it built.
    public struct Walkthrough: Sendable {
        public var features: String
        public var plan: String
        public var setCheck: String
        public var setSuggested: String
        public var page: String
    }

    /// Renders the demo tracks into tracksDir and runs the whole pipeline on them, writing into
    /// outDir what each step prints (text fragments the docs include) and the set's preview
    /// page (outDir/preview).
    public static func walkthrough(
        tracksDir: String, outDir: String, bpm: Double, renderer: SetRenderer, format: ExportFormat = .m4a,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> Walkthrough {
        let (recs, items) = try await library(tracksDir: tracksDir, progress: progress)
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        func write(_ name: String, _ s: String) throws {
            let text = s.trimmingCharacters(in: .newlines) + "\n"
            try Data(text.utf8).write(to: URL(fileURLWithPath: (outDir as NSString).appendingPathComponent(name)))
        }
        let ts = tracks.map { recs[String($0.no)]! }
        try write("tracks.md", trackTable(ts))
        let feat = "\(tracks.count) files: ok \(tracks.count)"
        try write("features.txt", feat)
        let plan = CuePlan.summary(items)
        try write("plan.txt", plan + "\nplan written to ~/.cache/auto-dj/plan.json")
        try write("plan.md", cueTable(items))
        let first = try SetRun.plan(playlist, order, recs, TransitionCache(), order: .playlist, freeStart: false)
        try write("set-check.txt", first.report)
        let sug = try SetRun.plan(playlist, order, recs, TransitionCache(), order: .suggested, freeStart: false)
        try write("set-suggested.txt", sug.report)
        progress("rendering the previews")
        let page = try await PreviewExport.build(
            PreviewPlan(sug, bpm: bpm), renderer: renderer, to: (outDir as NSString).appendingPathComponent("preview"),
            mix: true, format: format)
        return Walkthrough(features: feat, plan: plan, setCheck: first.report, setSuggested: sug.report, page: page)
    }

    static func trackTable(_ ts: [Track]) -> String {
        var b = "| #   | Title | Key | BPM | Length | File |\n| --- | ----- | --- | --- | ------ | ---- |\n"
        for (t, d) in zip(ts, tracks) {
            let bpm = d.song.bpm.rounded() == d.song.bpm ? String(Int(d.song.bpm)) : String(d.song.bpm)
            b += "| \(d.no) | \(d.title) | \(d.key) | \(bpm) | \(SetRun.minSec(t.length)) | `\(d.file)` |\n"
        }
        return b
    }

    static func cueTable(_ items: [CuePlan.Item]) -> String {
        var b = "| Track | IN (A) | BRIDGE (B) | DROP (C) | OUT (D) | EMERGENCY (H) | Memory cues |\n"
        b += "| ----- | ------ | ---------- | -------- | ------- | ------------- | ----------- |\n"
        for it in items {
            func cell(_ n: String) -> String { it.hot.first { $0.name == n }.map { String($0.beat) } ?? "—" }
            let mem = it.mem.map { "\($0.name) \($0.beat)" }.joined(separator: " · ")
            b +=
                "| \(it.title) | \(cell("IN")) | \(cell("BRIDGE")) | \(cell("DROP")) | \(cell("OUT")) | "
                + "\(cell("EMERGENCY")) | \(mem) |\n"
        }
        return b
    }
}
