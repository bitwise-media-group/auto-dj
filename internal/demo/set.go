// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package demo is the demo set: ten original house tracks rendered by internal/demo/synth,
// and the walkthrough built from them (`auto-dj demo`, and the docs). The tracks carry no
// third-party rights, and because the generator knows each track's beat grid, phrases and
// key, the walkthrough runs the real rules, set planner and preview without Rekordbox
// (docs/decisions/0014-generated-demo-set.md).
package demo

import (
	"fmt"
	"slices"

	"github.com/bitwise-media-group/auto-dj/internal/demo/synth"
)

// Playlist is the demo playlist's name.
const Playlist = "auto-dj demo"

// Track is one demo track.
type Track struct {
	No    int // position in the demo playlist (1-based)
	Title string
	Key   string // Rekordbox key notation, e.g. "F#m"
	Song  synth.Song
}

// File is the track's file name.
func (t Track) File() string { return fmt.Sprintf("%02d %s.aiff", t.No, t.Title) }

// The chord progressions, voiced for A minor (transposed per track).
var (
	am9      = []float64{57, 60, 64, 67, 71}
	am7      = []float64{57, 60, 64, 67}
	fmaj9    = []float64{53, 57, 60, 64, 67}
	fmaj7    = []float64{53, 57, 60, 64}
	cmaj7    = []float64{55, 60, 64, 67, 71}
	em7      = []float64{55, 59, 62, 64, 67}
	dm9      = []float64{53, 57, 60, 62, 64}
	g6       = []float64{55, 59, 62, 64, 67}
	gmaj     = []float64{55, 59, 62, 67}
	cmaj7b   = []float64{55, 60, 64, 71}
	progDeep = [4]synth.Chord{ch(33, am9), ch(29, fmaj9), ch(36, cmaj7), ch(28, em7)} // i9 VI9 III7 v7
	progWalk = [4]synth.Chord{ch(33, am7), ch(38, dm9), ch(31, g6), ch(36, cmaj7b)}   // i7 iv9 VII6 III7
	progLift = [4]synth.Chord{ch(33, am9), ch(31, g6), ch(29, fmaj7), ch(31, gmaj)}   // i9 VII6 VI7 VII
	progHold = [4]synth.Chord{ch(33, am7), ch(33, am9), ch(38, dm9), ch(28, em7)}     // i7 i9 iv9 v7
	progRise = [4]synth.Chord{ch(29, fmaj7), ch(31, gmaj), ch(33, am7), ch(33, am9)}  // VI7 VII i7 i9
)

func ch(root float64, notes []float64) synth.Chord { return synth.Chord{Root: root, Notes: notes} }

func hit(step, interval, length, gain float64) synth.Hit {
	return synth.Hit{Step: step, Interval: interval, Len: length, Gain: gain}
}

// lowSun is the first track's hand-written lead (A minor).
var lowSun = []synth.Note{
	{Step: 0, Midi: 76, Len: 2}, {Step: 3, Midi: 79, Len: 1}, {Step: 4, Midi: 81, Len: 3}, {Step: 8, Midi: 79, Len: 2},
	{Step: 11, Midi: 76, Len: 1}, {Step: 12, Midi: 74, Len: 4},
	{Step: 16, Midi: 72, Len: 2}, {Step: 19, Midi: 74, Len: 1}, {Step: 20, Midi: 76, Len: 3}, {Step: 24, Midi: 72, Len: 2},
	{Step: 27, Midi: 69, Len: 1}, {Step: 28, Midi: 72, Len: 4},
	{Step: 32, Midi: 76, Len: 2}, {Step: 35, Midi: 79, Len: 1}, {Step: 36, Midi: 83, Len: 3}, {Step: 40, Midi: 81, Len: 2},
	{Step: 43, Midi: 79, Len: 1}, {Step: 44, Midi: 76, Len: 4},
	{Step: 48, Midi: 74, Len: 2}, {Step: 51, Midi: 76, Len: 1}, {Step: 52, Midi: 79, Len: 3}, {Step: 56, Midi: 76, Len: 4},
	{Step: 60, Midi: 74, Len: 2}, {Step: 62, Midi: 71, Len: 2},
}

// tone is a lead note as an index into the bar's chord voicing (sorted low to high; past
// the top it wraps an octave up), played an octave above the chord.
type tone struct{ step, idx, len float64 }

var (
	motifArp = []tone{
		{0, 0, 1.5}, {2, 1, 1.5}, {4, 2, 1.5}, {6, 3, 1.5}, {8, 4, 1.5}, {10, 3, 1.5}, {12, 2, 1.5}, {14, 1, 1.5},
	}
	motifCall  = []tone{{0, 4, 3}, {3, 3, 1}, {6, 2, 2}, {10, 4, 2}, {14, 3, 2}}
	motifLong  = []tone{{0, 4, 6}, {8, 3, 4}, {12, 2, 4}}
	motifPluck = []tone{{0, 2, 1}, {3, 4, 1}, {6, 3, 1}, {8, 2, 1}, {11, 4, 1}, {14, 3, 2}}
)

