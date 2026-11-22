// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

@preconcurrency import AVFoundation
import Foundation

/// One transition clip: A and B as `Timeline.pair` plans them.
public struct PairClip: Sendable {
    public var a: Seg
    public var b: Seg
}

/// A transition's preview: its clip, or why it has none.
public struct PairPreview: Sendable {
    public var i: Int
    public var clip: PairClip?
    public var reason: String?
}

/// Everything about a set's previews that is known before any audio exists: the mix and
/// clip timelines and the set-list page's data (port of internal/preview/preview.go).
///
/// The full-set mix plays the original tracks end to end: each track from its E (the first
/// from START) to where it leaves the mix. When A reaches G, B starts at E, time-stretched to
/// the playing tempo (key kept) and fading in over 8 beats. Until the bass swap B's bass is
/// filtered out; at the bass swap the bass moves to B (A is low-cut). A leaves the mix on its
/// exit: on FILTER a low-pass sweep to silence over 8 beats, then a fade out over 4 beats; on
/// CUT an immediate cut; with neither, a fade out over 8 beats from the bass swap. Once A has
/// gone B returns to its own tempo. With a fixed set tempo every track plays at that tempo
/// throughout instead, key kept. The last track plays to its end. Every track follows its
/// jumps. Each transition clip is the same mix of just A and B: A from 8 beats before G,
/// ending 8 beats after A has left.
public struct PreviewPlan: Sendable {
    public var playlist: String
    public var bpm: Double
    public var mix: [Seg]
    public var pairs: [PairPreview]
    public var order: [PlaylistTrack]
    public var actions: [SetAction]
    public var recs: [String: Track]

    /// The mix's length in seconds.
    public var duration: Double { mix.filter { !$0.missing }.map(\.end).max() ?? 0 }

    public init(_ res: SetResult, bpm: Double, audioExists: (Track?) -> Bool = Timeline.audioOK) {
        playlist = res.playlist
        self.bpm = max(bpm, 0)
        order = res.order
        actions = res.actions
        recs = res.recs
        mix = Timeline.mix(res.order, res.actions, res.recs, bpm: bpm, audioExists: audioExists)
        pairs = (0..<max(res.order.count - 1, 0)).map { i in
            let a = res.recs[res.order[i].id]
            let b = res.recs[res.order[i + 1].id]
            guard a != nil, b != nil, res.actions[i].g != nil, res.actions[i + 1].e != nil, audioExists(a),
                audioExists(b)
            else { return PairPreview(i: i, reason: "audio file not found (streaming track?)") }
            let (sa, sb) = Timeline.pair(
                Array(res.order[i...i + 1]), Array(res.actions[i...i + 1]), res.recs, bpm: bpm, audioExists: audioExists
            )
            return PairPreview(i: i, clip: PairClip(a: sa, b: sb))
        }
    }
}

// MARK: - the set-list page's data

/// The set-list page's data (set.json), in the shape setlist.html reads.
public struct PageData: Encodable, Sendable {
    public var playlist: String
    public var bpm: Double?
    public var tracks: [PageTrack]
    public var pairs: [PagePair]
    public var mix: PageMix?

    public struct PageTrack: Encodable, Sendable {
        var n: Int
        var title: String
        var key: String
        var bpm: Double
        var E: [JSONScalar]?
        var G: [JSONScalar]?
        var bassSwap: String?
        var exit: [JSONScalar]?
        var markers: [[JSONScalar]]
        var warnings: [String]

        enum CodingKeys: String, CodingKey {
            case n, title, key, bpm, E, G, bassSwap = "bass_swap", exit, markers, warnings
        }

