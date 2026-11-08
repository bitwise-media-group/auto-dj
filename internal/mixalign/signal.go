// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package mixalign

import (
	"math"

	"gonum.org/v1/gonum/dsp/fourier"

	"github.com/bitwise-media-group/auto-dj/internal/features"
	"github.com/bitwise-media-group/auto-dj/internal/num"
)

// channels are the envelopes the tracks are located by, one per row, each z-scored over
// the whole signal: the low- and high-band spectral flux (features columns 4 and 5, with
// their half-second local mean removed, so they follow the hits) and the log power of the
// four bands (columns 0-3: kick and bassline, low mids, chords and stabs, hats and air).
// The flux alone is too generic: tracks with one drum kit match each other.
func channels(F []features.Frame) [][]float64 {
	out := make([][]float64, 6)
	for c := range out {
		out[c] = make([]float64, len(F))
	}
	for i, f := range F {
		out[0][i], out[1][i] = float64(f[4]), float64(f[5])
	}
	for c := range 2 {
		mm := movingMean(out[c], 21)
		for i := range out[c] {
			out[c][i] -= mm[i]
		}
	}
	for b := range 4 {
		p := make([]float64, len(F))
		for i, f := range F {
			p[i] = float64(f[b])
		}
		ref := num.Percentile(p, 50) + 1e-9
		for i, v := range p {
			out[2+b][i] = math.Log1p(v / ref)
		}
	}
	for _, x := range out {
		zscore(x)
	}
	return out
}

// zscore makes x zero-mean with unit variance in place (flat x: all zeros).
func zscore(x []float64) {
	if len(x) == 0 {
		return
	}
	m := 0.0
	for _, v := range x {
		m += v
	}
	m /= float64(len(x))
	sd := 0.0
	for i := range x {
		x[i] -= m
		sd += x[i] * x[i]
	}
	sd = math.Sqrt(sd / float64(len(x)))
	if sd < 1e-12 {
		clear(x)
		return
	}
	for i := range x {
		x[i] /= sd
	}
}

// amp is the amplitude (square root of the summed band power) of the given band columns.
func amp(F []features.Frame, cols ...int) []float64 {
	out := make([]float64, len(F))
	for i, f := range F {
		s := 0.0
		for _, c := range cols {
			s += float64(f[c])
		}
		out[i] = math.Sqrt(s)
	}
	return out
}

// movingMean is the mean of x over a centred window of w frames (shorter at the edges).
func movingMean(x []float64, w int) []float64 {
	p := prefix(x)
	out := make([]float64, len(x))
	h := w / 2
	for i := range x {
		a, b := max(i-h, 0), min(i+h+1, len(x))
		out[i] = (p[b] - p[a]) / float64(b-a)
	}
	return out
}

// prefix is the running sum of x, with p[0] = 0.
func prefix(x []float64) []float64 {
	p := make([]float64, len(x)+1)
	for i, v := range x {
		p[i+1] = p[i] + v
	}
	return p
}

// at is x linearly interpolated at fractional index pos; ok is false outside the samples.
func at(x []float64, pos float64) (float64, bool) {
	if pos < 0 || pos > float64(len(x)-1) || len(x) == 0 {
		return 0, false
	}
	i := int(pos)
	if i >= len(x)-1 {
		return x[len(x)-1], true
	}
	f := pos - float64(i)
	return x[i]*(1-f) + x[i+1]*f, true
}

// pearson is the correlation of x and y (0 when either is flat).
func pearson(x, y []float64) float64 {
	n := float64(len(x))
	if n < 2 {
		return 0
	}
	var sx, sy, sxx, syy, sxy float64
	for i := range x {
		sx += x[i]
		sy += y[i]
		sxx += x[i] * x[i]
		syy += y[i] * y[i]
		sxy += x[i] * y[i]
	}
	vx, vy := sxx-sx*sx/n, syy-sy*sy/n
	if vx <= 1e-12 || vy <= 1e-12 {
		return 0
	}
	return (sxy - sx*sy/n) / math.Sqrt(vx*vy)
}

// normalise makes q zero-mean with unit norm in place; false when q is flat.
func normalise(q []float64) bool {
	m := 0.0
	for _, v := range q {
		m += v
	}
	m /= float64(len(q))
	n := 0.0
	for i := range q {
		q[i] -= m
		n += q[i] * q[i]
	}
	if n <= 1e-12 {
		return false
	}
	n = math.Sqrt(n)
	for i := range q {
		q[i] /= n
	}
	return true
}

// maxFilter is the maximum of x over a centred window of 2w+1 samples.
func maxFilter(x []float64, w int) []float64 {
	if w <= 0 {
		return x
	}
	out := make([]float64, len(x))
	for i := range x {
		m := math.Inf(-1)
		for j := max(i-w, 0); j <= min(i+w, len(x)-1); j++ {
			m = math.Max(m, x[j])
		}
		out[i] = m
	}
	return out
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

// correlator computes normalised cross-correlations of short probes against one signal x
// by FFT. Not safe for concurrent use: give each goroutine its own (fork).
type correlator struct {
	x      []float64
	n      int
	fft    *fourier.FFT
	X      []complex128 // x's spectrum, shared between forks
	p1, p2 []float64    // prefix sums of x and x², shared
	buf    []float64
	coef   []complex128
}

func newCorrelator(x []float64) *correlator {
	n := smoothLen(len(x))
	c := &correlator{x: x, n: n, fft: fourier.NewFFT(n)}
	pad := make([]float64, n)
	copy(pad, x)
	c.X = c.fft.Coefficients(nil, pad)
	sq := make([]float64, len(x))
	for i, v := range x {
		sq[i] = v * v
	}
	c.p1, c.p2 = prefix(x), prefix(sq)
	c.buf, c.coef = make([]float64, n), make([]complex128, n/2+1)
	return c
}

// fork is a correlator sharing c's spectrum with its own FFT work space.
func (c *correlator) fork() *correlator {
	return &correlator{x: c.x, n: c.n, fft: fourier.NewFFT(c.n), X: c.X, p1: c.p1, p2: c.p2,
		buf: make([]float64, c.n), coef: make([]complex128, c.n/2+1)}
}

// ncc is the Pearson correlation of the zero-mean, unit-norm probe q with x[L:L+len(q)] for
// every lag L in 0 .. len(x)-len(q).
func (c *correlator) ncc(q []float64) []float64 {
	m := len(q)
	if m == 0 || m > len(c.x) {
		return nil
	}
	clear(c.buf)
	copy(c.buf, q)
	Q := c.fft.Coefficients(c.coef, c.buf)
	for i := range Q {
		Q[i] = c.X[i] * complex(real(Q[i]), -imag(Q[i]))
	}
	raw := c.fft.Sequence(c.buf, Q)
	out := make([]float64, len(c.x)-m+1)
	fm := float64(m)
	for L := range out {
		s1 := c.p1[L+m] - c.p1[L]
		v := c.p2[L+m] - c.p2[L] - s1*s1/fm
		if v > 1e-9 {
			out[L] = raw[L] / float64(c.n) / math.Sqrt(v)
		}
	}
	return out
}
