// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package preview renders audio previews of each transition in a set, plus a set-list page.
//
// The full-set mix (set.mp3) plays the original tracks end to end: each track from its E (the
// first from START) to where it leaves the mix. When A reaches G, B starts at E,
// time-stretched to the playing tempo (key kept) and fading in over 8 beats. Until the bass
// swap B's bass is filtered out; at the bass swap the bass moves to B (A is low-cut). A leaves
// the mix on its exit (setlist.Action.Exit): on FILTER a low-pass sweep to silence over 8
// beats, then a fade out over 4 beats; on CUT an immediate cut; with neither, a fade out over
// 8 beats from the bass swap. Once A has gone B returns to its own tempo. With a fixed set
// tempo (Build's bpm) every track plays at that tempo throughout instead, key kept. The last
// track plays to its end. The bass swap point is the planned BASS SWAP, else 32 beats after E.
//
// Every track follows its jumps: on reaching a JUMP memory cue playback goes to the JUMP hot
// cue (JumpRoute).
//
// Each transition clip (01-02.mp3, ...) is the same mix of just A and B: A from 8 beats
// before G, ending 8 beats after A has left. Needs ffmpeg.
package preview

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/num"
	"github.com/bitwise-media-group/auto-dj/internal/review"
	"github.com/bitwise-media-group/auto-dj/internal/setlist"
	"github.com/bitwise-media-group/auto-dj/internal/tracks"
)

// Mix parameters (beats unless noted).
const (
	SR              = 44100
	Lead            = 8
	FadeIn          = 8
	FadeOut         = 8
	Tail            = 8
	FilterBeats     = 8 // FILTER exit: low-pass sweep to silence, then a fade out
	FilterFadeBeats = 4
	LowCutHz        = 180
	GapS            = 1.0 // silence (s) where a track's audio is missing
	SwapXFS         = 0.03
	SplitXFS        = 0.02
	JumpXFS         = 0.01
	CutRampS        = 0.005
)

type pageTrack struct {
	N        int      `json:"n"`
	Title    string   `json:"title"`
	Key      string   `json:"key"`
	BPM      float64  `json:"bpm"`
	E        []any    `json:"E"`
	G        []any    `json:"G"`
	BassSwap *string  `json:"bass_swap"`
	Exit     []any    `json:"exit"`
	Markers  [][]any  `json:"markers"`
	Warnings []string `json:"warnings"`
}

type pagePair struct {
	I             int       `json:"i"`
	File          string    `json:"file"`
	Dur           float64   `json:"dur"`
	BOffset       float64   `json:"b_offset"`
	FadeIn        []float64 `json:"fade_in"`
	SwapT         *float64  `json:"swap_t"`
	FadeOut       []float64 `json:"fade_out"`
	Exit          string    `json:"exit"`
	FilterT       []float64 `json:"filter_t"`
	Sync          bool      `json:"sync"`
	Jumps         [][]any   `json:"jumps"`
	BeatS         float64   `json:"beat_s"`
	BPM           float64   `json:"bpm"`
	Tempo         float64   `json:"tempo"`
	G             int       `json:"g"`
	E             int       `json:"e"`
	SwapB         int       `json:"swap_b"`
	EstimatedSwap bool      `json:"estimated_swap"`
	GTime         string    `json:"g_time"`
	ETime         string    `json:"e_time"`
	SwapTime      string    `json:"swap_time"`
}

// pageNoPair is a transition with no clip.
type pageNoPair struct {
	I      int     `json:"i"`
	File   *string `json:"file"`
	Reason string  `json:"reason"`
}

type pageMix struct {
	File   string  `json:"file"`
	Dur    float64 `json:"dur"`
	Tracks []any   `json:"tracks"`
}

type pageData struct {
	Playlist string      `json:"playlist"`
	BPM      float64     `json:"bpm,omitempty"` // the set's fixed tempo
	Tracks   []pageTrack `json:"tracks"`
	Pairs    []any       `json:"pairs"`
	Mix      *pageMix    `json:"mix"`
}

func exists(p string) bool {
	_, err := os.Stat(p)
	return p != "" && err == nil
}

// Build renders every transition (and, with mix, the whole set as set.mp3) into outDir and
// writes index.html + set.json. bpm > 0 plays everything at that fixed tempo (key kept); 0
// beat-matches each incoming track to the outgoing one. It returns the page's path.
func Build(playlist string, order []db.PlaylistTrack, actions []setlist.Action, recs map[string]*tracks.Track,
	outDir string, mix bool, bpm float64) (string, error) {
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return "", err
	}
	var err error
	data := pageData{Playlist: playlist, BPM: max(bpm, 0), Tracks: []pageTrack{}, Pairs: []any{}}
	for i, x := range order {
		data.Tracks = append(data.Tracks, newPageTrack(i, x, actions[i], recs[x.ID]))
	}
	for i := 0; i+1 < len(order); i++ {
		a, b := recs[order[i].ID], recs[order[i+1].ID]
		A, B := actions[i], actions[i+1]
		if a == nil || b == nil || A.G == nil || B.E == nil || !exists(a.Path) || !exists(b.Path) {
			data.Pairs = append(data.Pairs, pageNoPair{I: i, Reason: "audio file not found (streaming track?)"})
			continue
		}
		var p pagePair
		if p, err = renderPair(order[i:i+2], actions[i:i+2], recs, outDir, i, bpm); err != nil {
			return "", err
		}
		data.Pairs = append(data.Pairs, p)
	}
	if mix {
		if data.Mix, err = renderMix(order, actions, recs, outDir, bpm); err != nil {
			return "", err
		}
	}
	js, err := db.MarshalJSON(data)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(outDir, "set.json"), js, 0o644); err != nil {
		return "", err
	}
	compact, err := json.Marshal(data)
	if err != nil {
		return "", err
	}
	page := strings.ReplaceAll(review.Template("setlist.html"), "__DATA__", string(compact))
	page = strings.ReplaceAll(page, "__TITLE__", playlist)
	out := filepath.Join(outDir, "index.html")
	return out, os.WriteFile(out, []byte(page), 0o644)
}

