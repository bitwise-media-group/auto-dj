// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Accelerate
import Foundation

/// Downsamples by a whole factor with a Kaiser-windowed sinc low-pass, as ffmpeg's resampler
/// does (32 taps per phase, cutoff 0.97 of the output Nyquist, β 9). The features are taken at
/// 11025 Hz from (mostly) 44.1 kHz files; this keeps their top band (2.5-5.5 kHz, close to
/// the output Nyquist) where the Go build put it: AVAudioConverter's filter rolls it off ~12%
/// more. Streaming: push chunks, get the output samples they complete.
struct Decimator {
    let factor: Int
    let taps: [Float]
    /// Input samples not yet fully used (the filter's history).
    private var buf: [Float]
    /// Index in buf of the next output sample's first tap.
    private var pos = 0

    init(factor: Int, tapsPerPhase: Int = 32, cutoff: Double = 0.97, beta: Double = 9) {
        self.factor = factor
        let n = tapsPerPhase * factor
        let fc = cutoff / Double(factor) / 2  // cycles per input sample
        func i0(_ x: Double) -> Double {
            var s = 1.0
            var t = 1.0
            for k in 1..<50 {
                t *= (x / 2 / Double(k)) * (x / 2 / Double(k))
                s += t
            }
            return s
        }
        taps = (0..<n).map { k in
            let m = Double(k) - Double(n - 1) / 2
            let sinc = m == 0 ? 2 * fc : sin(2 * .pi * fc * m) / (.pi * m)
            let w = i0(beta * max(0, 1 - pow(2 * Double(k) / Double(n - 1) - 1, 2)).squareRoot()) / i0(beta)
            return Float(sinc * w)
        }
        buf = [Float](repeating: 0, count: n / 2)  // centre the filter on input sample 0
    }

    /// The output samples the input so far completes.
    mutating func push(_ x: [Float]) -> [Float] {
        buf += x
        let n = taps.count
        let count = buf.count - pos >= n ? (buf.count - pos - n) / factor + 1 : 0
        if count == 0 { return [] }
        var y = [Float](repeating: 0, count: count)
        buf.withUnsafeBufferPointer { b in
            vDSP_desamp(b.baseAddress! + pos, vDSP_Stride(factor), taps, &y, vDSP_Length(count), vDSP_Length(n))
        }
        pos += count * factor
        buf.removeFirst(pos)
        pos = 0
        return y
    }

    /// The remaining output samples (the input ends in silence), up to `total` in all.
    mutating func finish(_ produced: Int, total: Int) -> [Float] {
        let need = total - produced
        if need <= 0 { return [] }
        return Array(push([Float](repeating: 0, count: taps.count + need * factor)).prefix(need))
    }
}
