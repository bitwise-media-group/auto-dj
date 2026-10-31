// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package synth

import (
	"math"
	"slices"
	"sync"
	"testing"
)

// short is a song small enough to render in a test (under the race detector too): 26 fast bars
// with a two-note chord, one stab per bar and two lead notes.
func short() Song {
	c := Chord{Root: 33, Notes: []float64{57, 64}}
	return Song{
		BPM: 300, Seed: 3, Prog: [4]Chord{c, c, c, c},
		Lead:   []Note{{Step: 0, Midi: 76, Len: 2}, {Step: 20, Midi: 72, Len: 2}},
		Bass:   []Hit{{Step: 2, Len: 1.6, Gain: 0.55}},
		Stabs:  []float64{0},
		Layout: Layout{Intro: 2, Groove: 9, Main: 1, Break: 5, Drop: 1, Outro: 8},
	}
}

var rendered = sync.OnceValue(func() []float32 { return Render(short()) })

func TestRenderIsDeterministic(t *testing.T) {
	if !slices.Equal(rendered(), Render(short())) {
		t.Fatal("two renders of the same song differ")
	}
}

func TestRenderLengthAndLevel(t *testing.T) {
	pcm := rendered()
	frames := len(pcm) / 2
	step := SR * 60 / 300 / 4
	want := int(26*16*step) + int(2*SR)
	if frames != want {
		t.Fatalf("frames = %d, want %d", frames, want)
	}
	peak := 0.0
	for _, v := range pcm {
		if math.IsNaN(float64(v)) {
			t.Fatal("NaN sample")
		}
		peak = math.Max(peak, math.Abs(float64(v)))
	}
	if math.Abs(peak-0.89) > 1e-6 {
		t.Fatalf("peak = %v, want 0.89 (-1 dBFS)", peak)
	}
}

func TestSections(t *testing.T) {
	got := Layout{Intro: 16, Groove: 16, Main: 16, Break: 16, Drop: 32, Outro: 16}.Of()
	want := Sections{Groove: 16, Main: 32, Break: 48, Drop: 64, Outro: 96, End: 112}
	if got != want {
		t.Fatalf("Of() = %+v, want %+v", got, want)
	}
}
