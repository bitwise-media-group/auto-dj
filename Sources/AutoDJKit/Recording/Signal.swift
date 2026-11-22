// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Accelerate
import Foundation

/// The envelopes and correlations the recording alignment works on (port of
/// internal/mixalign/signal.go).
enum Signal {
    /// The envelopes the tracks are located by, one per row, each z-scored over the whole
    /// signal: the low- and high-band spectral flux (feature columns 4 and 5, with their
    /// half-second local mean removed, so they follow the hits) and the log power of the four
    /// bands (columns 0-3: kick and bassline, low mids, chords and stabs, hats and air). The flux
    /// alone is too generic: tracks with one drum kit match each other.
    static func channels(_ F: Features.Frames) -> [[Double]] {
        let n = F.count
        var out = [[Double]](repeating: [Double](repeating: 0, count: n), count: 6)
        for i in 0..<n {
            out[0][i] = Double(F[i, 4])
            out[1][i] = Double(F[i, 5])
        }
        for c in 0..<2 {
            let mm = movingMean(out[c], 21)
            for i in 0..<n { out[c][i] -= mm[i] }
        }
        for b in 0..<4 {
            let p = (0..<n).map { Double(F[$0, b]) }
            let ref = Num.percentile(p, 50) + 1e-9
            out[2 + b] = p.map { log1p($0 / ref) }
        }
        for c in out.indices { zscore(&out[c]) }
        return out
    }

    /// x made zero-mean with unit variance in place (flat x: all zeros).
    static func zscore(_ x: inout [Double]) {
        if x.isEmpty { return }
        let m = vDSP.mean(x)
        vDSP.add(-m, x, result: &x)
        let sd = (vDSP.sumOfSquares(x) / Double(x.count)).squareRoot()
        if sd < 1e-12 {
            x = [Double](repeating: 0, count: x.count)
            return
        }
        vDSP.divide(x, sd, result: &x)
    }

    /// The amplitude (square root of the summed band power) of the given band columns.
    static func amp(_ F: Features.Frames, _ cols: [Int]) -> [Double] {
        (0..<F.count).map { i in cols.reduce(0.0) { $0 + Double(F[i, $1]) }.squareRoot() }
    }

    /// The mean of x over a centred window of w frames (shorter at the edges).
    static func movingMean(_ x: [Double], _ w: Int) -> [Double] {
        let p = prefix(x)
        let h = w / 2
        return x.indices.map { i in
            let a = max(i - h, 0)
            let b = min(i + h + 1, x.count)
            return (p[b] - p[a]) / Double(b - a)
        }
    }

    /// The running sum of x, with p[0] = 0.
    static func prefix(_ x: [Double]) -> [Double] {
        var p = [Double](repeating: 0, count: x.count + 1)
        for (i, v) in x.enumerated() { p[i + 1] = p[i] + v }
        return p
    }

    /// x linearly interpolated at fractional index pos; nil outside the samples.
    @inline(__always)
    static func at(_ x: [Double], _ pos: Double) -> Double? {
        if x.isEmpty || pos < 0 || pos > Double(x.count - 1) { return nil }
        let i = Int(pos)
        if i >= x.count - 1 { return x[x.count - 1] }
        let f = pos - Double(i)
        return x[i] * (1 - f) + x[i + 1] * f
    }

    /// The correlation of x and y (0 when either is flat).
    static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        let n = Double(x.count)
        if n < 2 { return 0 }
        let sx = vDSP.sum(x)
        let sy = vDSP.sum(y)
        let sxx = vDSP.sumOfSquares(x)
        let syy = vDSP.sumOfSquares(y)
        let sxy = vDSP.dot(x, y)
        let vx = sxx - sx * sx / n
        let vy = syy - sy * sy / n
        if vx <= 1e-12 || vy <= 1e-12 { return 0 }
        return (sxy - sx * sy / n) / (vx * vy).squareRoot()
    }

    /// q made zero-mean with unit norm in place; false when q is flat.
    static func normalise(_ q: inout [Double]) -> Bool {
        let m = vDSP.mean(q)
        vDSP.add(-m, q, result: &q)
        let n = vDSP.sumOfSquares(q)
        if n <= 1e-12 { return false }
        vDSP.divide(q, n.squareRoot(), result: &q)
        return true
    }

    /// The maximum of x over a centred window of 2w+1 samples.
    static func maxFilter(_ x: [Double], _ w: Int) -> [Double] {
        if w <= 0 || x.isEmpty { return x }
        // pad with -inf so every window is whole, then a sliding max
        let pad = [Double](repeating: -.infinity, count: w)
        let y = pad + x + pad
        var out = [Double](repeating: 0, count: x.count)
        y.withUnsafeBufferPointer { yp in
            out.withUnsafeMutableBufferPointer { op in
                vDSP_vswmaxD(yp.baseAddress!, 1, op.baseAddress!, 1, vDSP_Length(x.count), vDSP_Length(2 * w + 1))
            }
        }
        return out
    }
}