func at(t *tracks.Track, b int) string { return setlist.MinSec(beatTime(t, b)) }

// newPageTrack is a track's line on the set-list page (cue positions as m:ss).
func newPageTrack(i int, x db.PlaylistTrack, act setlist.Action, t *tracks.Track) pageTrack {
	pt := pageTrack{N: i + 1, Title: x.Title, Key: x.Key, BPM: x.BPM, Markers: [][]any{}, Warnings: act.Warnings}
	if t == nil {
		return pt
	}
	if act.E != nil {
		pt.E = []any{act.E.Name, at(t, act.E.Beat), act.E.Status}
	}
	liveG := act.G != nil && act.G.Status != "clear"
	if liveG {
		pt.G = []any{act.G.Name, at(t, act.G.Beat), act.G.Status}
	}
	if act.BassSwap != nil && act.BassSwap.Beat != 0 {
		s := at(t, act.BassSwap.Beat)
		pt.BassSwap = &s
	}
	if act.Exit != nil && liveG {
		pt.Exit = []any{act.Exit.Name, at(t, act.Exit.A)}
	}
	for _, m := range act.Markers {
		pt.Markers = append(pt.Markers, []any{m.Name, at(t, m.Beat), m.Status})
	}
	return pt
}

// renderMix renders the full-set mix as set.mp3 (nil when no track has local audio).
func renderMix(order []db.PlaylistTrack, actions []setlist.Action, recs map[string]*tracks.Track,
	outDir string, bpm float64) (*pageMix, error) {
	segs := MixTimeline(order, actions, recs, 0, bpm)
	if !slices.ContainsFunc(segs, func(s *Seg) bool { return !s.Missing }) {
		return nil, nil
	}
	if _, err := RenderSet(segs, filepath.Join(outDir, "set.mp3")); err != nil {
		return nil, err
	}
	dur, ts := MixInfo(segs)
	return &pageMix{File: "set.mp3", Dur: dur, Tracks: ts}, nil
}

func renderPair(order []db.PlaylistTrack, actions []setlist.Action, recs map[string]*tracks.Track, outDir string,
	i int, bpm float64) (pagePair, error) {
	a, b := recs[order[0].ID], recs[order[1].ID]
	A, B := actions[0], actions[1]
	sa, sb := PairTimeline(order, actions, recs, bpm)
	play := a.BPM // the tempo B is matched to
	if bpm > 0 {
		play = bpm
	}
	name := fmt.Sprintf("%02d-%02d.mp3", i+1, i+2)
	if _, err := RenderSet([]*Seg{sa, sb}, filepath.Join(outDir, name)); err != nil {
		return pagePair{}, err
	}
	r := func(v float64) float64 { return num.RoundTo(v, 2) }
	swapB := B.E.Beat + 32
	if B.Swap != nil && *B.Swap > B.E.Beat {
		swapB = *B.Swap
	}
	fadeIn := []float64{r(sb.Start), r(sb.Start)}
	if sb.FadeIn != nil {
		fadeIn = []float64{r(sb.FadeIn[0]), r(sb.FadeIn[1])}
	}
	xs := sa.Exit.Xs
	p := pagePair{
		I: i, File: name, Dur: r(sb.End), BOffset: r(sb.Start), FadeIn: fadeIn, SwapT: r2(sa.SwapT),
		FadeOut: []float64{r(xs[0]), r(xs[len(xs)-1])}, Exit: sa.Exit.Kind, Sync: sb.Sync, Jumps: [][]any{},
		BeatS: num.RoundTo(60/play, 4), BPM: play, Tempo: num.RoundTo(play/b.BPM, 4),
		G: A.G.Beat, E: B.E.Beat, SwapB: swapB, EstimatedSwap: sa.EstimatedSwap,
		GTime: setlist.MinSec(beatTime(a, A.G.Beat)), ETime: setlist.MinSec(beatTime(b, B.E.Beat)),
		SwapTime: setlist.MinSec(beatTime(b, swapB)),
	}
	if sa.Exit.Kind == "filter" {
		p.FilterT = []float64{r(xs[0]), r(xs[1])} // the sweep
	}
	for _, j := range sa.Jumps {
		p.Jumps = append(p.Jumps, []any{"a", r(j)})
	}
	for _, j := range sb.Jumps {
		p.Jumps = append(p.Jumps, []any{"b", r(j)})
	}
	return p, nil
}
