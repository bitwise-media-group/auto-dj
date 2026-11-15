// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

@preconcurrency import AVFoundation
import Foundation

/// Decodes audio files with AVFoundation (AIFF, WAV, MP3, AAC, ALAC, FLAC), replacing the Go
/// version's ffmpeg pipes. Output is float32, non-interleaved, at the requested rate.
public enum AudioDecoder {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The file's duration in seconds and native sample rate.
    public static func info(_ path: String) throws -> (duration: Double, sampleRate: Double) {
        let f = try open(path)
        return (Double(f.length) / f.processingFormat.sampleRate, f.processingFormat.sampleRate)
    }

    static func open(_ path: String) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: URL(fileURLWithPath: path))
        } catch {
            throw Failure(description: "can't decode \(path): \(error.localizedDescription)")
        }
    }

    /// Streams the file as `channels` channels at sampleRate, starting at `from` seconds and
    /// stopping after `duration` seconds (nil: to the end). Mono output is a stereo source's
    /// (L + R) / √2, as ffmpeg's -ac 1 downmixes (the feature cache's scale depends on it), and
    /// the mean of any other layout's channels; stereo output from a mono source duplicates it.
    /// `chunk` receives one array per channel; `progress` the fraction of the range decoded.
    public static func stream(
        _ path: String, sampleRate: Double, channels: Int, from: Double = 0, duration: Double? = nil,
        progress: ((Double) -> Void)? = nil, chunk: ([[Float]]) throws -> Void
    ) throws {
        let file = try open(path)
        let src = file.processingFormat
        let srcCh = Int(src.channelCount)
        let startFrame = AVAudioFramePosition(max(0, from) * src.sampleRate)
        if startFrame >= file.length { return }
        // seeking raises (an Objective-C exception, uncatchable here) on a file whose codec isn't
        // available, so only seek when needed
        if startFrame > 0 { file.framePosition = startFrame }
        var remaining = file.length - startFrame
        if let duration {
            remaining = min(remaining, AVAudioFramePosition((duration * src.sampleRate).rounded(.up)))
        }
        let total = Double(remaining)
        // resample at the source channel count, mix afterwards
        guard
            let mid = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(srcCh),
                interleaved: false)
        else { throw Failure(description: "bad format") }
        let same = src.sampleRate == sampleRate && src.commonFormat == .pcmFormatFloat32 && !src.isInterleaved
        // mono at a whole fraction of the source rate (44.1 kHz -> 11025 Hz for the features):
        // read at the source rate and decimate like ffmpeg (see Decimator)
        let factor = src.sampleRate / sampleRate
        var decimator =
            channels == 1 && factor >= 2 && factor == factor.rounded() && src.commonFormat == .pcmFormatFloat32
                && !src.isInterleaved ? Decimator(factor: Int(factor)) : nil
        var produced = 0
        let converter = same || decimator != nil ? nil : AVAudioConverter(from: src, to: mid)
        if !same, decimator == nil, converter == nil { throw Failure(description: "no converter for \(path)") }
        converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        // features (mono) from a source at an odd rate (48 kHz): the slow, flat-top resampler, so
        // the top band matches the decimated 44.1 kHz files; previews (stereo): the fast one
        converter?.sampleRateConverterAlgorithm =
            channels == 1 ? AVSampleRateConverterAlgorithm_Mastering : AVSampleRateConverterAlgorithm_Normal

        let inCap: AVAudioFrameCount = 1 << 16
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: inCap) else {
            throw Failure(description: "no buffer")
        }
        let outCap = AVAudioFrameCount(Double(inCap) * sampleRate / src.sampleRate) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: mid, frameCapacity: outCap) else {
            throw Failure(description: "no buffer")
        }
        var readErr: Error?
        var eof = false

        func emit(_ b: AVAudioPCMBuffer) throws {
            let n = Int(b.frameLength)
            if n == 0 { return }
            let data = b.floatChannelData!
            var out: [[Float]]
            if channels == 1 {
                var m = [Float](UnsafeBufferPointer(start: data[0], count: n))
                if srcCh > 1 {
                    for c in 1..<srcCh {
                        let p = data[c]
                        for i in 0..<n { m[i] += p[i] }
                    }
                    let s = srcCh == 2 ? Float(0.5.squareRoot()) : 1 / Float(srcCh)
                    for i in 0..<n { m[i] *= s }
                }
                if decimator != nil {
                    m = decimator!.push(m)
                    produced += m.count
                    if m.isEmpty { return }
                }
                out = [m]
            } else {
                out = (0..<channels).map { c in
                    [Float](UnsafeBufferPointer(start: data[min(c, srcCh - 1)], count: n))
                }
            }
            try chunk(out)
        }

        func readInput() -> AVAudioPCMBuffer? {
            if remaining <= 0 { return nil }
            inBuf.frameLength = 0
            do {
                try file.read(into: inBuf, frameCount: AVAudioFrameCount(min(Int64(inCap), remaining)))
            } catch {
                readErr = error
                return nil
            }
            if inBuf.frameLength == 0 { return nil }
            remaining -= AVAudioFramePosition(inBuf.frameLength)
            progress?(1 - Double(remaining) / max(total, 1))
            return inBuf
        }

        if converter == nil {
            while let b = readInput() { try emit(b) }
            if let readErr { throw readErr }
            if decimator != nil {
                let tail = decimator!.finish(produced, total: Int((total / factor).rounded()))
                if !tail.isEmpty { try chunk([tail]) }
            }
            return
        }
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let st = converter!.convert(to: outBuf, error: &err) { _, status in
                if eof {
                    status.pointee = .endOfStream
                    return nil
                }
                if let b = readInput() {
                    status.pointee = .haveData
                    return b
                }
                eof = true
                status.pointee = .endOfStream
                return nil
            }
            if let readErr { throw readErr }
            if st == .error { throw Failure(description: "decoding \(path): \(err?.localizedDescription ?? "")") }
            try emit(outBuf)
            if st == .endOfStream { break }
        }
    }

    /// The whole range as one array per channel.
    public static func decode(
        _ path: String, sampleRate: Double, channels: Int, from: Double = 0, duration: Double? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> [[Float]] {
        var out = [[Float]](repeating: [], count: channels)
        try stream(
            path, sampleRate: sampleRate, channels: channels, from: from, duration: duration,
            progress: progress
        ) { c in
            for i in 0..<channels { out[i].append(contentsOf: c[i]) }
        }
        return out
    }
}
