// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

@preconcurrency import AVFoundation
import AppKit
import Foundation
import Testing

@testable import AutoDJKit

/// Writes stereo audio as 16-bit WAV.
func writeWAV(_ y: Stereo, to path: String, sampleRate: Double = 44100) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let f = try AVAudioFile(
        forWriting: URL(fileURLWithPath: path), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(y.count))!
    b.frameLength = AVAudioFrameCount(y.count)
    y.l.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: y.count) }
    y.r.withUnsafeBufferPointer { b.floatChannelData![1].update(from: $0.baseAddress!, count: y.count) }
    try f.write(from: b)
}

/// A sine wave, optionally with silence before and after (seconds).
func tone(_ hz: Double, _ sec: Double, sampleRate: Double = 44100, before: Double = 0, after: Double = 0) -> Stereo {
    let n0 = Int(before * sampleRate)
    let n1 = Int(sec * sampleRate)
    let n2 = Int(after * sampleRate)
    var v = [Float](repeating: 0, count: n0 + n1 + n2)
    for i in 0..<n1 { v[n0 + i] = Float(sin(2 * .pi * hz * Double(i) / sampleRate) * 0.5) }
    return Stereo(l: v, r: v)
}

@Suite struct AlignmentTests {
    @Test func times() throws {
        for s in [0, 1.2344, 59.9996, 3723.456] {
            #expect(abs(try MixAlign.parseTime(MixAlign.formatTime(s)) - s) <= 0.0005)
        }
        #expect(MixAlign.formatTime(3723.456) == "1:02:03.456")
        for bad in ["", "1:61:00", "a", "1:2:3:4", "-3"] {
            #expect(throws: (any Error).self) { try MixAlign.parseTime(bad) }
        }
        #expect(try MixAlign.parseTime("2:03.5") == 123.5)
    }

    @Test func correlatorMatchesDirect() {
        var g = SeededRandom(5)
        let x = (0..<1000).map { _ in g.float() * 2 - 1 }
        var q = (0..<64).map { _ in g.float() * 2 - 1 }
        _ = Signal.normalise(&q)
        let fast = Correlator(x).ncc(q)
        for L in [0, 17, 500, 936] {
            #expect(abs(fast[L] - Signal.pearson(q, Array(x[L..<L + 64]))) < 1e-9, "lag \(L)")
        }
    }

    /// n frames of random features with a 4-beat pulse and a slow arrangement, so every probe
    /// is distinct (seeded).
    func featureTrack(_ seed: UInt64, _ n: Int) -> [[Float]] {
        var rng = SeededRandom(seed)
        var section = 1.0
        return (0..<n).map { i in
            if i % 400 == 0 { section = 0.5 + rng.float() }
            let pulse = i % 20 == 0 ? 1.0 : 0.2
            return (0..<6).map { _ in Float(section * (pulse + 0.5 * rng.float())) }
        }
    }

    func frames(_ rows: [[Float]]) -> Features.Frames { Features.Frames(data: rows.flatMap { $0 }) }

    /// The whole alignment on feature-level tracks: B overlaps A's last 600 frames and takes
    /// over after 300 of them; C was never played.
    @Test func alignFeatures() throws {
        let A = featureTrack(1, 3000)
        let B = featureTrack(2, 3000)
        let C = featureTrack(3, 3000)
        let at = 2400  // B starts at A's frame 2400
        let rec = (0..<(at + B.count)).map { i in
            (0..<6).map { c -> Float in
                var v: Float = 0
                if i < A.count && i < at + 300 { v += A[i][c] }
                if i >= at && (c != 0 || i >= at + 300) { v += B[i - at][c] }  // B's bass only after the swap
                return v
            }
        }
        let inputs = [
            MixAlign.Input(no: 1, id: "a", title: "A", rec: nil, frames: frames(A)),
            MixAlign.Input(no: 2, id: "c", title: "C", rec: nil, frames: frames(C)),
            MixAlign.Input(no: 3, id: "b", title: "B", rec: nil, frames: frames(B)),
        ]
        let es = MixAlign.align(
            frames(rec), inputs, sampleRate: Int(Features.sr), samples: Int64(rec.count * Features.hop))
        #expect(es[0].located && es[1].status == MixAlign.notFoundState && es[2].located)
        let fps = Features.fps
        let fit = try #require(es[2].inFit)
        #expect(abs(fit.offset - Double(at) / fps) <= 0.05 && abs(fit.r - 1) <= 0.002, "B's fit \(fit)")
        #expect(abs(try MixAlign.parseTime(es[2].cut) - Double(at + 300) / fps) <= 0.5)
    }

