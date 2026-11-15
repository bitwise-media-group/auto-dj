// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Accelerate
import Foundation

/// Stereo float32 audio at `Mix.sampleRate`, one array per channel.
public struct Stereo: Sendable, Equatable {
    public var l: [Float]
    public var r: [Float]

    public init(count: Int) {
        l = [Float](repeating: 0, count: count)
        r = l
    }

    public init(l: [Float], r: [Float]) {
        self.l = l
        self.r = r
    }

    public var count: Int { l.count }

    public subscript(range: Range<Int>) -> Stereo { Stereo(l: Array(l[range]), r: Array(r[range])) }

    /// Adds other into self from frame `at` (growing as needed).
    public mutating func add(_ other: Stereo, at: Int) {
        let need = at + other.count
        if need > count {
            l += [Float](repeating: 0, count: need - count)
            r += [Float](repeating: 0, count: need - r.count)
        }
        other.l.withUnsafeBufferPointer { src in
            l.withUnsafeMutableBufferPointer { dst in
                vDSP.add(src, UnsafeBufferPointer(rebasing: dst[at..<need]), result: &dst[at..<need])
            }
        }
        other.r.withUnsafeBufferPointer { src in
            r.withUnsafeMutableBufferPointer { dst in
                vDSP.add(src, UnsafeBufferPointer(rebasing: dst[at..<need]), result: &dst[at..<need])
            }
        }
    }

    /// Multiplies frame i by g(i).
    public mutating func scale(_ g: (Int) -> Double) {
        for i in 0..<count {
            let v = Float(g(i))
            l[i] *= v
            r[i] *= v
        }
    }

    /// Resizes to n frames (truncating or padding with silence).
    public mutating func resize(_ n: Int) {
        if count > n {
            l.removeLast(count - n)
            r.removeLast(r.count - n)
        } else if count < n {
            l += [Float](repeating: 0, count: n - count)
            r += [Float](repeating: 0, count: n - r.count)
        }
    }
}

/// The mix's DSP (port of internal/preview/render.go): zero-phase low-cut for the bass swap,
/// the STFT low-pass sweep of a FILTER exit, and the soft limiter.
public enum DSP {
    static let sr = Mix.sampleRate

    /// Real FFT helper over a power-of-two size: forward to (re, im) with vDSP's packing and
    /// scaling (DC in re[0], Nyquist in im[0], both scaled by 2), inverse back (scaled by 2n).
    final class RealFFT {
        let n: Int
        let log2n: vDSP_Length
        let setup: FFTSetup

        init(_ n: Int) {
            self.n = n
            log2n = vDSP_Length(log2(Double(n)).rounded())
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        /// Filters x (n samples) in place by a real gain per bin (gain.count == n/2 + 1).
        func filter(_ x: inout [Float], gain: [Float]) {
            let h = n / 2
            var re = [Float](repeating: 0, count: h)
            var im = [Float](repeating: 0, count: h)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var z = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    x.withUnsafeBytes { xb in
                        vDSP_ctoz(xb.bindMemory(to: DSPComplex.self).baseAddress!, 2, &z, 1, vDSP_Length(h))
                    }
                    vDSP_fft_zrip(setup, &z, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    rp[0] *= gain[0]
                    ip[0] *= gain[h]  // Nyquist
                    for k in 1..<h {
                        rp[k] *= gain[k]
                        ip[k] *= gain[k]
                    }
                    vDSP_fft_zrip(setup, &z, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                    x.withUnsafeMutableBytes { xb in
                        vDSP_ztoc(&z, 1, xb.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(h))
                    }
                }
            }
            var s = Float(1) / Float(2 * n)
            vDSP_vsmul(x, 1, &s, &x, 1, vDSP_Length(n))
        }
    }

    static func pow2(_ n: Int) -> Int {
        var m = 1
        while m < n { m <<= 1 }
        return max(m, 2)
    }

