// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package num holds the few numpy behaviours the cue rules depend on, reproduced exactly:
// linear-interpolation percentiles, pairwise summation, first-wins argmin/argmax, Hann
// windows and Python's rounding.
package num

import (
	"math"
	"slices"
	"strconv"
)

// pwBlock is numpy's PW_BLOCKSIZE: pairwise summation unrolls 8 accumulators up to it.
const pwBlock = 128

// Float is the element type numpy's pairwise summation works over.
type Float interface{ ~float32 | ~float64 }

// Sum is numpy's sum of a 1-D array: pairwise summation in the array's own precision.
func Sum[T Float](a []T) T {
	n := len(a)
	switch {
	case n < 8:
		var res T
		for _, v := range a {
			res += v
		}
		return res
	case n <= pwBlock:
		var r [8]T
		copy(r[:], a[:8])
		i := 8
		for ; i < n-n%8; i += 8 {
			for j := range 8 {
				r[j] += a[i+j]
			}
		}
		res := ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
		for ; i < n; i++ {
			res += a[i]
		}
		return res
	default:
		n2 := n / 2
		n2 -= n2 % 8
		return Sum(a[:n2]) + Sum(a[n2:])
	}
}

// Mean is numpy's mean of a 1-D array (NaN when empty, as numpy warns and returns nan).
func Mean[T Float](a []T) T {
	if len(a) == 0 {
		return T(math.NaN())
	}
	return Sum(a) / T(len(a))
}

// Percentile is np.percentile(a, q) with the default linear method.
func Percentile(a []float64, q float64) float64 {
	n := len(a)
	if n == 0 {
		return math.NaN()
	}
	s := slices.Clone(a)
	slices.Sort(s)
	v := float64(n-1) * (q / 100)
	if v >= float64(n-1) {
		return s[n-1]
	}
	if v < 0 {
		return s[0]
	}
	lo := math.Floor(v)
	i := int(lo)
	return lerp(s[i], s[i+1], v-lo)
}

// lerp is numpy's _lerp: interpolate from the nearer end so t=1 gives b exactly.
func lerp(a, b, t float64) float64 {
	d := b - a
	if t >= 0.5 {
		return b - d*(1-t)
	}
	return a + d*t
}

// Argmin is np.argmin: the first index of the smallest value (-1 when empty).
func Argmin(a []float64) int {
	best := -1
	for i, v := range a {
		if best < 0 || v < a[best] {
			best = i
		}
	}
	return best
}

// Argmax is np.argmax: the first index of the largest value (-1 when empty).
func Argmax(a []float64) int {
	best := -1
	for i, v := range a {
		if best < 0 || v > a[best] {
			best = i
		}
	}
	return best
}

// MinBy returns the first element with the smallest key, like Python's min(xs, key=...).
func MinBy[T any](xs []T, less func(a, b T) bool) (T, bool) {
	var best T
	if len(xs) == 0 {
		return best, false
	}
	best = xs[0]
	for _, x := range xs[1:] {
		if less(x, best) {
			best = x
		}
	}
	return best, true
}

// Hann is np.hanning(m): the symmetric Hann window.
func Hann(m int) []float64 {
	if m < 1 {
		return nil
	}
	if m == 1 {
		return []float64{1}
	}
	w := make([]float64, m)
	for k := range w {
		n := float64(1 - m + 2*k)
		w[k] = 0.5 + 0.5*math.Cos(math.Pi*n/float64(m-1))
	}
	return w
}

// HannPeriodic is np.hanning(m + 1)[:-1]: the periodic Hann window used for STFT.
func HannPeriodic(m int) []float64 {
	return Hann(m + 1)[:m]
}

// Round is Python's round(x): nearest integer, ties to even.
func Round(x float64) int {
	return int(math.RoundToEven(x))
}

// RoundTo is Python's round(x, digits): correctly rounded, exact ties to even.
func RoundTo(x float64, digits int) float64 {
	if math.IsNaN(x) || math.IsInf(x, 0) {
		return x
	}
	v, _ := strconv.ParseFloat(strconv.FormatFloat(x, 'f', digits, 64), 64)
	return v
}

// Clip is np.clip for one value.
func Clip(x, lo, hi float64) float64 {
	return math.Min(math.Max(x, lo), hi)
}

// Linspace32 is np.linspace(start, stop, n) in float32 (endpoint included).
func Linspace32(start, stop float64, n int) []float32 {
	out := make([]float32, n)
	if n == 1 {
		out[0] = float32(start)
		return out
	}
	step := (stop - start) / float64(n-1)
	for i := range out {
		out[i] = float32(start + float64(i)*step)
	}
	if n > 1 {
		out[n-1] = float32(stop)
	}
	return out
}