    // The test set: demo songs as 88-bar extended mixes, mixed at a fixed 126 BPM (the songs are
    // 123-125: every track plays at r != 1). Each transition starts the next track at its beat 1
    // on the outgoing track's beat 257 and swaps the bass on the incoming beat 65. Track 2 jumps
    // back 64 beats from beat 209 to beat 145, in its solo middle, and the history lists a track
    // between 2 and 3 that was never played.
    static let mixBPM = 126.0
    static let gBeat = 257
    static let swapBeat = 65
    static let layout = Synth.Layout(intro: 8, groove: 16, main: 24, breakdown: 8, drop: 24, outro: 8)

    @Test func alignRenderedSet() async throws {
        let dir = try tempDir()
        var ts: [Track] = []
        for (i, k) in [0, 1, 4, 3].enumerated() {  // Low Sun, Glasshouse, Copper Wire (never played), Night Bus
            var d = Demo.tracks[k]
            d.song.layout = Self.layout
            d.no = i + 1
            let path = dir + "/\(i + 1).wav"
            let y = Synth.render(d.song)
            try writeWAV(y, to: path)
            var t = Demo.analyse(d, path: path, frames: y.count)
            t.length = Double(t.beats.count) * 60 / d.song.bpm + 2
            ts.append(t)
        }
        ts[1].cues = [Cue(kind: 1, t: ts[1].beats[144], name: "JUMP"), Cue(kind: 0, t: ts[1].beats[208], name: "JUMP")]
        let played = [ts[0], ts[1], ts[3]]
        let order = played.enumerated().map {
            PlaylistTrack(no: $0 + 1, id: $1.id, title: $1.title, bpm: $1.bpm, key: "")
        }
        var acts = played.map { SetAction(id: $0.id, title: $0.title) }
        for i in acts.indices {
            acts[i].e = Slot(name: "E", beat: 1, status: .new)
            if i + 1 < acts.count { acts[i].g = Slot(name: "G", beat: Self.gBeat, status: .new) }
            if i > 0 { acts[i].swap = Self.swapBeat }
        }
        let recs = Dictionary(uniqueKeysWithValues: played.map { ($0.id, $0) })
        let res = SetResult(
            playlist: "Test", report: "", order: order, actions: acts, recs: recs, clashes: 0, keyChecks: [],
            suggested: [0, 1, 2], suggestedCost: 0, cache: TransitionCache())
        let plan = PreviewPlan(res, bpm: Self.mixBPM)
        var chunks: [String] = []
        for try await ev in SetRenderer(cacheDir: dir + "/renders").render(plan, pairs: false) {
            if case .mixChunk(let c) = ev { chunks.append(c.file) }
        }
        let mix = dir + "/mix.wav"
        try PreviewExport.encode(chunks, to: mix, format: .wav)

        let audio = try MixExport.probe(mix)
        let recF = try Features.decodeFrames(mix)
        let inputs = try ts.map { t in
            MixAlign.Input(no: Int(t.id)!, id: t.id, title: t.title, rec: t, frames: try Features.decodeFrames(t.path))
        }
        let es = MixAlign.align(recF, inputs, sampleRate: audio.sampleRate, samples: audio.samples)
        for (i, e) in es.enumerated() { #expect(e.located == (i != 2), "track \(e.no): \(e.status) \(e.notes)") }
        #expect(es[2].status == MixAlign.notFoundState && !es[2].kept)

        let segs = plan.mix
        let spb = 60 / Self.mixBPM
        let playedEntries = [es[0], es[1], es[3]]
        for (k, seg) in segs.enumerated() {
            let e = playedEntries[k]
            let truthIn = seg.clock.out0 - seg.clock.src0 / seg.clock.rate
            if k != 1, let f = e.inFit {
                #expect(abs(f.offset - truthIn) <= 0.1 && abs(f.r - seg.clock.rate) <= 0.002, "\(e.title): \(f)")
            }
            if k == 0 {
                #expect(e.cut == "0:00:00.000")
                continue
            }
            let swap = segs[k - 1].swapT!
            #expect(abs(try MixAlign.parseTime(e.cut) - swap) <= spb, "\(e.title): cut \(e.cut), swap \(swap)")
            let tr = try #require(e.transition)
            #expect((tr.e - 1) % SetPlanner.phrase == 0, "\(e.title): \(tr)")
            if k == 2 {
                #expect(tr.e <= Self.swapBeat && tr.g - tr.e == Self.gBeat - 1 && tr.bassSwap == Self.swapBeat, "\(tr)")
            }
        }
        // the loop: track 2 ends 64 of its beats later than it started
        let seg = segs[1]
        let truthOut = seg.clock.out0 - seg.clock.src0 / seg.clock.rate + 64 * 60 / ts[1].bpm / seg.clock.rate
        #expect(abs((playedEntries[1].outFit?.offset ?? 0) - truthOut) <= 0.1)
    }

    @Test func alignmentFileKeepsEdits() throws {
        var e1 = MixAlign.Entry(no: 1, id: "a", title: "A")
        e1.status = MixAlign.ok
        e1.cut = "0:00:00.000"
        var e2 = MixAlign.Entry(no: 2, id: "b", title: "B")
        e2.status = MixAlign.ok
        e2.cutSample = 441_000
        e2.cut = MixAlign.formatTime(10)
        var f = AlignmentFile(
            history: "H", date: "2026-11-07", recording: "/r.wav", sampleRate: 44100, channels: 2, samples: 44100 * 60,
            tracks: [e1, e2])
        #expect(!f.tracks[1].edited(sampleRate: 44100))
        f.tracks[1].cut = "0:00:12.000"  // edited by hand
        #expect(f.tracks[1].edited(sampleRate: 44100))
        #expect(try f.segments().map(\.start) == [0, 529_200])
        let p = try tempDir() + "/alignment.json"
        try f.save(p)
        let back = try #require(try AlignmentFile.load(p))
        var fresh = back
        fresh.tracks[1].cut = MixAlign.formatTime(10)
        #expect(fresh.keepEdits(from: back) == 1 && fresh.tracks[1].cut == "0:00:12.000")
        f.tracks[1].cut = "0:00:00.000"  // not after track 1's
        #expect(throws: AutoDJError.self) { try f.segments() }
    }
}

@Suite struct ExportTests {
    /// A 64x64 red PNG.
    func png(_ path: String) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<64 { for y in 0..<64 { rep.setColor(.red, atX: x, y: y) } }
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }

    /// Cuts 30 s of audio into three files: each plays exactly its samples, they carry the tags
    /// and the cover, and the cue sheet indexes the cuts.
    @Test func export() async throws {
        let dir = try tempDir()
        let rec = dir + "/REC001.WAV"
        let art = dir + "/cover.png"
        try writeWAV(tone(330, 30), to: rec)
        try png(art)
        let a = try MixExport.probe(rec)
        #expect(a == MixExport.Audio(sampleRate: 44100, channels: 2, samples: 30 * 44100))
        let sr = a.sampleRate
        func entry(_ no: Int, _ id: String, _ title: String, _ status: String, at s: Double?) -> MixAlign.Entry {
            var e = MixAlign.Entry(no: no, id: id, title: title)
            e.status = status
            if let s {
                e.cutSample = Int64(s * Double(sr))
                e.cut = MixAlign.formatTime(Double(e.cutSample) / Double(sr))
            }
            return e
        }
        var e4 = entry(4, "13", "Three/Four", MixAlign.noAudio, at: nil)
        e4.cut = "0:00:21.250"
        let f = AlignmentFile(
            history: "H", date: "2026-11-07", recording: rec, sampleRate: sr, channels: 2, samples: a.samples,
            tracks: [
                entry(1, "10", "One", MixAlign.ok, at: 0), entry(2, "11", "Gone", MixAlign.notFoundState, at: nil),
                entry(3, "12", "Two", MixAlign.ok, at: 10.5), e4,
            ])
        var t10 = Tags()
        (t10.title, t10.artist, t10.composer, t10.genre, t10.label, t10.comment) =
            ("One (Original Mix)", "Oxia", "Giorgio Moroder", "Techno", "Kompakt", "8A")
        var t12 = Tags()
        (t12.title, t12.artist) = ("Two", "Two  Artists")
        let tags = ["10": t10, "12": t12]
        let opt = MixExport.Options(
            recording: rec, outDir: dir + "/out", album: "Live at Dene Lodge", dj: "DJ Deavon", date: "2026-11-07",
            art: art)
        let ts = try MixExport.plan(f, tags: tags, outDir: opt.outDir)
        #expect(ts.count == 3 && ts[2].start == 21250 * Int64(sr) / 1000 && ts[1].end == ts[2].start)
        #expect(
            ts.map { ($0.file as NSString).lastPathComponent } == [
                "01 - Oxia - One (Original Mix).m4a", "02 - Two Artists - Two.m4a",
                "03 - Unknown Artist - Three_Four.m4a",
            ])
        try await MixExport.export(f, ts, opt)  // checks every file plays exactly its samples
        for (i, t) in ts.enumerated() {
            let md = try await AVURLAsset(url: URL(fileURLWithPath: t.file)).load(.metadata)
            func value(_ id: AVMetadataIdentifier) async throws -> String? {
                guard let item = AVMetadataItem.metadataItems(from: md, filteredByIdentifier: id).first else {
                    return nil
                }
                return try await item.load(.stringValue)
            }
            #expect(try await value(.iTunesMetadataAlbumArtist) == "DJ Deavon")
            #expect(try await value(.iTunesMetadataAlbum) == "Live at Dene Lodge")
            #expect(!AVMetadataItem.metadataItems(from: md, filteredByIdentifier: .iTunesMetadataCoverArt).isEmpty)
            let trkn = AVMetadataItem.metadataItems(from: md, filteredByIdentifier: .iTunesMetadataTrackNumber).first
            let data = try await trkn?.load(.dataValue)
            #expect(data.map { Int($0[3]) } == i + 1 && data.map { Int($0[5]) } == 3)
            if i == 0 {
                #expect(try await value(.iTunesMetadataComposer) == "Giorgio Moroder")
                #expect(try await value(.iTunesMetadataArtist) == "Oxia")
                #expect(try await value(.iTunesMetadataSongName) == "One (Original Mix)")
                #expect(try await value(.iTunesMetadataGrouping) == "Kompakt")
                #expect(try await value(.iTunesMetadataUserComment) == "8A")
            }
        }
        let paths = try MixExport.writeSheets(f, ts, opt)
        let cue = try String(contentsOfFile: paths[0], encoding: .utf8)
        for want in [
            "FILE \"REC001.WAV\" WAVE", "INDEX 01 00:10:37", "INDEX 01 00:21:18", "PERFORMER \"DJ Deavon\"",
            "SONGWRITER \"Giorgio Moroder\"",
        ] {
            #expect(cue.contains(want), "\(want)")
        }
        let tl = try String(contentsOfFile: paths[1], encoding: .utf8)
        #expect(tl.hasPrefix("0:00:00  Oxia – One (Original Mix)\n0:00:10  Two Artists – Two\n"))
    }

    @Test func cueTime() {
        #expect(MixExport.cueTime(Int64(6000.5 * 44100), 44100) == "100:00:37")
    }

    /// 1.5 s of silence, 10 s of tone, 2 s of silence: the first track starts 10 ms before the
    /// tone and the last ends where it stops; the cut between them stays.
    @Test func trimSilence() throws {
        let dir = try tempDir()
        let rec = dir + "/rec.wav"
        try writeWAV(tone(440, 10, sampleRate: 48000, before: 1.5, after: 2), to: rec, sampleRate: 48000)
        let a = try MixExport.probe(rec)
        let sr = Int64(a.sampleRate)
        var e1 = MixAlign.Entry(no: 1, id: "1", title: "")
        e1.status = MixAlign.ok
        e1.cut = "0:00:00.000"
        var e2 = MixAlign.Entry(no: 2, id: "2", title: "")
        e2.status = MixAlign.ok
        e2.cutSample = 6 * sr
        e2.cut = MixAlign.formatTime(6)
        let f = AlignmentFile(
            history: "", date: "", recording: rec, sampleRate: a.sampleRate, channels: a.channels, samples: a.samples,
            tracks: [e1, e2])
        var ts = try MixExport.plan(f, tags: [:], outDir: dir)
        try MixExport.trimSilence(f, &ts, recording: rec)
        func near(_ got: Int64, _ want: Double) -> Bool { abs(Double(got) / Double(sr) - want) < 0.005 }
        #expect(near(ts[0].start, 1.49) && ts[0].end == 6 * sr && ts[1].start == 6 * sr && near(ts[1].end, 11.5))
    }
}

