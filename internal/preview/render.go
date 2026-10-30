// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package preview

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"

	"gonum.org/v1/gonum/dsp/fourier"

	"github.com/bitwise-media-group/adj/internal/num"
)

// Stereo is interleaved-by-frame float32 audio at SR.
type Stereo [][2]float32

// decode returns dur output seconds of path from source second start at tempo (source s
// per output s, key kept), padded with silence before 0 and after the end of the file.
func decode(path string, start, dur, tempo float64) (Stereo, error) {
	pre := math.Max(0, -start) // requested start before 0: pad with silence
	args := []string{"-v", "error",
		"-ss", fmt.Sprintf("%.4f", math.Max(start, 0)),
		"-t", fmt.Sprintf("%.4f", math.Max(dur*tempo-pre*tempo, 0.01)),
		"-i", path, "-ac", "2", "-ar", fmt.Sprint(SR)}
	if math.Abs(tempo-1) > 1e-4 {
		args = append(args, "-af", fmt.Sprintf("atempo=%.6f", tempo))
	}
	args = append(args, "-f", "f32le", "-")
	cmd := exec.Command("ffmpeg", args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	raw, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("ffmpeg decoding %s: %w: %s", filepath.Base(path), err, strings.TrimSpace(stderr.String()))
	}
	n := num.Round(dur * SR)
	y := make(Stereo, n)
	off := int(pre * SR)
	for i := 0; i+8 <= len(raw) && off+i/8 < n; i += 8 {
		y[off+i/8] = [2]float32{
			math.Float32frombits(binary.LittleEndian.Uint32(raw[i:])),
			math.Float32frombits(binary.LittleEndian.Uint32(raw[i+4:])),
		}
	}
	return y, nil
}

// decodeRoute returns dur output seconds of a track from playback second p0 at tempo,
// through its jumps (a JumpXFS crossfade into each).
func decodeRoute(path string, route *Route, p0, dur, tempo float64) (Stereo, error) {
	n := num.Round(dur * SR)
	y := make(Stereo, n)
	xf := int(JumpXFS * SR)
	pieces := route.Span(p0, p0+dur*tempo)
	for k, p := range pieces {
		i0 := num.Round((p.Q - p0) / tempo * SR)
		last := k == len(pieces)-1
		m := n - i0
		if !last {
			m = min(m, num.Round((p.S1-p.S0)/tempo*SR)+xf)
		}
		if m <= 0 {
			continue
		}
		z, err := decode(path, p.S0, float64(m)/SR, tempo)
		if err != nil {
			return nil, err
		}
		z = z[:min(m, len(z))]
		r := num.Linspace32(0, 1, min(xf, m))
		for i, w := range r {
			if k > 0 {
				z[i][0] *= w
				z[i][1] *= w
			}
			if !last {
				j := len(z) - len(r) + i
				z[j][0] *= r[len(r)-1-i]
				z[j][1] *= r[len(r)-1-i]
			}
		}
		for i, v := range z {
			if i0+i < n {
				y[i0+i][0] += v[0]
				y[i0+i][1] += v[1]
			}
		}
	}
	return y, nil
}

// smoothLen is the smallest n' >= n with no prime factor above 5 (a fast FFT size).
func smoothLen(n int) int {
	for m := max(n, 1); ; m++ {
		k := m
		for _, p := range []int{2, 3, 5} {
			for k%p == 0 {
				k /= p
			}
		}
		if k == 1 {
			return m
		}
	}
}

// lowCut removes the bass below ~LowCutHz with a zero-phase FFT mask (ramping from 0.6 to
// 1.0 x LowCutHz). The segment is zero-padded to a fast FFT length.
func lowCut(y Stereo) Stereo {
	n := len(y)
	if n == 0 {
		return Stereo{}
	}
	m := smoothLen(n)
	fft := fourier.NewFFT(m)
	val := 1.0 / (float64(m) * (1.0 / SR))
	mask := make([]float64, m/2+1)
	for k := range mask {
		mask[k] = num.Clip((float64(k)*val-LowCutHz*0.6)/(LowCutHz*0.4), 0, 1)
	}
	out := make(Stereo, n)
	seq := make([]float64, m)
	for ch := range 2 {
		for i := range seq {
			seq[i] = 0
			if i < n {
				seq[i] = float64(y[i][ch])
			}
		}
		c := fft.Coefficients(nil, seq)
		for k := range c {
			c[k] *= complex(mask[k], 0)
		}
		res := fft.Sequence(nil, c)
		for i := range n {
			out[i][ch] = float32(res[i] / float64(m))
		}
	}
	return out
}

