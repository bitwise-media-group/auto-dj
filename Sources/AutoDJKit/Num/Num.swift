// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// The numpy behaviours the cue rules depend on: linear-interpolation percentiles, pairwise
/// summation, first-wins argmin/argmax, Hann windows and Python's rounding (port of
/// internal/num). Only the semantics that define behaviour are kept (ADR 0018); small
/// numeric drift from the Go version is accepted.
public enum Num {
    /// The sum of a collection.
    public static func sum<T: BinaryFloatingPoint>(_ a: some Collection<T>) -> T {
        a.reduce(0, +)
    }

    /// numpy's mean of a 1-D array (NaN when empty).
    public static func mean<T: BinaryFloatingPoint>(_ a: some Collection<T>) -> T {
        if a.isEmpty { return T.nan }
        return sum(a) / T(a.count)
    }

    /// np.percentile(a, q) with the default linear method.
    public static func percentile(_ a: [Double], _ q: Double) -> Double {
        let n = a.count
        if n == 0 { return .nan }
        let s = a.sorted()
        let v = Double(n - 1) * (q / 100)
        if v >= Double(n - 1) { return s[n - 1] }
        if v < 0 { return s[0] }
        let lo = v.rounded(.down)
        let i = Int(lo)
        return lerp(s[i], s[i + 1], v - lo)
    }

    /// numpy's _lerp: interpolate from the nearer end so t=1 gives b exactly.
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let d = b - a
        if t >= 0.5 { return b - d * (1 - t) }
        return a + d * t
    }

    /// np.argmin: the first index of the smallest value (-1 when empty).
    public static func argmin(_ a: [Double]) -> Int {
        var best = -1
        for (i, v) in a.enumerated() where best < 0 || v < a[best] { best = i }
        return best
    }

    /// np.argmax: the first index of the largest value (-1 when empty).
    public static func argmax(_ a: [Double]) -> Int {
        var best = -1
        for (i, v) in a.enumerated() where best < 0 || v > a[best] { best = i }
        return best
    }

    /// The first element with the smallest key, like Python's min(xs, key=...).
    public static func minBy<T>(_ xs: [T], _ less: (T, T) -> Bool) -> T? {
        guard var best = xs.first else { return nil }
        for x in xs.dropFirst() where less(x, best) { best = x }
        return best
    }

    /// np.hanning(m): the symmetric Hann window.
    public static func hann(_ m: Int) -> [Double] {
        if m < 1 { return [] }
        if m == 1 { return [1] }
        return (0..<m).map { k in
            let n = Double(1 - m + 2 * k)
            return 0.5 + 0.5 * cos(Double.pi * n / Double(m - 1))
        }
    }

    /// np.hanning(m + 1)[:-1]: the periodic Hann window used for STFT.
    public static func hannPeriodic(_ m: Int) -> [Double] {
        Array(hann(m + 1).prefix(m))
    }

    /// Python's round(x): nearest integer, ties to even.
    public static func round(_ x: Double) -> Int {
        Int(x.rounded(.toNearestOrEven))
    }

    /// Python's round(x, digits): correctly rounded, exact ties to even.
    public static func roundTo(_ x: Double, _ digits: Int) -> Double {
        if x.isNaN || x.isInfinite { return x }
        return Double(String(format: "%.*f", digits, x)) ?? x
    }

    /// np.clip for one value.
    public static func clip(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        Swift.min(Swift.max(x, lo), hi)
    }

    /// np.linspace(start, stop, n) in float32 (endpoint included).
    public static func linspace32(_ start: Double, _ stop: Double, _ n: Int) -> [Float] {
        if n <= 0 { return [] }
        if n == 1 { return [Float(start)] }
        let step = (stop - start) / Double(n - 1)
        var out = (0..<n).map { Float(start + Double($0) * step) }
        out[n - 1] = Float(stop)
        return out
    }

    /// Floor division (Python's //) for Ints.
    public static func floorDiv(_ a: Int, _ b: Int) -> Int {
        var q = a / b
        if a % b != 0, (a < 0) != (b < 0) { q -= 1 }
        return q
    }
}
