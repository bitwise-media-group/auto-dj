// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package num

import (
	"math"
	"testing"
)

// Reference values come from numpy 2.5 (see the expressions in each comment).
func TestSumFloat32Pairwise(t *testing.T) {
	x := make([]float32, 1000) // (np.arange(1000, dtype=float32) * float32(0.1)) ** 1.5
	for i := range x {
		v := float32(i) * float32(0.1)
		x[i] = float32(math.Pow(float64(v), 1.5))
	}
	for _, c := range []struct {
		n    int
		want float32
	}{{1000, 399500.125}, {100, 1249.1384}, {5, 0.53836453}} {
		if got := Sum(x[:c.n]); got != c.want {
			t.Errorf("Sum(x[:%d]) = %v, want %v", c.n, got, c.want)
		}
	}
}

func TestPercentileAndMean(t *testing.T) {
	y := make([]float64, 257) // np.sin(np.arange(257)) * 3.7
	for i := range y {
		y[i] = math.Sin(float64(i)) * 3.7
	}
	for _, c := range []struct {
		a    []float64
		q    float64
		want float64
	}{{y, 95, 3.652542774941139}, {y, 90, 3.4981252708182433}, {y[:10], 50, 1.023491212608004}} {
		if got := Percentile(c.a, c.q); math.Abs(got-c.want) > 1e-15 {
			t.Errorf("Percentile(%d, %v) = %v, want %v", len(c.a), c.q, got, c.want)
		}
	}
	if got := Mean(y); math.Abs(got-0.0065082293479743905) > 1e-17 {
		t.Errorf("Mean = %v", got)
	}
	l := make([]float64, 100) // np.log10(np.arange(1, 101) + 1e-9)
	for i := range l {
		l[i] = math.Log10(float64(i+1) + 1e-9)
	}
	if got := Percentile(l, 95); math.Abs(got-1.9779509866809528) > 1e-15 {
		t.Errorf("Percentile(log) = %v", got)
	}
}

func TestHann(t *testing.T) {
	want := []float64{0, 0.5, 1, 0.5, 0}
	for i, v := range Hann(5) {
		if math.Abs(v-want[i]) > 1e-16 {
			t.Fatalf("Hann(5) = %v", Hann(5))
		}
	}
	w := Hann(1024) // np.hanning(1024).astype(float32)[[1, 100, 511]]
	for i, c := range map[int]float32{1: 9.430768841411918e-06, 100: 0.09138035029172897, 511: 0.999997615814209} {
		if float32(w[i]) != c {
			t.Errorf("Hann(1024)[%d] = %v, want %v", i, float32(w[i]), c)
		}
	}
	if p := HannPeriodic(4); p[0] != 0 || math.Abs(p[2]-1) > 1e-16 || len(p) != 4 {
		t.Errorf("HannPeriodic(4) = %v", p)
	}
}

func TestRounding(t *testing.T) {
	if Round(1.5) != 2 || Round(2.5) != 2 || Round(-0.5) != 0 || Round(2.6) != 3 {
		t.Error("Round is not half-to-even")
	}
	if RoundTo(2.675, 2) != 2.67 || RoundTo(0.125, 2) != 0.12 || RoundTo(1.25, 1) != 1.2 {
		t.Error("RoundTo does not match Python's round(x, n)")
	}
}

func TestArgFirst(t *testing.T) {
	a := []float64{3, 1, 1, 5, 5}
	if Argmin(a) != 1 || Argmax(a) != 3 || Argmin(nil) != -1 {
		t.Error("ties must go to the first element")
	}
	m, _ := MinBy([]int{4, 2, 7, 2}, func(a, b int) bool { return a < b })
	if m != 2 {
		t.Error("MinBy")
	}
}