// lowpassSweep is a low-pass whose cutoff falls log-linearly from hi to lo over the first
// sweep samples of y (all of it when sweep is 0), then stays at lo (STFT, 24 dB/oct).
func lowpassSweep(y Stereo, sweep int) Stereo {
	const nFFT, hi, lo = 2048, 16000.0, 20.0
	hop := nFFT / 2
	if sweep == 0 {
		sweep = len(y)
	}
	sweep = max(sweep, 1)
	w := num.HannPeriodic(nFFT) // sqrt periodic Hann: w^2 sums to 1 at 50% hop
	for i := range w {
		w[i] = math.Sqrt(w[i])
	}
	pad := make(Stereo, nFFT+len(y)+nFFT+hop)
	copy(pad[nFFT:], y)
	out := make(Stereo, len(pad))
	fft := fourier.NewFFT(nFFT)
	val := 1.0 / (float64(nFFT) * (1.0 / SR))
	seq := make([]float64, nFFT)
	var coef []complex128
	var res []float64
	for a := 0; a <= len(pad)-nFFT; a += hop {
		prog := num.Clip(float64(a+nFFT/2-nFFT)/float64(sweep), 0, 1)
		fc := hi * math.Pow(lo/hi, prog)
		for ch := range 2 {
			for i := range seq {
				seq[i] = float64(pad[a+i][ch]) * w[i]
			}
			coef = fft.Coefficients(coef, seq)
			for k := range coef {
				coef[k] /= complex(math.Sqrt(1+math.Pow(float64(k)*val/fc, 8)), 0)
			}
			res = fft.Sequence(res, coef)
			for i := range nFFT {
				out[a+i][ch] += float32(res[i] / nFFT * w[i])
			}
		}
	}
	return out[nFFT : nFFT+len(y)]
}

// renderTrack is one track's audio over mix time [Start, End), with its jumps, fades, bass
// swaps and exit.
func renderTrack(s *Seg) (Stereo, error) {
	y, err := decodeSeg(s)
	if err != nil {
		return nil, err
	}
	n := len(y)
	t := func(i int) float64 { return s.Start + float64(i)/SR }
	idx := func(x float64) int { return int(num.Clip(math.RoundToEven((x-s.Start)*SR), 0, float64(n))) }
	if s.BassIn != nil { // no bass until the swap
		swapBass(y[:idx(*s.BassIn+0.2)], 0, t, *s.BassIn, true)
	}
	if s.BassOut != nil { // bass gone after the swap
		k := idx(*s.BassOut - 0.2)
		swapBass(y[k:], k, t, *s.BassOut, false)
	}
	if fi := s.FadeIn; fi != nil {
		scale(y, func(i int) float64 { return num.Clip((t(i)-fi[0])/math.Max(fi[1]-fi[0], 1e-3), 0, 1) })
	}
	xs := s.Exit.Xs
	switch s.Exit.Kind {
	case "filter": // sweep to silence, then fade out
		k := idx(xs[0])
		copy(y[k:], lowpassSweep(y[k:], idx(xs[1])-k))
		scale(y, func(i int) float64 { return 1 - num.Clip((t(i)-xs[1])/math.Max(xs[2]-xs[1], 1e-3), 0, 1) })
	case "fade":
		scale(y, func(i int) float64 { return 1 - num.Clip((t(i)-xs[0])/math.Max(xs[1]-xs[0], 1e-3), 0, 1) })
	}
	if s.Exit.Kind == "filter" || s.Exit.Kind == "cut" { // the cut itself, without a click
		scale(y, func(i int) float64 { return num.Clip((s.End-t(i))/CutRampS, 0, 1) })
	}
	return y, nil
}

