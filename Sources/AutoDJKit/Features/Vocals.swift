// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import SoundAnalysis

/// Where a track has vocals (ADR 0020): Apple's on-device sound classifier (SoundAnalysis,
/// `SNClassifierIdentifier.version1`) run over the audio in 1.5 s windows every `hop` seconds,
/// keeping each window's strongest vocal label (singing, rapping, speech, choir, ...). Cached
/// beside the track's features as `<key>.vox`; sets avoid transitions where both tracks' vocals
/// play at once.
public enum Vocals {
    /// Seconds between windows (1.5 s windows, half overlapping).
    public static let hop = 0.75
    static let window = 1.5

    /// The classifier's labels that count as a voice.
    static let labels: Set<String> = [
        "singing", "male_singing", "female_singing", "child_singing", "choir", "rapping", "humming", "yodeling",
        "speech", "male_speech", "female_speech", "whispering", "chant", "mantra", "shout", "yell",
    ]

    /// A bar (averaged over 4 beats) with at least this vocal confidence has vocals.
    public static let threshold = 0.3

    static let ext = ".vox"
    static let magic: UInt32 = 0x3158_4F56  // "VOX1"

    /// Where audioPath's vocal analysis is cached.
    public static func cachePath(featureDir: String, audioPath: String) -> String {
        (featureDir as NSString).appendingPathComponent(Features.key(audioPath) + ext)
    }

    /// Each window's vocal confidence (0...1), one per `hop` seconds from the start.
    public static func analyse(_ path: String) throws -> [Float] {
        let analyzer = try SNAudioFileAnalyzer(url: URL(fileURLWithPath: path))
        let req = try SNClassifySoundRequest(classifierIdentifier: .version1)
        req.windowDuration = CMTime(seconds: window, preferredTimescale: 1000)
        req.overlapFactor = 1 - hop / window
        let obs = Observer()
        try analyzer.add(req, withObserver: obs)
        analyzer.analyze()
        if let e = obs.error { throw e }
        return obs.conf
    }

    final class Observer: NSObject, SNResultsObserving {
        var conf: [Float] = []
        var error: Error?

        func request(_ r: SNRequest, didProduce result: SNResult) {
            guard let c = result as? SNClassificationResult else { return }
            let i = Int((c.timeRange.start.seconds / hop).rounded())
            guard i >= 0 else { return }
            let v = c.classifications.filter { labels.contains($0.identifier) }.map(\.confidence).max() ?? 0
            if conf.count <= i { conf += [Float](repeating: 0, count: i + 1 - conf.count) }
            conf[i] = max(conf[i], Float(v))
        }

        func request(_ r: SNRequest, didFailWithError e: Error) { error = e }
    }

    /// Writes conf to path: "VOX1", hop in ms, count (uint32 little-endian each), then the
    /// confidences as float32 little-endian.
    public static func save(_ path: String, _ conf: [Float]) throws {
        var d = Data()
        for v in [magic, UInt32((hop * 1000).rounded()), UInt32(conf.count)] {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        for v in conf { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// The cached confidences, nil when there's no cache file.
    public static func load(_ path: String) throws -> [Float]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        func u32(_ at: Int) -> UInt32 {
            d.subdata(in: at..<at + 4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
        guard d.count >= 12, u32(0) == magic else { throw Features.CacheError(description: "\(path): not a VOX1 file") }
        let n = Int(u32(8))
        guard d.count >= 12 + 4 * n else { throw Features.CacheError(description: "\(path): truncated") }
        return (0..<n).map { Float(bitPattern: u32(12 + 4 * $0)) }
    }

    /// Each beat's vocal confidence (0...1), averaged over the bar around it (2 beats either
    /// side), from the windows of conf.
    public static func perBeat(_ conf: [Float], beats: [Double], bpm: Double) -> [Double] {
        let nb = beats.count
        guard nb > 0 else { return [] }
        let spb = 60 / max(bpm, 1)
        let raw: [Double] = (0..<nb).map { i in
            let a = beats[i]
            let b = i + 1 < nb ? beats[i + 1] : a + spb
            // windows whose middle falls in the beat (at least the nearest one)
            let lo = max(Int(((a - window / 2) / hop).rounded(.up)), 0)
            let hi = min(Int(((b - window / 2) / hop).rounded(.down)), conf.count - 1)
            if lo <= hi { return Double(conf[lo...hi].reduce(0, +)) / Double(hi - lo + 1) }
            let k = min(max(Int(((a - window / 2) / hop).rounded()), 0), conf.count - 1)
            return k >= 0 ? Double(conf[k]) : 0
        }
        return (0..<nb).map { i in
            let s = max(i - 2, 0)
            let t = min(i + 2, nb - 1)
            return raw[s...t].reduce(0, +) / Double(t - s + 1)
        }
    }

    /// audioPath's per-beat vocal confidence from the cache, nil when it isn't cached.
    public static func perBeat(featureDir: String, audioPath: String, beats: [Double], bpm: Double) throws
        -> [Double]?
    {
        try load(cachePath(featureDir: featureDir, audioPath: audioPath)).map { perBeat($0, beats: beats, bpm: bpm) }
    }
}
