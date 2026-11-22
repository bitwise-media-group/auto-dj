// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Accelerate
import CryptoKit
import Foundation

/// One frame's (or beat's) features.
public typealias Frame = [Float]

/// Per-frame band energies from the track audio (port of internal/features, decoded with
/// AVFoundation and transformed with vDSP).
///
/// Columns: 0 sub/kick+bass 30-120 Hz | 1 low-mid 120-500 | 2 mid 500-2500 | 3 high 2500-5500
/// | 4 low-band spectral flux | 5 high-band spectral flux. Decoded at 11025 Hz mono, FFT 1024,
/// hop 256 (~43 frames/s), in float32. One cache file per track.
public enum Features {
    public static let sr = 11025.0
    public static let nfft = 1024
    public static let hop = 256
    public static let fps = sr / Double(hop)
    public static let cols = 6
    /// The band-power ranges (Hz) of columns 0..3.
    public static let bands: [(Double, Double)] = [(30, 120), (120, 500), (500, 2500), (2500, 5500)]

    /// A track's frames, flattened row by row (frame f column j is `data[f * cols + j]`).
    public struct Frames: Sendable, Equatable {
        public var data: [Float]
        public var count: Int { data.count / Features.cols }

        public init(data: [Float]) { self.data = data }

        public subscript(f: Int, j: Int) -> Float { data[f * Features.cols + j] }

        public func row(_ f: Int) -> ArraySlice<Float> {
            data[f * Features.cols..<(f + 1) * Features.cols]
        }
    }

    // ---------------------------------------------------------------- cache