    /// Removes the bass below ~`Mix.lowCutHz` with a zero-phase FFT mask (ramping from 0.6 to
    /// 1.0 x the cutoff). The segment is zero-padded to a power-of-two FFT length.
    public static func lowCut(_ y: Stereo) -> Stereo {
        let n = y.count
        if n == 0 { return y }
        let m = pow2(n)
        let fft = RealFFT(m)
        let val = 1.0 / (Double(m) * (1.0 / sr))
        let gain = (0...m / 2).map { k in
            Float(Num.clip((Double(k) * val - Mix.lowCutHz * 0.6) / (Mix.lowCutHz * 0.4), 0, 1))
        }
        var out = Stereo(count: 0)
        for ch in 0..<2 {
            var x = (ch == 0 ? y.l : y.r) + [Float](repeating: 0, count: m - n)
            fft.filter(&x, gain: gain)
            x.removeLast(m - n)
            if ch == 0 { out.l = x } else { out.r = x }
        }
        return out
    }

    /// A low-pass whose cutoff falls log-linearly from 16 kHz to 20 Hz over the first sweep
    /// samples of y (all of it when sweep is 0), then stays at 20 Hz (STFT, 24 dB/oct).
    public static func lowpassSweep(_ y: Stereo, sweep: Int) -> Stereo {
        let nFFT = 2048
        let hop = nFFT / 2
        let hi = 16000.0
        let lo = 20.0
        let sweep = max(sweep == 0 ? y.count : sweep, 1)
        let w = Num.hannPeriodic(nFFT).map { Float($0.squareRoot()) }  // sqrt Hann: w^2 sums to 1
        let padN = nFFT + y.count + nFFT + hop
        let fft = RealFFT(nFFT)
        let val = 1.0 / (Double(nFFT) * (1.0 / sr))
        var out = Stereo(count: 0)
        for ch in 0..<2 {
            var pad = [Float](repeating: 0, count: padN)
            let src = ch == 0 ? y.l : y.r
            pad.replaceSubrange(nFFT..<nFFT + src.count, with: src)
            var acc = [Float](repeating: 0, count: padN)
            var frame = [Float](repeating: 0, count: nFFT)
            var a = 0
            while a <= padN - nFFT {
                let prog = Num.clip(Double(a + nFFT / 2 - nFFT) / Double(sweep), 0, 1)
                let fc = hi * pow(lo / hi, prog)
                let gain = (0...nFFT / 2).map { k in Float(1 / (1 + pow(Double(k) * val / fc, 8)).squareRoot()) }
                for i in 0..<nFFT { frame[i] = pad[a + i] * w[i] }
                fft.filter(&frame, gain: gain)
                for i in 0..<nFFT { acc[a + i] += frame[i] * w[i] }
                a += hop
            }
            let res = Array(acc[nFFT..<nFFT + y.count])
            if ch == 0 { out.l = res } else { out.r = res }
        }
        return out
    }

    /// Crossfades y (mix seconds t(i)) between itself and its low-cut version around mix second
    /// `at`: low-cut before it when in, after it when out.
    public static func swapBass(_ y: inout Stereo, range: Range<Int>, t: (Int) -> Double, at: Double, in isIn: Bool) {
        if range.isEmpty { return }
        let part = y[range]
        let lc = lowCut(part)
        for (k, i) in range.enumerated() {
            let xf = Num.clip((t(i) - at) / Mix.swapXFS + 0.5, 0, 1)
            let (wy, wl) = isIn ? (xf, 1 - xf) : (1 - xf, xf)  // the original before, the low cut after (in)
            y.l[i] = Float(Double(lc.l[k]) * wl + Double(part.l[k]) * wy)
            y.r[i] = Float(Double(lc.r[k]) * wl + Double(part.r[k]) * wy)
        }
    }

    /// Fixed headroom plus a soft knee, so overlaps don't clip (a whole set can't be normalised
    /// up front while streaming).
    public static func limit(_ y: inout Stereo) {
        let gain: Float = 0.85
        let knee: Float = 0.8
        func f(_ v: Float) -> Float {
            let x = v * gain
            let a = abs(x)
            if a <= knee { return x }
            let s = knee + (1 - knee) * tanh((a - knee) / (1 - knee))
            return x < 0 ? -s : s
        }
        for i in 0..<y.count {
            y.l[i] = f(y.l[i])
            y.r[i] = f(y.r[i])
        }
    }
}
