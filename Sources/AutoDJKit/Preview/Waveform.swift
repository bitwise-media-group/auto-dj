// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Accelerate
import Foundation

/// A rendered track's waveform the way Rekordbox's 3-band display draws it: per bin
/// (1 / `rate` seconds) the RMS of the lows (below ~200 Hz), mids and highs (above ~2.5 kHz).
/// Computed from the mix segment, so it already shows the fades, filters and bass swaps.
public struct Waveform: Sendable, Equatable {
    /// Bins per second.
    public static let rate = 60.0
    /// The mix second of bin 0.
    public var start: Double
    public var low: [Float]
    public var mid: [Float]
    public var high: [Float]

    public init(start: Double, low: [Float], mid: [Float], high: [Float]) {
        self.start = start
        self.low = low
        self.mid = mid
        self.high = high
    }

    public var count: Int { low.count }

    /// The mix second where the waveform ends.
    public var end: Double { start + Double(count) / Self.rate }

    /// Each band's mean over the bins within mix seconds [t0, t1) (zeros outside the waveform).
    public func mean(_ t0: Double, _ t1: Double) -> (low: Float, mid: Float, high: Float) {
        guard t1 > start, t0 < end else { return (0, 0, 0) }
        let a = max(Int(((t0 - start) * Self.rate).rounded(.down)), 0)
        let b = min(max(Int(((t1 - start) * Self.rate).rounded(.up)), a + 1), count)
        guard a < b else { return (0, 0, 0) }
        let n = Float(b - a)
        return (low[a..<b].reduce(0, +) / n, mid[a..<b].reduce(0, +) / n, high[a..<b].reduce(0, +) / n)
    }

    /// Each band's level at quantile q (0...1) of its bins: what counts as loud for this track.
    public func level(_ q: Double) -> (low: Float, mid: Float, high: Float) {
        func at(_ x: [Float]) -> Float {
            let s = x.sorted()
            return s.isEmpty ? 0 : s[min(Int(Double(s.count - 1) * q), s.count - 1)]
        }
        return (at(low), at(mid), at(high))
    }

    /// The waveform of y, which starts at mix second start.
    public static func of(_ y: Stereo, start: Double) -> Waveform {
        let n = y.count
        guard n > 0 else { return Waveform(start: start, low: [], mid: [], high: []) }
        var mono = [Float](repeating: 0, count: n)
        vDSP.add(y.l, y.r, result: &mono)
        vDSP.multiply(0.5, mono, result: &mono)
        let lo = filter(mono, [biquad(lowPass: true, 200), biquad(lowPass: true, 200)])
        let md = filter(mono, [biquad(lowPass: false, 200), biquad(lowPass: true, 2500)])
        let hi = filter(mono, [biquad(lowPass: false, 2500), biquad(lowPass: false, 2500)])
        let hop = Int(Mix.sampleRate / rate)
        let bins = (n + hop - 1) / hop
        func rms(_ x: [Float]) -> [Float] {
            x.withUnsafeBufferPointer { p in
                (0..<bins).map { b in
                    vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: p[b * hop..<min(b * hop + hop, n)]))
                }
            }
        }
        return Waveform(start: start, low: rms(lo), mid: rms(md), high: rms(hi))
    }

    /// A Butterworth (Q = 1/sqrt 2) low- or high-pass section at f Hz: b0 b1 b2 a1 a2.
    static func biquad(lowPass: Bool, _ f: Double) -> [Double] {
        let w = 2 * Double.pi * f / Mix.sampleRate
        let alpha = sin(w) / 2.0.squareRoot()  // sin w / 2Q
        let c = cos(w)
        let a0 = 1 + alpha
        let k: Double = lowPass ? 1 - c : 1 + c
        let s: Double = lowPass ? 1 : -1
        let b: [Double] = [k / 2, s * k, k / 2]
        let a: [Double] = [-2 * c, 1 - alpha]
        return (b + a).map { $0 / a0 }
    }

    static func filter(_ x: [Float], _ sections: [[Double]]) -> [Float] {
        guard
            var bq = vDSP.Biquad(
                coefficients: sections.flatMap { $0 }, channelCount: 1, sectionCount: vDSP_Length(sections.count),
                ofType: Float.self)
        else { return x }
        return bq.apply(input: x)
    }
}