        public func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(n, forKey: .n)
            try c.encode(title, forKey: .title)
            try c.encode(key, forKey: .key)
            try c.encode(bpm, forKey: .bpm)
            try c.encode(E, forKey: .E)  // null when absent, as the page expects
            try c.encode(G, forKey: .G)
            try c.encode(bassSwap, forKey: .bassSwap)
            try c.encode(exit, forKey: .exit)
            try c.encode(markers, forKey: .markers)
            try c.encode(warnings, forKey: .warnings)
        }
    }

    public struct PagePair: Encodable, Sendable {
        var i: Int
        var file: String?
        var reason: String?
        var dur, bOffset: Double?
        var fadeIn: [Double]?
        var swapT: Double?
        var fadeOut: [Double]?
        var exit: String?
        var filterT: [Double]?
        var sync: Bool?
        var jumps: [[JSONScalar]]?
        var beatS, bpm, tempo: Double?
        var g, e, swapB: Int?
        var estimatedSwap: Bool?
        var gTime, eTime, swapTime: String?

        enum CodingKeys: String, CodingKey {
            case i, file, reason, dur, bOffset = "b_offset", fadeIn = "fade_in", swapT = "swap_t", fadeOut = "fade_out"
            case exit, filterT = "filter_t", sync, jumps, beatS = "beat_s", bpm, tempo, g, e, swapB = "swap_b"
            case estimatedSwap = "estimated_swap", gTime = "g_time", eTime = "e_time", swapTime = "swap_time"
        }

        public func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(i, forKey: .i)
            try c.encode(file, forKey: .file)
            if let reason {
                try c.encode(reason, forKey: .reason)
                return
            }
            try c.encodeIfPresent(dur, forKey: .dur)
            try c.encodeIfPresent(bOffset, forKey: .bOffset)
            try c.encodeIfPresent(fadeIn, forKey: .fadeIn)
            try c.encode(swapT, forKey: .swapT)
            try c.encodeIfPresent(fadeOut, forKey: .fadeOut)
            try c.encodeIfPresent(exit, forKey: .exit)
            try c.encode(filterT, forKey: .filterT)
            try c.encodeIfPresent(sync, forKey: .sync)
            try c.encodeIfPresent(jumps, forKey: .jumps)
            try c.encodeIfPresent(beatS, forKey: .beatS)
            try c.encodeIfPresent(bpm, forKey: .bpm)
            try c.encodeIfPresent(tempo, forKey: .tempo)
            try c.encodeIfPresent(g, forKey: .g)
            try c.encodeIfPresent(self.e, forKey: .e)
            try c.encodeIfPresent(swapB, forKey: .swapB)
            try c.encodeIfPresent(estimatedSwap, forKey: .estimatedSwap)
            try c.encodeIfPresent(gTime, forKey: .gTime)
            try c.encodeIfPresent(eTime, forKey: .eTime)
            try c.encodeIfPresent(swapTime, forKey: .swapTime)
        }
    }

    public struct PageMix: Encodable, Sendable {
        var file: String
        var dur: Double
        var tracks: [MixTrack]
    }

    /// The page's view of one mix segment.
    public struct MixTrack: Encodable, Sendable {
        public var n: Int
        public var title: String
        public var missing: Bool?
        public var start, end: Double?
        public var g, swap: Double?
        public var estimatedSwap: Bool?
        public var exit: String?
        public var exitT: [Double]?
        public var sync: Bool?
        public var jumps: [Double]?

        enum CodingKeys: String, CodingKey {
            case n, title, missing, start, end, g, swap, estimatedSwap = "estimated_swap", exit, exitT = "exit_t", sync,
                jumps
        }

        public func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(n, forKey: .n)
            try c.encode(title, forKey: .title)
            if missing == true {
                try c.encode(true, forKey: .missing)
                return
            }
            try c.encodeIfPresent(start, forKey: .start)
            try c.encodeIfPresent(end, forKey: .end)
            try c.encode(g, forKey: .g)
            try c.encode(swap, forKey: .swap)
            try c.encodeIfPresent(estimatedSwap, forKey: .estimatedSwap)
            try c.encodeIfPresent(exit, forKey: .exit)
            try c.encodeIfPresent(exitT, forKey: .exitT)
            try c.encodeIfPresent(sync, forKey: .sync)
            try c.encodeIfPresent(jumps, forKey: .jumps)
        }
    }

    static func r2(_ v: Double) -> Double { Num.roundTo(v, 2) }

    /// The page's view of the mix timeline: when each track plays and how it leaves.
    public static func mixInfo(_ segs: [Seg]) -> (Double, [MixTrack]) {
        var dur = 0.0
        let tracks = segs.map { s -> MixTrack in
            if s.missing { return MixTrack(n: s.n, title: s.title, missing: true) }
            dur = max(dur, s.end)
            return MixTrack(
                n: s.n, title: s.title, start: r2(s.start), end: r2(s.end), g: s.gT.map(r2), swap: s.swapT.map(r2),
                estimatedSwap: s.estimatedSwap, exit: s.exit.kind.rawValue, exitT: s.exit.xs.map(r2), sync: s.sync,
                jumps: s.jumps.map(r2))
        }
        return (r2(dur), tracks)
    }

    /// The page data for a plan; ext names the audio files (clips "01-02.<ext>", mix "set.<ext>").
    public init(_ plan: PreviewPlan, ext: String, mix withMix: Bool) {
        playlist = plan.playlist
        bpm = plan.bpm > 0 ? plan.bpm : nil
        tracks = plan.order.enumerated().map { i, x in Self.track(i, x, plan.actions[i], plan.recs[x.id]) }
        pairs = plan.pairs.map { p in
            guard let clip = p.clip else { return PagePair(i: p.i, reason: p.reason) }
            return Self.pair(p.i, clip, plan, ext: ext)
        }
        if withMix, plan.mix.contains(where: { !$0.missing }) {
            let (dur, ts) = Self.mixInfo(plan.mix)
            mix = PageMix(file: "set." + ext, dur: dur, tracks: ts)
        }
    }

    static func at(_ t: Track, _ b: Int) -> String { SetRun.minSec(beatTime(t, b)) }

    /// A track's line on the set-list page (cue positions as m:ss).
    static func track(_ i: Int, _ x: PlaylistTrack, _ act: SetAction, _ t: Track?) -> PageTrack {
        var pt = PageTrack(n: i + 1, title: x.title, key: x.key, bpm: x.bpm, markers: [], warnings: act.warnings)
        guard let t else { return pt }
        if let e = act.e { pt.E = [.s(e.name), .s(at(t, e.beat)), .s(e.status.rawValue)] }
        let liveG = act.g != nil && act.g!.status != .clear
        if liveG, let g = act.g { pt.G = [.s(g.name), .s(at(t, g.beat)), .s(g.status.rawValue)] }
        if let b = act.bassSwap?.beat { pt.bassSwap = at(t, b) }
        if liveG, let ex = act.exit { pt.exit = [.s(ex.name), .s(at(t, ex.a))] }
        pt.markers = act.markers.map { [.s($0.name), .s(at(t, $0.beat)), .s($0.status.rawValue)] }
        return pt
    }

    /// The clip file name of transition i.
    public static func clipName(_ i: Int, ext: String) -> String { String(format: "%02d-%02d.", i + 1, i + 2) + ext }

    static func pair(_ i: Int, _ clip: PairClip, _ plan: PreviewPlan, ext: String) -> PagePair {
        let (sa, sb) = (clip.a, clip.b)
        let a = sa.rec!
        let b = sb.rec!
        let A = plan.actions[i]
        let B = plan.actions[i + 1]
        let play = plan.bpm > 0 ? plan.bpm : a.bpm  // the tempo B is matched to
        let eBeat = B.e!.beat
        let swapB = (B.swap ?? 0) > eBeat ? B.swap! : eBeat + 32
        let xs = sa.exit.xs
        var p = PagePair(i: i, file: clipName(i, ext: ext))
        p.dur = r2(sb.end)
        p.bOffset = r2(sb.start)
        p.fadeIn = sb.fadeIn.map { [r2($0.0), r2($0.1)] } ?? [r2(sb.start), r2(sb.start)]
        p.swapT = sa.swapT.map(r2)
        p.fadeOut = [r2(xs[0]), r2(xs[xs.count - 1])]
        p.exit = sa.exit.kind.rawValue
        p.filterT = sa.exit.kind == .filter ? [r2(xs[0]), r2(xs[1])] : nil
        p.sync = sb.sync
        p.jumps = sa.jumps.map { [.s("a"), .d(r2($0))] } + sb.jumps.map { [.s("b"), .d(r2($0))] }
        p.beatS = Num.roundTo(60 / play, 4)
        p.bpm = play
        p.tempo = Num.roundTo(play / b.bpm, 4)
        p.g = A.g!.beat
        p.e = eBeat
        p.swapB = swapB
        p.estimatedSwap = sa.estimatedSwap
        p.gTime = SetRun.minSec(beatTime(a, A.g!.beat))
        p.eTime = SetRun.minSec(beatTime(b, eBeat))
        p.swapTime = SetRun.minSec(beatTime(b, swapB))
        return p
    }
}