// decodeSeg decodes the track's audio for [Start, End): stretched until the clock's split,
// at its own tempo after, with a short crossfade where the tempo goes back to normal.
func decodeSeg(s *Seg) (Stereo, error) {
	c, path, route := s.Clock, s.Rec.Path, s.Route
	n := num.Round((s.End - s.Start) * SR)
	pre := math.Min(math.Max(c.Split-c.Out0, 0), s.End-s.Start) // stretched part (mix seconds)
	preN := num.Round(pre * SR)
	var y Stereo
	if pre > 0 {
		head, err := decodeRoute(path, route, c.Src0, pre+SplitXFS, c.Rate)
		if err != nil {
			return nil, err
		}
		y = head
		if n-preN > 0 {
			y = head[:min(preN, len(head))]
			tail := head[len(y):]
			rest, err := decodeRoute(path, route, c.SrcSplit(), s.End-s.Start-pre, 1)
			if err != nil {
				return nil, err
			}
			tail = tail[:min(int(SplitXFS*SR), len(rest), len(tail))]
			r := num.Linspace32(0, 1, len(tail))
			for i := range tail {
				for ch := range 2 {
					rest[i][ch] = tail[i][ch]*(1-r[i]) + rest[i][ch]*r[i]
				}
			}
			y = append(slices.Clip(y), rest...)
		}
	} else if n-preN > 0 {
		rest, err := decodeRoute(path, route, c.SrcSplit(), s.End-s.Start-pre, 1)
		if err != nil {
			return nil, err
		}
		y = rest
	}
	if len(y) > n {
		y = y[:n]
	}
	for len(y) < n {
		y = append(y, [2]float32{})
	}
	return y, nil
}

// swapBass crossfades y (mix samples from index off) between itself and its low-cut version
// around mix second at: low-cut before it when in, after it when out.
func swapBass(y Stereo, off int, t func(int) float64, at float64, in bool) {
	if len(y) == 0 {
		return
	}
	lc := lowCut(y)
	for i := range y {
		xf := num.Clip((t(off+i)-at)/SwapXFS+0.5, 0, 1)
		wy, wl := xf, 1-xf // the original before, the low cut after
		if !in {
			wy, wl = 1-xf, xf
		}
		for ch := range 2 {
			y[i][ch] = float32(float64(lc[i][ch])*wl + float64(y[i][ch])*wy)
		}
	}
}

// scale multiplies every sample i of y by g(i).
func scale(y Stereo, g func(i int) float64) {
	for i := range y {
		v := g(i)
		y[i][0] = float32(float64(y[i][0]) * v)
		y[i][1] = float32(float64(y[i][1]) * v)
	}
}

// limit applies fixed headroom plus a soft knee, so overlaps don't clip (a whole set can't
// be normalised up front while streaming).
func limit(y Stereo, w *bufio.Writer) error {
	const gain, knee = 0.85, 0.8
	var b [4]byte
	for _, fr := range y {
		for _, v := range fr {
			x := float64(v * gain)
			if a := math.Abs(x); a > knee {
				x = math.Copysign(knee+(1-knee)*math.Tanh((a-knee)/(1-knee)), x)
			}
			binary.LittleEndian.PutUint32(b[:], math.Float32bits(float32(x)))
			if _, err := w.Write(b[:]); err != nil {
				return err
			}
		}
	}
	return nil
}

// RenderSet renders a timeline to one MP3, a track at a time (two in memory at most).
func RenderSet(segs []*Seg, out string) (string, error) {
	var play []*Seg
	for _, s := range segs {
		if !s.Missing {
			play = append(play, s)
		}
	}
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return "", err
	}
	cmd := exec.Command("ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", fmt.Sprint(SR), "-ac", "2", "-i", "-",
		"-b:a", "160k", out)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return "", err
	}
	if err := cmd.Start(); err != nil {
		return "", err
	}
	w := bufio.NewWriterSize(stdin, 1<<20)
	fail := func(err error) (string, error) {
		_ = stdin.Close()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return "", err
	}
	var buf Stereo // unwritten mix audio, from sample buf0
	buf0 := 0
	for k, s := range play {
		y, err := renderTrack(s)
		if err != nil {
			return fail(err)
		}
		i0 := num.Round(s.Start*SR) - buf0
		if need := i0 + len(y); need > len(buf) {
			buf = append(buf, make(Stereo, need-len(buf))...)
		}
		for i, v := range y {
			buf[i0+i][0] += v[0]
			buf[i0+i][1] += v[1]
		}
		// nothing later starts before the next track, so everything up to it is final
		done := len(buf)
		if k+1 < len(play) {
			done = num.Round(play[k+1].Start*SR) - buf0
			if done > len(buf) { // a gap (missing audio): silence until the next track
				buf = append(buf, make(Stereo, done-len(buf))...)
			}
		}
		if err := limit(buf[:done], w); err != nil {
			return fail(err)
		}
		buf, buf0 = buf[done:], buf0+done
	}
	if err := w.Flush(); err != nil {
		return fail(err)
	}
	_ = stdin.Close()
	if err := cmd.Wait(); err != nil {
		return "", fmt.Errorf("ffmpeg failed writing %s: %w: %s", out, err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}