// toneLead spells a per-bar motif over a progression.
func toneLead(prog [4]synth.Chord, motif []tone) []synth.Note {
	out := make([]synth.Note, 0, len(prog)*len(motif))
	for bar, c := range prog {
		ns := slices.Sorted(slices.Values(c.Notes))
		for _, m := range motif {
			i := int(m.idx)
			midi := ns[i%len(ns)] + 12*float64(i/len(ns)) + 12
			out = append(out, synth.Note{Step: float64(bar*16) + m.step, Midi: midi, Len: m.len})
		}
	}
	return out
}

var (
	bassOffbeat = []synth.Hit{
		hit(2, 0, 1.6, 0.55), hit(6, 0, 1.6, 0.55), hit(10, 0, 1.6, 0.55), hit(14, 12, 1.6, 0.55), hit(7, 7, 0.8, 0.35),
	}
	bassRolling = []synth.Hit{
		hit(2, 0, 0.9, 0.5), hit(3, 12, 0.9, 0.4), hit(6, 0, 0.9, 0.5), hit(7, 12, 0.9, 0.4),
		hit(10, 0, 0.9, 0.5), hit(11, 12, 0.9, 0.4), hit(14, 0, 0.9, 0.5), hit(15, 7, 0.9, 0.4),
	}
	bassSync = []synth.Hit{
		hit(3, 0, 2, 0.55), hit(6, 0, 1.5, 0.5), hit(10, 0, 2, 0.55), hit(13, 7, 1, 0.4), hit(14, 12, 1.5, 0.45),
	}
	bassLong = []synth.Hit{hit(2, 0, 3, 0.55), hit(6, 0, 3, 0.55), hit(10, 7, 3, 0.5), hit(14, 0, 1.6, 0.55)}

	stabsDeep   = []float64{0, 3, 6, 10, 13}
	stabsOrgan  = []float64{2, 6, 10, 14}
	stabsDotted = []float64{0, 6, 12}
	stabsPush   = []float64{3, 7, 11, 14}

	standard = synth.Layout{Intro: 16, Groove: 16, Main: 16, Break: 16, Drop: 32, Outro: 16}
	longIn   = synth.Layout{Intro: 32, Groove: 16, Main: 16, Break: 16, Drop: 32, Outro: 16}
	short    = synth.Layout{Intro: 16, Groove: 16, Main: 8, Break: 16, Drop: 32, Outro: 16}
)

// transpose is the shift from A minor to the key's tonic, kept within -6..+5 semitones so
// every track sits in the same register.
func transpose(tonic int) float64 { return float64((tonic-9+18)%12 - 6) }

// Tracks is the demo playlist in its imported order. Its keys run round the Camelot wheel
// (8A → 12A), except that "Paper Lanterns" is filed third: a clash the key check finds and
// the suggested order fixes.
var Tracks = []Track{
	{1, "Low Sun", "Am", synth.Song{BPM: 124, Transpose: transpose(9), Seed: 1, Prog: progDeep, Lead: lowSun,
		Bass: bassOffbeat, Stabs: stabsDeep, Layout: standard}},
	{2, "Glasshouse", "Am", synth.Song{BPM: 124, Transpose: transpose(9), Seed: 2, Prog: progWalk,
		Lead: toneLead(progWalk, motifCall), Bass: bassRolling, Stabs: stabsOrgan, StabCut: 2200, Layout: standard}},
	{3, "Paper Lanterns", "F#m", synth.Song{BPM: 125, Transpose: transpose(6), Seed: 7, Prog: progRise,
		Lead: toneLead(progRise, motifArp), Bass: bassOffbeat, Stabs: stabsPush, Layout: standard}},
	{4, "Night Bus", "Em", synth.Song{BPM: 123, Transpose: transpose(4), Seed: 3, Prog: progLift,
		Lead: toneLead(progLift, motifPluck), Bass: bassSync, Stabs: stabsDeep, StabCut: 1500, Layout: longIn}},
	{5, "Copper Wire", "Em", synth.Song{BPM: 124, Transpose: transpose(4), Seed: 4, Prog: progHold,
		Lead: toneLead(progHold, motifLong), Bass: bassLong, Stabs: stabsDotted, Layout: standard}},
	{6, "Slow Orbit", "Bm", synth.Song{BPM: 124, Transpose: transpose(11), Seed: 5, Prog: progRise,
		Lead: toneLead(progRise, motifCall), Bass: bassRolling, Stabs: stabsPush, StabCut: 2000, Layout: short}},
	{7, "Tidewater", "Bm", synth.Song{BPM: 125, Transpose: transpose(11), Seed: 6, Prog: progDeep,
		Lead: toneLead(progDeep, motifArp), Bass: bassOffbeat, Stabs: stabsOrgan, Layout: longIn}},
	{8, "Northbound", "F#m", synth.Song{BPM: 125, Transpose: transpose(6), Seed: 8, Prog: progWalk,
		Lead: toneLead(progWalk, motifPluck), Bass: bassSync, Stabs: stabsDeep, StabCut: 2400, Layout: standard}},
	{9, "Afterglow", "C#m", synth.Song{BPM: 126, Transpose: transpose(1), Seed: 9, Prog: progLift,
		Lead: toneLead(progLift, motifLong), Bass: bassLong, Stabs: stabsDotted, Layout: short}},
	{10, "Last Train Home", "C#m", synth.Song{BPM: 126, Transpose: transpose(1), Seed: 10, Prog: progHold,
		Lead: toneLead(progHold, motifCall), Bass: bassOffbeat, Stabs: stabsDeep, StabCut: 1600, Layout: standard}},
}
