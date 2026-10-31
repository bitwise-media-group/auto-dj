// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package demo

import (
	"slices"
	"testing"

	"github.com/bitwise-media-group/auto-dj/internal/anlz"
	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/setlist"
)

func TestAnalysePhrases(t *testing.T) {
	tr := Tracks[0] // standard layout: 112 bars at 124 BPM
	step := 44100 * 60 / 124.0 / 4
	frames := int(112*16*step) + 2*44100
	r := analyse(tr, "x.aiff", frames)
	want := []anlz.Phrase{
		{Beat: 1, Label: "Intro"}, {Beat: 65, Label: "Up"}, {Beat: 129, Label: "Chorus"}, {Beat: 193, Label: "Down"},
		{Beat: 257, Label: "Chorus"}, {Beat: 321, Label: "Chorus"}, {Beat: 385, Label: "Outro"},
	}
	if !slices.Equal(r.Phrases, want) {
		t.Fatalf("phrases = %v", r.Phrases)
	}
	if len(r.Beats) != 452 || r.Beats[4] != 4*60/124.0 || r.BNum[4] != 1 || r.BNum[7] != 4 {
		t.Fatalf("grid: %d beats, beat 5 at %v (bar beat %d)", len(r.Beats), r.Beats[4], r.BNum[4])
	}
}

// The imported order has exactly one key clash, which the suggested order resolves.
func TestKeyClashIsPlanted(t *testing.T) {
	order := make([]db.PlaylistTrack, len(Tracks))
	items := make([]setlist.OrderItem, len(Tracks))
	for i, tr := range Tracks {
		if tr.No != i+1 {
			t.Fatalf("track %q is numbered %d at position %d", tr.Title, tr.No, i+1)
		}
		if _, ok := setlist.ToCamelot(tr.Key); !ok {
			t.Fatalf("%s: unknown key %q", tr.Title, tr.Key)
		}
		order[i] = db.PlaylistTrack{No: tr.No, ID: tr.Title, Title: tr.Title, BPM: tr.Song.BPM, Key: tr.Key}
		items[i] = setlist.OrderItem{Key: tr.Key, BPM: tr.Song.BPM}
	}
	clashes := func(o []db.PlaylistTrack) int {
		n := 0
		for _, k := range setlist.CheckOrder(o) {
			if !k.OK {
				n++
			}
		}
		return n
	}
	if n := clashes(order); n != 1 {
		t.Fatalf("imported order has %d clashes, want 1", n)
	}
	sug, _ := setlist.SuggestOrder(items, true)
	re := make([]db.PlaylistTrack, len(sug))
	for i, k := range sug {
		re[i] = order[k]
	}
	if n := clashes(re); n != 0 {
		t.Fatalf("suggested order has %d clashes", n)
	}
}

func TestToneLeadFollowsTheChords(t *testing.T) {
	notes := toneLead(progWalk, motifCall)
	if len(notes) != 4*len(motifCall) {
		t.Fatalf("%d notes", len(notes))
	}
	// bar 2 (Dm9, voiced 53 57 60 62 64): index 4 is E4, an octave up
	if n := notes[len(motifCall)]; n.Step != 16 || n.Midi != 76 {
		t.Fatalf("first note of bar 2 = %+v", n)
	}
}
