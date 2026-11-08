// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package features

import (
	"bytes"
	"encoding/binary"
	"math"
	"math/rand"
	"slices"
	"testing"
)

// TestFramesOfMatchesFrameFeatures checks the chunked computation against the one-shot one,
// flux columns included, for lengths around the chunk edges.
func TestFramesOfMatchesFrameFeatures(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for _, n := range []int{NFFT, NFFT + 1, 4*Hop + NFFT, 4*Hop + NFFT + 7, 9000, 20000} {
		y := make([]float32, n)
		for i := range y {
			y[i] = float32(math.Sin(float64(i)*0.07) + 0.3*rng.NormFloat64())
		}
		var b bytes.Buffer
		if err := binary.Write(&b, binary.LittleEndian, y); err != nil {
			t.Fatal(err)
		}
		want, err := FrameFeatures(y)
		if err != nil {
			t.Fatal(err)
		}
		got, err := framesOf(&b, 4*Hop)
		if err != nil {
			t.Fatal(err)
		}
		if !slices.Equal(got, want) {
			t.Errorf("n=%d: %d frames, want %d (or values differ)", n, len(got), len(want))
		}
	}
}