// MARK: - export

/// Audio formats the bundle can be written in.
public enum ExportFormat: String, Sendable, CaseIterable {
    /// AAC in an MPEG-4 container: every browser plays it (the default).
    case m4a
    /// Uncompressed 16-bit PCM.
    case wav
}

/// Writes the preview bundle (index.html, set.json, the clips and the mix) to a folder:
/// today's --preview-dir layout (ADR 0019).
public enum PreviewExport {
    /// Encodes PCM files (concatenated in order) into one audio file.
    public static func encode(_ parts: [String], to out: String, format: ExportFormat) throws {
        let settings: [String: Any]
        switch format {
        case .m4a:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Mix.sampleRate, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ]
        case .wav:
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Mix.sampleRate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]
        }
        try? FileManager.default.removeItem(atPath: out)
        let f = try AVAudioFile(
            forWriting: URL(fileURLWithPath: out), settings: settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        for p in parts {
            let src = try AVAudioFile(forReading: URL(fileURLWithPath: p))
            let buf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: 1 << 16)!
            while src.framePosition < src.length {
                try src.read(into: buf)
                if buf.frameLength == 0 { break }
                try f.write(from: buf)
            }
        }
    }

    /// Writes index.html + set.json for the plan and encodes the rendered clips and mix chunks
    /// into dir. Returns the page's path.
    public static func write(
        _ plan: PreviewPlan, clips: [Int: String], mixChunks: [String], to dir: String, format: ExportFormat
    ) throws -> String {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ext = format.rawValue
        for (i, file) in clips {
            try encode(
                [file], to: (dir as NSString).appendingPathComponent(PageData.clipName(i, ext: ext)), format: format)
        }
        if !mixChunks.isEmpty {
            try encode(mixChunks, to: (dir as NSString).appendingPathComponent("set." + ext), format: format)
        }
        var data = PageData(plan, ext: ext, mix: !mixChunks.isEmpty)
        data.pairs = data.pairs.map { p in  // a clip that wasn't rendered has no file
            var p = p
            if p.reason == nil && clips[p.i] == nil { p.file = nil; p.reason = "not rendered" }
            return p
        }
        try JSONFile.write(data, to: (dir as NSString).appendingPathComponent("set.json"))
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        let compact = Review.scriptSafe(String(decoding: try e.encode(data), as: UTF8.self))
        let page = Templates.setlist.replacingOccurrences(of: "__DATA__", with: compact)
            .replacingOccurrences(of: "__TITLE__", with: htmlEscape(plan.playlist))
        let out = (dir as NSString).appendingPathComponent("index.html")
        try Data(page.utf8).write(to: URL(fileURLWithPath: out))
        return out
    }

    /// Text safe inside HTML (the playlist name in the page title).
    public static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Renders everything and writes the bundle (the CLI's `set --preview-dir`).
    public static func build(
        _ plan: PreviewPlan, renderer: SetRenderer, to dir: String, mix: Bool, format: ExportFormat,
        onEvent: @Sendable (RenderEvent) -> Void = { _ in }
    ) async throws -> String {
        var clips: [Int: String] = [:]
        var chunks: [String] = []
        for try await ev in renderer.render(plan, pairs: true, mix: mix) {
            onEvent(ev)
            switch ev {
            case .pairReady(let i, let file, _): clips[i] = file
            case .mixChunk(let c): chunks.append(c.file)
            default: break
            }
        }
        return try write(plan, clips: clips, mixChunks: chunks, to: dir, format: format)
    }
}