/// Normalised cross-correlations of short probes against one signal x by FFT (power-of-two
/// sizes, vDSP). Not safe for concurrent use: give each task its own (`fork`).
final class Correlator: @unchecked Sendable {
    let x: [Double]
    let n: Int
    let log2n: vDSP_Length
    let setup: FFTSetupD
    let ownsSetup: Bool
    /// x's spectrum (vDSP's packed real format), shared between forks.
    let xr: [Double]
    let xi: [Double]
    /// Prefix sums of x and x², shared.
    let p1: [Double]
    let p2: [Double]
    var qr: [Double]
    var qi: [Double]
    var buf: [Double]

    init(_ x: [Double]) {
        self.x = x
        var n = 2
        while n < x.count { n <<= 1 }
        self.n = n
        log2n = vDSP_Length(log2(Double(n)).rounded())
        setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
        ownsSetup = true
        (xr, xi) = Self.forward(x, n: n, log2n: log2n, setup: setup)
        p1 = Signal.prefix(x)
        p2 = Signal.prefix(x.map { $0 * $0 })
        qr = [Double](repeating: 0, count: n / 2)
        qi = qr
        buf = [Double](repeating: 0, count: n)
    }

    private init(fork c: Correlator) {
        (x, n, log2n, setup, xr, xi, p1, p2) = (c.x, c.n, c.log2n, c.setup, c.xr, c.xi, c.p1, c.p2)
        ownsSetup = false
        qr = [Double](repeating: 0, count: n / 2)
        qi = qr
        buf = [Double](repeating: 0, count: n)
        parent = c
    }

    /// Keeps the shared FFT setup alive.
    private var parent: Correlator?

    deinit { if ownsSetup { vDSP_destroy_fftsetupD(setup) } }

    /// A correlator sharing this one's spectrum, with its own work space.
    func fork() -> Correlator { Correlator(fork: self) }

    static func forward(_ v: [Double], n: Int, log2n: vDSP_Length, setup: FFTSetupD) -> ([Double], [Double]) {
        var re = [Double](repeating: 0, count: n / 2)
        var im = re
        var padded = v + [Double](repeating: 0, count: n - v.count)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var z = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                padded.withUnsafeMutableBytes {
                    vDSP_ctozD($0.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2, &z, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zripD(setup, &z, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        return (re, im)
    }

    /// The Pearson correlation of the zero-mean, unit-norm probe q with x[L..<L+q.count] for
    /// every lag L in 0 ... x.count-q.count.
    func ncc(_ q: [Double]) -> [Double] {
        let m = q.count
        if m == 0 || m > x.count { return [] }
        for i in 0..<n { buf[i] = i < m ? q[i] : 0 }
        let h = n / 2
        qr.withUnsafeMutableBufferPointer { rp in
            qi.withUnsafeMutableBufferPointer { ip in
                var z = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buf.withUnsafeMutableBytes {
                    vDSP_ctozD($0.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2, &z, 1, vDSP_Length(h))
                }
                vDSP_fft_zripD(setup, &z, 1, log2n, FFTDirection(kFFTDirection_Forward))
                // X · conj(Q); DC and Nyquist are real and packed in [0]
                rp[0] = xr[0] * rp[0]
                ip[0] = xi[0] * ip[0]
                for k in 1..<h {
                    let (a, b, c, d) = (xr[k], xi[k], rp[k], ip[k])
                    rp[k] = a * c + b * d
                    ip[k] = b * c - a * d
                }
                vDSP_fft_zripD(setup, &z, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                buf.withUnsafeMutableBytes {
                    vDSP_ztocD(&z, 1, $0.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2, vDSP_Length(h))
                }
            }
        }
        // vDSP: forward is 2x the DFT, inverse n x the normalised inverse: 4n in all
        let scale = 1 / (4 * Double(n))
        let fm = Double(m)
        var out = [Double](repeating: 0, count: x.count - m + 1)
        for L in out.indices {
            let s1 = p1[L + m] - p1[L]
            let v = p2[L + m] - p2[L] - s1 * s1 / fm
            if v > 1e-9 { out[L] = buf[L] * scale / v.squareRoot() }
        }
        return out
    }
}