@Suite struct DemoTests {
    @Test func analysePhrases() {
        let tr = Demo.tracks[0]  // standard layout: 112 bars at 124 BPM
        let step = 44100 * 60 / 124.0 / 4
        let r = Demo.analyse(tr, path: "x.aiff", frames: Int(112 * 16 * step) + 2 * 44100)
        #expect(
            r.phrases == [
                Phrase(beat: 1, label: "Intro"), Phrase(beat: 65, label: "Up"), Phrase(beat: 129, label: "Chorus"),
                Phrase(beat: 193, label: "Down"), Phrase(beat: 257, label: "Chorus"),
                Phrase(beat: 321, label: "Chorus"),
                Phrase(beat: 385, label: "Outro"),
            ])
        #expect(r.beats.count == 452 && r.beats[4] == 4 * 60 / 124.0 && r.bnum[4] == 1 && r.bnum[7] == 4)
    }

    /// The imported order has exactly one key clash, which the suggested order resolves.
    @Test func keyClashIsPlanted() {
        let order = Demo.order
        for (i, t) in Demo.tracks.enumerated() {
            #expect(t.no == i + 1 && Camelot(t.key) != nil)
        }
        func clashes(_ o: [PlaylistTrack]) -> Int { Keys.checkOrder(o).filter { !$0.move.ok }.count }
        #expect(clashes(order) == 1)
        let (sug, _) = Keys.suggestOrder(order.map { Keys.Item(key: $0.key, bpm: $0.bpm) }, keepFirst: true)
        #expect(clashes(sug.map { order[$0] }) == 0)
    }

    @Test func toneLeadFollowsTheChords() {
        let notes = Demo.toneLead(Demo.progWalk, Demo.motifCall)
        #expect(notes.count == 4 * Demo.motifCall.count)
        // bar 2 (Dm9, voiced 53 57 60 62 64): index 4 is E4, an octave up
        let n = notes[Demo.motifCall.count]
        #expect(n.step == 16 && n.midi == 76)
    }

    /// A song small enough to render in a test: 26 fast bars.
    static let short = Synth.Song(
        bpm: 300, seed: 3, prog: Array(repeating: Synth.Chord(root: 33, notes: [57, 64]), count: 4),
        lead: [Synth.Note(step: 0, midi: 76, len: 2), Synth.Note(step: 20, midi: 72, len: 2)],
        bass: [Synth.Hit(step: 2, interval: 0, len: 1.6, gain: 0.55)], stabs: [0],
        layout: Synth.Layout(intro: 2, groove: 9, main: 1, breakdown: 5, drop: 1, outro: 8))

    @Test func synthIsDeterministicWithLengthAndLevel() {
        let a = Synth.render(Self.short)
        #expect(a == Synth.render(Self.short))
        let step = Synth.sr * 60 / 300 / 4
        #expect(a.count == Int(26 * 16 * step) + Int(2 * Synth.sr))
        let peak = max(a.l.map(abs).max()!, a.r.map(abs).max()!)
        #expect(!a.l.contains { $0.isNaN } && abs(peak - 0.89) < 1e-6)
    }

    @Test func sections() {
        let s = Synth.Layout(intro: 16, groove: 16, main: 16, breakdown: 16, drop: 32, outro: 16).sections
        #expect(s == Synth.Sections(groove: 16, main: 32, breakdown: 48, drop: 64, outro: 96, end: 112))
    }
}
