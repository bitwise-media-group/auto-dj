// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Accelerate
import Foundation

/// Changes tempo with the key kept: WSOLA (waveform-similarity overlap-add), the algorithm
/// family of ffmpeg's atempo that the Go version used, so the previews sound as before
/// (ADR 0019). 46 ms Hann windows at 50% overlap; each window is taken from within ±12 ms of
/// its nominal source position, wherever it best continues the previous one.
public enum TimeStretch {
    static let window = 2048
    static let hop = window / 2
    static let delta = 512
    static let hann: [Float] = Num.hannPeriodic(window).map { Float($0) }

    /// n output frames of src played at rate (source seconds per output second), starting at
    /// src frame 0. Missing source after its end is silence.
    public static func stretch(_ src: Stereo, rate: Double, frames n: Int) -> Stereo {
        if n <= 0 { return Stereo(count: 0) }
        if abs(rate - 1) < 1e-4 {
            var out = src
            out.resize(n)
            return out
        }
        let W = window
        let H = hop
        // padded copies: P frames of silence before frame 0, enough after the end
        let P = W + delta + 8
        let need = Int(Double(n + W) * rate) + W + delta + 8
        let len = P + max(src.count, need) + P
        var l = [Float](repeating: 0, count: len)
        var r = l
        l.replaceSubrange(P..<P + src.count, with: src.l)
        r.replaceSubrange(P..<P + src.count, with: src.r)
        var mono = [Float](repeating: 0, count: len)
        vDSP.add(l, r, result: &mono)
        // a 4x-decimated copy for the coarse similarity search
        let m4 = stride(from: 0, to: len - 3, by: 4).map { mono[$0] + mono[$0 + 1] + mono[$0 + 2] + mono[$0 + 3] }

        var out = Stereo(count: n + 2 * W)
        var prev = -H  // source position (unpadded) of the last window taken
        var k = -1  // window k is centred on output frame k * H + H; k = -1 covers the start
        while k * H < n {
            let outPos = k * H
            let nominal = Int((Double(outPos) * rate).rounded())
            var pos = nominal
            if k > -1 {
                pos = bestOffset(mono: mono, m4: m4, target: prev + H + P, nominal: nominal + P) - P
            }
            // overlap-add the window
            let s = pos + P
            for i in 0..<W {
                let o = outPos + i
                if o < 0 || o >= out.count { continue }
                let w = hann[i]
                out.l[o] += l[s + i] * w
                out.r[o] += r[s + i] * w
            }
            prev = pos
            k += 1
        }
        out.resize(n)
        return out
    }

    /// The padded source position within ±delta of nominal whose first half-window best
    /// matches the half-window at target (the natural continuation of the previous window).
    static func bestOffset(mono: [Float], m4: [Float], target: Int, nominal: Int) -> Int {
        let H = hop
        let lo = max(nominal - delta, 0)
        let hi = min(nominal + delta, mono.count - H - 1)
        if hi <= lo { return max(min(nominal, mono.count - H - 1), 0) }
        // coarse: every 4th position on the decimated copy
        let t4 = target / 4
        let n4 = H / 4
        var best = lo / 4 * 4
        var bestV = -Float.infinity
        m4.withUnsafeBufferPointer { m in
            let ref = UnsafeBufferPointer(rebasing: m[t4..<min(t4 + n4, m.count)])
            var c = lo / 4 * 4
            while c <= hi {
                let j = c / 4
                if j + ref.count <= m.count {
                    let v = vDSP.dot(ref, UnsafeBufferPointer(rebasing: m[j..<j + ref.count]))
                    if v > bestV || (v == bestV && abs(c - nominal) < abs(best - nominal)) { (bestV, best) = (v, c) }
                }
                c += 4
            }
        }
        // fine: ±3 around the coarse pick at full rate
        var fine = best
        bestV = -Float.infinity
        mono.withUnsafeBufferPointer { m in
            let ref = UnsafeBufferPointer(rebasing: m[target..<target + H])
            for c in max(best - 3, lo)...min(best + 3, hi) {
                let v = vDSP.dot(ref, UnsafeBufferPointer(rebasing: m[c..<c + H]))
                if v > bestV || (v == bestV && abs(c - nominal) < abs(fine - nominal)) { (bestV, fine) = (v, c) }
            }
        }
        return fine
    }
}
