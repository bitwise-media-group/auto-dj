// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package testtrack builds synthetic tracks for tests: no Rekordbox library needed.
package testtrack

import (
	"github.com/bitwise-media-group/adj/internal/anlz"
	"github.com/bitwise-media-group/adj/internal/db"
	"github.com/bitwise-media-group/adj/internal/tracks"
)

// Options shape a synthetic track (zero values take the defaults).
type Options struct {
	NB        int     // beats (640)
	BPM       float64 // 128
	Breakdown [2]int  // no-bass stretch [start, end) (257, 321)
	Outro     int     // Outro phrase start (577)
	BassEnd   int     // first beat of the bassless tail (625)
}

// Synth is a typical 4/4 extended mix: intro (no bass) 1-64, groove, breakdown, drop, outro.
func Synth(o Options) *tracks.Track {
	if o.NB == 0 {
		o.NB = 640
	}
	if o.BPM == 0 {
		o.BPM = 128
	}
	if o.Breakdown == [2]int{} {
		o.Breakdown = [2]int{257, 321}
	}
	if o.Outro == 0 {
		o.Outro = 577
	}
	if o.BassEnd == 0 {
		o.BassEnd = 625
	}
	nb := o.NB
	t := &tracks.Track{
		ID: "1", Title: "Synthetic (Extended Mix)", Path: "/x.aiff", BPM: o.BPM, Category: "mik",
		Beats: make([]float64, nb), BNum: make([]int, nb), FB: make([][6]float64, nb), Cues: []db.Cue{},
	}
	for i := range nb {
		t.Beats[i] = float64(i) * 60 / o.BPM
		t.BNum[i] = i%4 + 1
	}
	t.Phrases = []anlz.Phrase{
		{Beat: 1, Label: "Intro"}, {Beat: 65, Label: "Up"}, {Beat: 129, Label: "Chorus"}, {Beat: 193, Label: "Chorus"},
		{Beat: o.Breakdown[0], Label: "Down"}, {Beat: 289, Label: "Up"}, {Beat: o.Breakdown[1], Label: "Chorus"},
		{Beat: 385, Label: "Chorus"}, {Beat: 449, Label: "Chorus"}, {Beat: 513, Label: "Chorus"},
		{Beat: o.Outro, Label: "Outro"},
	}
	for i := range nb {
		sub := 1.0
		if i < 64 || (i >= o.Breakdown[0]-1 && i < o.Breakdown[1]-1) || i >= o.BassEnd-1 {
			sub = 1e-4 // intro, breakdown and tail: no bass
		}
		t.FB[i] = [6]float64{sub, sub, 1, 1, 1, 1}
	}
	return t
}

// Cue is a cue on beat b of t.
func Cue(t *tracks.Track, b int, name string, kind int) db.Cue {
	return db.Cue{Kind: kind, T: t.Beats[b-1], Name: name}
}