    /// Names a track's cache file by its NFC file name, so a cache survives the library moving
    /// between machines.
    static func key(_ path: String) -> String {
        let name = ((path as NSString).lastPathComponent).precomposedStringWithCanonicalMapping
        return Insecure.MD5.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Where audioPath's features are cached.
    public static func cachePath(featureDir: String, audioPath: String) -> String {
        (featureDir as NSString).appendingPathComponent(key(audioPath) + ext)
    }

    /// The cache file: LZFSE over the magic "ADJ2", version, frame count, column count (uint32
    /// little-endian each), then the frames as float32 little-endian, row by row.
    static let ext = ".f32.lzfse"
    static let magic: UInt32 = 0x324A_4441  // "ADJ2"
    static let version: UInt32 = 1

    public struct CacheError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Writes frames to path (atomically).
    public static func save(_ path: String, _ F: Frames) throws {
        var raw = Data(capacity: 16 + F.data.count * 4)
        for v in [magic, version, UInt32(F.count), UInt32(cols)] {
            withUnsafeBytes(of: v.littleEndian) { raw.append(contentsOf: $0) }
        }
        F.data.withUnsafeBytes { raw.append(contentsOf: $0) }
        let z = try (raw as NSData).compressed(using: .lzfse) as Data
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try writeAtomically(z, to: path)
    }

    /// Reads a cache file written by `save`; nil when there is none.
    public static func load(_ path: String) throws -> Frames? {
        guard let z = FileManager.default.contents(atPath: path) else { return nil }
        let raw: Data
        do {
            raw = try (z as NSData).decompressed(using: .lzfse) as Data
        } catch {
            throw CacheError(description: "\(path): \(error.localizedDescription)")
        }
        func u32(_ i: Int) -> UInt32 {
            raw.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: i, as: UInt32.self)) }
        }
        guard raw.count >= 16, u32(0) == magic, u32(4) == version, u32(12) == UInt32(cols) else {
            throw CacheError(description: "\(path): not a version \(version) feature cache")
        }
        let n = Int(u32(8))
        guard raw.count == 16 + n * cols * 4 else {
            throw CacheError(description: "\(path): truncated feature cache")
        }
        var data = [Float](repeating: 0, count: n * cols)
        _ = data.withUnsafeMutableBytes { raw.copyBytes(to: $0, from: 16..<raw.count) }
        return Frames(data: data)
    }

    // ---------------------------------------------------------------- computation

    /// Computes frames from mono audio pushed in chunks, so a recording of several hours never
    /// has to be held decoded.
    public final class Extractor {
        let window: [Float]
        let masks: [Range<Int>]
        let dft: vDSP.DiscreteFourierTransform<Float>
        var buf: [Float] = []
        var prev: [Float] = []
        var out: [Float] = []
        var frames = 0

        public init() {
            window = Num.hann(nfft).map { Float($0) }
            masks = Features.bandMasks()
            dft = try! vDSP.DiscreteFourierTransform(
                previous: nil, count: nfft, direction: .forward, transformType: .complexReal,
                ofType: Float.self)
        }

        public func push(_ y: [Float]) {
            buf.append(contentsOf: y)
            var pos = 0
            while pos + nfft <= buf.count {
                frame(buf[pos..<pos + nfft])
                pos += hop
            }
            buf.removeFirst(pos)
        }

        /// The frames so far (numpy's 1 + (len - nfft) // hop of them).
        public func finish() -> Frames { Frames(data: out) }

        var x = [Float](repeating: 0, count: nfft)
        var re = [Float](repeating: 0, count: nfft / 2)
        var im = [Float](repeating: 0, count: nfft / 2)
        var oRe = [Float](repeating: 0, count: nfft / 2)
        var oIm = [Float](repeating: 0, count: nfft / 2)
        var S = [Float](repeating: 0, count: nfft / 2 + 1)
        var L = [Float](repeating: 0, count: nfft / 2 + 1)

        func frame(_ fr: ArraySlice<Float>) {
            vDSP.multiply(fr, window, result: &x)
            // even / odd split for the packed real transform
            for k in 0..<nfft / 2 {
                re[k] = x[2 * k]
                im[k] = x[2 * k + 1]
            }
            dft.transform(inputReal: re, inputImaginary: im, outputReal: &oRe, outputImaginary: &oIm)
            // vDSP's real DFT is scaled by 2 and packs Nyquist into imag[0]
            S[0] = abs(oRe[0]) / 2
            S[nfft / 2] = abs(oIm[0]) / 2
            for k in 1..<nfft / 2 {
                S[k] = (oRe[k] * oRe[k] + oIm[k] * oIm[k]).squareRoot() / 2
            }
            for k in 0...nfft / 2 { L[k] = log1pf(100 * S[k]) }
            if prev.isEmpty { prev = L }
            for m in masks {
                var e: Float = 0
                for k in m { e += S[k] * S[k] }
                out.append(e)
            }
            for m in [masks[0], masks[3]] {
                var f: Float = 0
                for k in m { f += max(L[k] - prev[k], 0) }
                out.append(f)
            }
            swap(&prev, &L)
            frames += 1
        }
    }

    /// Per band, the rfft bins with a <= f < b (np.fft.rfftfreq(nfft, 1/sr)).
    static func bandMasks() -> [Range<Int>] {
        let val = 1.0 / (Double(nfft) * (1.0 / sr))
        var idx = [[Int]](repeating: [], count: 4)
        for k in 0...nfft / 2 {
            let f = Double(k) * val
            for (j, b) in bands.enumerated() where f >= b.0 && f < b.1 { idx[j].append(k) }
        }
        return idx.map { $0.first!..<($0.last! + 1) }  // each band is a contiguous run of bins
    }

    /// The per-frame features of mono audio y.
    public static func frameFeatures(_ y: [Float]) throws -> Frames {
        if y.count < nfft { throw CacheError(description: "audio too short (\(y.count) samples)") }
        let e = Extractor()
        e.push(y)
        return e.finish()
    }

    /// Decodes path and computes its frames, streaming.
    public static func decodeFrames(_ path: String, progress: ((Double) -> Void)? = nil) throws
        -> Frames
    {
        let e = Extractor()
        var n = 0
        try AudioDecoder.stream(path, sampleRate: sr, channels: 1, progress: progress) {
            n += $0[0].count
            e.push($0[0])
        }
        if n < nfft { throw CacheError(description: "audio too short (\(n) samples)") }
        return e.finish()
    }

    // ---------------------------------------------------------------- extraction

    /// One file's extraction outcome.
    public enum Status: Sendable, Equatable {
        case cached, ok
        case error(String)

        public var label: String {
            switch self {
            case .cached: "cached"
            case .ok: "ok"
            case .error: "error"
            }
        }
    }

    /// Caches audioPath's features and vocal analysis (`Vocals`) unless they already are.
    public static func extractOne(
        _ audioPath: String, featureDir: String, progress: ((Double) -> Void)? = nil
    ) -> Status {
        let out = cachePath(featureDir: featureDir, audioPath: audioPath)
        let vox = Vocals.cachePath(featureDir: featureDir, audioPath: audioPath)
        let fm = FileManager.default
        let (haveF, haveV) = (fm.fileExists(atPath: out), fm.fileExists(atPath: vox))
        if haveF && haveV { return .cached }
        do {
            if !haveF {
                try save(out, try decodeFrames(audioPath, progress: haveV ? progress : { progress?($0 * 0.7) }))
            }
            if !haveV {
                try Vocals.save(vox, try Vocals.analyse(audioPath))
                progress?(1)
            }
            return .ok
        } catch {
            return .error("\(error)")
        }
    }

    /// Caches features for every path with `workers` decodes in parallel. Results are in input
    /// order; `onDone` hears about each file as it finishes, `onProgress` reports per file.
    public static func extractMany(
        _ paths: [String], featureDir: String, workers: Int,
        onProgress: (@Sendable (Int, Double) -> Void)? = nil,
        onDone: (@Sendable (Int, Status) -> Void)? = nil
    ) async throws -> [Status] {
        try FileManager.default.createDirectory(atPath: featureDir, withIntermediateDirectories: true)
        var res = [Status](repeating: .cached, count: paths.count)
        try await withThrowingTaskGroup(of: (Int, Status).self) { g in
            var next = 0
            func add() {
                let i = next
                next += 1
                g.addTask {
                    try Task.checkCancellation()
                    let st = extractOne(paths[i], featureDir: featureDir) { onProgress?(i, $0) }
                    onDone?(i, st)
                    return (i, st)
                }
            }
            for _ in 0..<min(max(workers, 1), paths.count) { add() }
            while let (i, st) = try await g.next() {
                res[i] = st
                if next < paths.count { add() }
            }
        }
        return res
    }

    /// Averages the cached frame features over each beat of the Rekordbox grid -> (n_beats, 6);
    /// nil when audioPath has no cache file.
    public static func perBeat(featureDir: String, audioPath: String, beats: [Double], bpm: Double)
        throws -> [[Double]]?
    {
        guard let F = try load(cachePath(featureDir: featureDir, audioPath: audioPath)) else {
            return nil
        }
        return perBeat(F, beats: beats, bpm: bpm)
    }

    static func perBeat(_ F: Frames, beats: [Double], bpm: Double) -> [[Double]] {
        let nb = beats.count
        if nb == 0 { return [] }
        let edges = beats + [beats[nb - 1] + 60 / max(bpm, 1)]
        var fb = [[Double]](repeating: [Double](repeating: 0, count: cols), count: nb)
        let nF = F.count
        for i in 0..<nb {
            let a = Int(edges[i] * fps)
            var b = max(a + 1, Int(edges[i + 1] * fps))
            if a >= nF || a < 0 { continue }
            b = min(b, nF)
            // numpy's mean over axis 0: a running float32 sum per column, then / count
            var s = [Float](repeating: 0, count: cols)
            for f in a..<b {
                for j in 0..<cols { s[j] += F[f, j] }
            }
            for j in 0..<cols { fb[i][j] = Double(s[j] / Float(b - a)) }
        }
        return fb
    }

    /// audioPath's frames from the cache, decoding (and caching) them when they aren't there.
    public static func frames(featureDir: String, audioPath: String) throws -> Frames {
        let p = cachePath(featureDir: featureDir, audioPath: audioPath)
        if let F = try? load(p) { return F }
        if case .error(let e) = extractOne(audioPath, featureDir: featureDir) {
            throw CacheError(description: e)
        }
        guard let F = try load(p) else { throw CacheError(description: "\(p): missing") }
        return F
    }

    /// A long recording's frames, cached by its path, size and modification time (recordings
    /// are often all called REC001.WAV).
    public static func recordingFrames(
        featureDir: String, path: String, progress: ((Double) -> Void)? = nil
    ) throws -> Frames {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let abs = URL(fileURLWithPath: path).standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
        let id = Insecure.MD5.hash(data: Data("\(abs)|\(size)|\(Int64(mtime * 1e9))".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let cache = ((featureDir as NSString).appendingPathComponent("recordings") as NSString)
            .appendingPathComponent(id + ext)
        if let F = try? load(cache) { return F }
        let F = try decodeFrames(path, progress: progress)
        try save(cache, F)
        return F
    }
}
