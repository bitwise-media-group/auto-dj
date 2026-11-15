// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

@preconcurrency import AVFoundation
import CryptoKit
import Foundation

/// Decoded tracks at `Mix.sampleRate` stereo, shared by every segment of a render: each
/// file is decoded once and kept while there is room (least recently used goes first).
public actor SourceCache {
    struct Entry {
        var audio: Stereo
        var used: UInt64
    }

    let maxFrames: Int
    var entries: [String: Entry] = [:]
    var loading: [String: Task<Stereo, Error>] = [:]
    var clock: UInt64 = 0

    /// maxBytes bounds the decoded audio held (8 bytes per stereo frame).
    public init(maxBytes: Int = 1 << 31) { maxFrames = maxBytes / 8 }

    /// path decoded, from the cache or now.
    public func audio(_ path: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Stereo {
        clock += 1
        if var e = entries[path] {
            e.used = clock
            entries[path] = e
            return e.audio
        }
        if let t = loading[path] { return try await t.value }
        let t = Task.detached {
            let c = try AudioDecoder.decode(path, sampleRate: Mix.sampleRate, channels: 2, progress: progress)
            return Stereo(l: c[0], r: c[1])
        }
        loading[path] = t
        defer { loading[path] = nil }
        let a = try await t.value
        entries[path] = Entry(audio: a, used: clock)
        var total = entries.values.reduce(0) { $0 + $1.audio.count }
        while total > maxFrames, entries.count > 1,
            let old = entries.filter({ $0.key != path }).min(by: { $0.value.used < $1.value.used })
        {
            total -= old.value.audio.count
            entries[old.key] = nil
        }
        return a
    }
}

/// Renders one timeline segment to audio (port of internal/preview/render.go).
public enum SegmentRenderer {
    static let sr = Mix.sampleRate

    /// dur output seconds of a track from source second start at tempo (source s per output
    /// s, key kept), padded with silence before 0 and after the end of the file.
    static func decode(_ src: Stereo, start: Double, dur: Double, tempo: Double) -> Stereo {
        let n = Num.round(dur * sr)
        let s0 = Int((start * sr).rounded(.down))
        let need = Int((dur * tempo + 0.2) * sr) + TimeStretch.window * 2
        var part = Stereo(count: need)
        let a = max(s0, 0)
        let b = min(s0 + need, src.count)
        if b > a {
            part.l.replaceSubrange((a - s0)..<(b - s0), with: src.l[a..<b])
            part.r.replaceSubrange((a - s0)..<(b - s0), with: src.r[a..<b])
        }
        return TimeStretch.stretch(part, rate: tempo, frames: n)
    }

    /// dur output seconds of a track from playback second p0 at tempo, through its jumps (a
    /// `Mix.jumpXFS` crossfade into each).
    static func decodeRoute(_ src: Stereo, _ route: Route, p0: Double, dur: Double, tempo: Double) -> Stereo {
        let n = Num.round(dur * sr)
        var y = Stereo(count: n)
        let xf = Int(Mix.jumpXFS * sr)
        let pieces = route.span(p0, p0 + dur * tempo)
        for (k, p) in pieces.enumerated() {
            let i0 = Num.round((p.q - p0) / tempo * sr)
            let last = k == pieces.count - 1
            var m = n - i0
            if !last { m = min(m, Num.round((p.s1 - p.s0) / tempo * sr) + xf) }
            if m <= 0 { continue }
            var z = decode(src, start: p.s0, dur: Double(m) / sr, tempo: tempo)
            z.resize(min(m, z.count))
            let r = Num.linspace32(0, 1, min(xf, m))
            for (i, w) in r.enumerated() {
                if k > 0 {
                    z.l[i] *= w
                    z.r[i] *= w
                }
                if !last {
                    let j = z.count - r.count + i
                    z.l[j] *= r[r.count - 1 - i]
                    z.r[j] *= r[r.count - 1 - i]
                }
            }
            if i0 >= 0 {
                z.resize(min(z.count, max(n - i0, 0)))
                y.add(z, at: i0)
            }
        }
        return y
    }

    /// The track's audio for [start, end): stretched until the clock's split, at its own (or
    /// the set's fixed) tempo after, with a short crossfade where the tempo changes.
    static func decodeSeg(_ s: Seg, _ src: Stereo) -> Stereo {
        let c = s.clock
        let route = s.route
        let n = Num.round((s.end - s.start) * sr)
        let pre = min(max(c.split - c.out0, 0), s.end - s.start)  // stretched part (mix seconds)
        let preN = Num.round(pre * sr)
        var y = Stereo(count: 0)
        if pre > 0 {
            let head = decodeRoute(src, route, p0: c.src0, dur: pre + Mix.splitXFS, tempo: c.rate)
            y = head
            if n - preN > 0 {
                y = head[0..<min(preN, head.count)]
                var tail = head[y.count..<head.count]
                var rest = decodeRoute(src, route, p0: c.srcSplit, dur: s.end - s.start - pre, tempo: c.own)
                tail.resize(min(Int(Mix.splitXFS * sr), rest.count, tail.count))
                let r = Num.linspace32(0, 1, tail.count)
                for i in 0..<tail.count {
                    rest.l[i] = tail.l[i] * (1 - r[i]) + rest.l[i] * r[i]
                    rest.r[i] = tail.r[i] * (1 - r[i]) + rest.r[i] * r[i]
                }
                y.l += rest.l
                y.r += rest.r
            }
        } else if n - preN > 0 {
            y = decodeRoute(src, route, p0: c.srcSplit, dur: s.end - s.start - pre, tempo: c.own)
        }
        y.resize(n)
        return y
    }

    /// The track's audio over mix time [start, end), with its jumps, fades, bass swaps and exit.
    public static func render(_ s: Seg, _ src: Stereo, progress: (Double) -> Void = { _ in }) -> Stereo {
        var y = decodeSeg(s, src)
        progress(0.6)
        let n = y.count
        func t(_ i: Int) -> Double { s.start + Double(i) / sr }
        func idx(_ x: Double) -> Int { Int(Num.clip(((x - s.start) * sr).rounded(.toNearestOrEven), 0, Double(n))) }
        if let bi = s.bassIn {  // no bass until the swap
            DSP.swapBass(&y, range: 0..<idx(bi + 0.2), t: t, at: bi, in: true)
        }
        if let bo = s.bassOut {  // bass gone after the swap
            DSP.swapBass(&y, range: idx(bo - 0.2)..<n, t: t, at: bo, in: false)
        }
        progress(0.8)
        if let fi = s.fadeIn {
            y.scale { i in Num.clip((t(i) - fi.0) / max(fi.1 - fi.0, 1e-3), 0, 1) }
        }
        let xs = s.exit.xs
        switch s.exit.kind {
        case .filter:  // sweep to silence, then fade out
            let k = idx(xs[0])
            let swept = DSP.lowpassSweep(y[k..<n], sweep: idx(xs[1]) - k)
            y.l.replaceSubrange(k..<n, with: swept.l)
            y.r.replaceSubrange(k..<n, with: swept.r)
            y.scale { i in 1 - Num.clip((t(i) - xs[1]) / max(xs[2] - xs[1], 1e-3), 0, 1) }
        case .fade:
            y.scale { i in 1 - Num.clip((t(i) - xs[0]) / max(xs[1] - xs[0], 1e-3), 0, 1) }
        default: break
        }
        if s.exit.kind == .filter || s.exit.kind == .cut {  // the cut itself, without a click
            y.scale { i in Num.clip((s.end - t(i)) / Mix.cutRampS, 0, 1) }
        }
        progress(1)
        return y
    }

    /// Identifies a segment's audio: the file and every parameter, relative to the segment's
    /// start, so a segment that only moved in the mix is found in the render cache.
    public static func key(_ s: Seg) -> String {
        guard let t = s.rec else { return "" }
        let attrs = try? FileManager.default.attributesOfItem(atPath: t.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        func r(_ x: Double?) -> String {
            guard let x else { return "-" }
            return x.isFinite ? String(format: "%.6f", x - s.start) : "inf"
        }
        func v(_ x: Double) -> String { x.isFinite ? String(format: "%.6f", x) : "inf" }
        let parts: [String] = [
            "v1", t.path, String(size), v(mtime),
            s.route.pieces.map { "\(v($0.s0)):\(v($0.s1))" }.joined(separator: ","),
            r(s.clock.out0), v(s.clock.src0), v(s.clock.rate), r(s.clock.split), v(s.clock.own),
            r(s.end), s.exit.kind.rawValue, s.exit.xs.map { r($0) }.joined(separator: ","),
            r(s.fadeIn?.0), r(s.fadeIn?.1), r(s.bassIn), r(s.bassOut),
        ]
        return SHA256.hash(data: Data(parts.joined(separator: "|").utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// PCM files in the render cache (CAF, float32 stereo).
public enum PCMFile {
    static let format = AVAudioFormat(standardFormatWithSampleRate: Mix.sampleRate, channels: 2)!

    public static func write(_ y: Stereo, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let tmp = path + ".tmp.caf"
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Mix.sampleRate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            ]
            let f = try AVAudioFile(
                forWriting: URL(fileURLWithPath: tmp), settings: settings, commonFormat: .pcmFormatFloat32,
                interleaved: false)
            let chunk = 1 << 16
            var i = 0
            while i < y.count {
                let k = min(chunk, y.count - i)
                let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(k))!
                b.frameLength = AVAudioFrameCount(k)
                y.l.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress! + i, count: k) }
                y.r.withUnsafeBufferPointer { b.floatChannelData![1].update(from: $0.baseAddress! + i, count: k) }
                try f.write(from: b)
                i += k
            }
        }
        if rename(tmp, path) != 0 { throw AutoDJError("can't write \(path)") }
    }

    public static func read(_ path: String) throws -> Stereo {
        let c = try AudioDecoder.decode(path, sampleRate: Mix.sampleRate, channels: 2)
        return Stereo(l: c[0], r: c[1])
    }
}

/// What the renderer reports while it works.
public enum RenderEvent: Sendable {
    /// Mix segment n (1-based track number) progress, 0...1.
    case track(n: Int, progress: Double)
    /// Transition i (track i+1 into i+2) progress, 0...1.
    case pair(i: Int, progress: Double)
    /// Transition i's clip is ready to play.
    case pairReady(i: Int, file: String, frames: Int)
    /// Final mix audio for frames [start, start + frames).
    case mixChunk(MixChunk)
    /// The whole mix is rendered.
    case mixDone(frames: Int)
    /// Mix segment n couldn't be rendered (its file can't be read): silence in the mix.
    case trackFailed(n: Int, error: String)
    /// Transition i's clip couldn't be rendered.
    case pairFailed(i: Int, error: String)
}

/// A finished stretch of the full-set mix.
public struct MixChunk: Sendable, Equatable {
    public var index: Int
    public var start: Int
    public var frames: Int
    public var file: String
}

/// Renders a set's previews in parallel: every mix segment and transition clip, each segment
/// cached by its parameters (so a reorder re-renders only what changed), the mix streamed out
/// in final chunks as soon as all earlier tracks are done.
public final class SetRenderer: Sendable {
    public let cacheDir: String
    public let sources: SourceCache
    public let workers: Int

    public init(
        cacheDir: String, sources: SourceCache = SourceCache(),
        workers: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.cacheDir = cacheDir
        self.sources = sources
        self.workers = max(workers, 1)
    }

    func segPath(_ key: String) -> String {
        ((cacheDir as NSString).appendingPathComponent("segments") as NSString).appendingPathComponent(key + ".caf")
    }

    /// The segment's audio, from the render cache or rendered now (and cached).
    public func segment(_ s: Seg, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Stereo {
        let key = SegmentRenderer.key(s)
        let p = segPath(key)
        if FileManager.default.fileExists(atPath: p), let y = try? PCMFile.read(p),
            y.count == Num.round((s.end - s.start) * Mix.sampleRate)
        {
            progress(1)
            return y
        }
        let src = try await sources.audio(s.rec!.path) { progress($0 * 0.3) }
        try Task.checkCancellation()
        let y = SegmentRenderer.render(s, src) { progress(0.3 + 0.7 * $0) }
        try? PCMFile.write(y, to: p)
        return y
    }

    enum Job: Sendable {
        case mix(Int)
        case pair(Int)
    }

    enum Done: Sendable {
        case mix(Int, Stereo)
        case pair(Int)
    }

    /// Renders the plan's transition clips (pairs) and full-set mix (mix), reporting as it goes.
    /// Cancel the consuming task to stop.
    public func render(_ plan: PreviewPlan, pairs: Bool = true, mix: Bool = true) -> AsyncThrowingStream<
        RenderEvent, Error
    > {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    try await self.run(plan, pairs: pairs, mix: mix) { cont.yield($0) }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func run(_ plan: PreviewPlan, pairs: Bool, mix: Bool, emit: @escaping @Sendable (RenderEvent) -> Void) async throws
    {
        let play = plan.mix.filter { !$0.missing }
        // interleave so the start of the set is ready first: mix 1, clip 1, mix 2, clip 2, ...
        var jobs: [Job] = []
        for k in 0..<max(play.count, plan.pairs.count) {
            if mix && k < play.count { jobs.append(.mix(k)) }
            if pairs && k < plan.pairs.count && plan.pairs[k].clip != nil { jobs.append(.pair(k)) }
        }
        let mixDir = (cacheDir as NSString).appendingPathComponent("mix/" + UUID().uuidString)
        var assembler = MixAssembler(play: play, dir: mixDir)
        try await withThrowingTaskGroup(of: Done.self) { g in
            var next = 0
            func add() {
                let job = jobs[next]
                next += 1
                g.addTask {
                    switch job {
                    // one unreadable file costs its own segment and clips, not the whole render
                    case .mix(let k):
                        let s = play[k]
                        do {
                            let y = try await self.segment(s) { emit(.track(n: s.n, progress: $0)) }
                            return .mix(k, y)
                        } catch  where !(error is CancellationError) && !Task.isCancelled {
                            emit(.trackFailed(n: s.n, error: "\(error)"))
                            return .mix(k, Stereo(count: Num.round((s.end - s.start) * Mix.sampleRate)))
                        }
                    case .pair(let i):
                        let clip = plan.pairs[i].clip!
                        do {
                            let file = try await self.pairClip(clip) { emit(.pair(i: i, progress: $0)) }
                            emit(.pairReady(i: i, file: file.0, frames: file.1))
                        } catch  where !(error is CancellationError) && !Task.isCancelled {
                            emit(.pairFailed(i: i, error: "\(error)"))
                        }
                        return .pair(i)
                    }
                }
            }
            for _ in 0..<min(workers, jobs.count) { add() }
            while let done = try await g.next() {
                if case .mix(let k, let y) = done {
                    for c in try assembler.add(k, y) { emit(.mixChunk(c)) }
                }
                if next < jobs.count { add() }
            }
        }
        if mix && !play.isEmpty { emit(.mixDone(frames: assembler.written)) }
    }

    /// Renders (or finds) a transition clip; returns its file and frame count.
    func pairClip(_ clip: PairClip, progress: @escaping @Sendable (Double) -> Void) async throws -> (String, Int) {
        let ka = SegmentRenderer.key(clip.a)
        let kb = SegmentRenderer.key(clip.b)
        let key = SHA256.hash(data: Data((ka + kb + String(format: "%.6f", clip.b.start - clip.a.start)).utf8)).prefix(
            16
        )
        .map { String(format: "%02x", $0) }.joined()
        let path = ((cacheDir as NSString).appendingPathComponent("clips") as NSString).appendingPathComponent(
            key + ".caf")
        let frames = Num.round(clip.b.end * Mix.sampleRate)
        if FileManager.default.fileExists(atPath: path) {
            progress(1)
            return (path, frames)
        }
        let ya = try await segment(clip.a) { progress($0 * 0.5) }
        let yb = try await segment(clip.b) { progress(0.5 + $0 * 0.5) }
        var out = Stereo(count: 0)
        out.add(ya, at: Num.round(clip.a.start * Mix.sampleRate))
        out.add(yb, at: Num.round(clip.b.start * Mix.sampleRate))
        out.resize(frames)
        DSP.limit(&out)
        try PCMFile.write(out, to: path)
        return (path, frames)
    }
}

/// Sums finished mix segments in order and releases each final chunk: everything before the
/// next track's start once all earlier tracks are in.
struct MixAssembler {
    let play: [Seg]
    let dir: String
    var pending: [Int: Stereo] = [:]
    var nextK = 0
    var buf = Stereo(count: 0)
    var buf0 = 0
    var written = 0

    init(play: [Seg], dir: String) {
        self.play = play
        self.dir = dir
    }

    mutating func add(_ k: Int, _ y: Stereo) throws -> [MixChunk] {
        pending[k] = y
        var out: [MixChunk] = []
        while let y = pending.removeValue(forKey: nextK) {
            let s = play[nextK]
            buf.add(y, at: Num.round(s.start * Mix.sampleRate) - buf0)
            // nothing later starts before the next track, so everything up to it is final
            var done = buf.count
            if nextK + 1 < play.count {
                done = Num.round(play[nextK + 1].start * Mix.sampleRate) - buf0
                if done > buf.count { buf.resize(done) }  // a gap (missing audio): silence
            }
            done = max(min(done, buf.count), 0)
            var chunk = buf[0..<done]
            DSP.limit(&chunk)
            let file = (dir as NSString).appendingPathComponent(String(format: "chunk-%03d.caf", nextK))
            try PCMFile.write(chunk, to: file)
            out.append(MixChunk(index: nextK, start: buf0, frames: done, file: file))
            written = buf0 + done
            buf = buf[done..<buf.count]
            buf0 += done
            nextK += 1
        }
        return out
    }
}
