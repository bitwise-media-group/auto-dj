// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package demo

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/bitwise-media-group/auto-dj/internal/config"
	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/features"
	"github.com/bitwise-media-group/auto-dj/internal/pairs"
	"github.com/bitwise-media-group/auto-dj/internal/plan"
	"github.com/bitwise-media-group/auto-dj/internal/preview"
	"github.com/bitwise-media-group/auto-dj/internal/setlist"
	"github.com/bitwise-media-group/auto-dj/internal/tracks"
)

// Result is what a walkthrough printed, step by step, and the preview page it built.
type Result struct {
	Features, Plan, SetCheck, SetSuggested string
	Page                                   string
}

// Walkthrough renders the demo tracks into tracksDir and runs the whole pipeline on them,
// writing into outDir what each step prints (text fragments the docs include) and the set's
// preview page (outDir/preview). Rekordbox's analysis is replaced by the generator's own
// grid and phrases, and `apply --write` by putting the planned cues on the records.
func Walkthrough(tracksDir, outDir string, bpm float64) (*Result, error) {
	res, err := walkthrough(tracksDir, outDir, bpm)
	if err != nil {
		return nil, fmt.Errorf("demo: %w", err)
	}
	return res, nil
}

func walkthrough(tracksDir, outDir string, bpm float64) (*Result, error) {
	rs, err := Render(tracksDir)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return nil, err
	}
	out := &Result{}
	write := func(name, s string) error {
		return os.WriteFile(filepath.Join(outDir, name), []byte(strings.TrimRight(s, "\n")+"\n"), 0o644)
	}
	if err := write("tracks.md", trackTable(rs)); err != nil {
		return nil, err
	}

	// auto-dj features
	featDir := filepath.Join(tracksDir, "features")
	paths := make([]string, len(rs))
	for i, r := range rs {
		paths[i] = r.Path
	}
	res, err := features.ExtractMany(paths, featDir, 4)
	if err != nil {
		return nil, err
	}
	for _, x := range res {
		if strings.HasPrefix(x.Status, "error") {
			return nil, fmt.Errorf("features %s: %s", x.Path, x.Status)
		}
	}
	out.Features = fmt.Sprintf("%d files: ok %d", len(rs), len(rs))
	if err := write("features.txt", out.Features); err != nil {
		return nil, err
	}

	// auto-dj plan: freshly analysed tracks have no hot cues (nohot)
	recs := map[string]*tracks.Track{}
	ts := make([]*tracks.Track, len(rs))
	for i, r := range rs {
		t := &tracks.Track{ID: fmt.Sprint(r.No), Title: r.Title, Path: r.Path, BPM: r.Song.BPM, Length: r.Length,
			Beats: r.Beats, BNum: r.BNum, Phrases: r.Phrases, Mood: 1, Cues: []db.Cue{}, Category: "nohot", Local: true}
		if t.FB, err = features.PerBeat(featDir, r.Path, t.Beats, t.BPM); err != nil {
			return nil, err
		}
		ts[i], recs[t.ID] = t, t
	}
	items := plan.Make(ts, []string{"nohot"}, config.DefaultRules)
	out.Plan = plan.Summary(items)
	if err := write("plan.txt", out.Plan+"\nplan written to ~/.cache/auto-dj/plan.json"); err != nil {
		return nil, err
	}
	if err := write("plan.md", cueTable(items)); err != nil {
		return nil, err
	}

	// auto-dj apply --write: the planned cues land on the tracks, which become "auto"
	for i, it := range items {
		ts[i].Cues = cuesOf(it)
		ts[i].Category = "auto"
	}

	// auto-dj set: first as imported (one key clash), then in the suggested order
	order := make([]db.PlaylistTrack, len(rs))
	for i, r := range rs {
		order[i] = db.PlaylistTrack{No: r.No, ID: fmt.Sprint(r.No), Title: r.Title, BPM: r.Song.BPM, Key: r.Key}
	}
	first, err := setlist.Plan(Playlist, order, recs, pairs.New(), "", false)
	if err != nil {
		return nil, err
	}
	out.SetCheck = first.Report
	if err := write("set-check.txt", first.Report); err != nil {
		return nil, err
	}
	sug, err := setlist.Plan(Playlist, order, recs, pairs.New(), "suggested", false)
	if err != nil {
		return nil, err
	}
	out.SetSuggested = sug.Report
	if err := write("set-suggested.txt", sug.Report); err != nil {
		return nil, err
	}
	if out.Page, err = preview.Build(Playlist, sug.Order, sug.Actions, sug.Recs, filepath.Join(outDir, "preview"), true,
		bpm); err != nil {
		return nil, err
	}
	return out, nil
}

// cuesOf is a plan item as the cues `apply --write` leaves on the track.
func cuesOf(it plan.Item) []db.Cue {
	out := make([]db.Cue, 0, len(it.Hot)+len(it.Mem))
	for _, h := range it.Hot {
		c := db.Cue{Kind: h.Kind, T: float64(h.MS) / 1000, Name: h.Name}
		if h.Loop != nil {
			c.Out = float64(*h.OutMS) / 1000
			c.AL.Int64, c.AL.Valid = 1, true
			c.BL.Int64, c.BL.Valid = int64(*h.Loop)<<16+1, true
		}
		out = append(out, c)
	}
	for _, m := range it.Mem {
		out = append(out, db.Cue{Kind: 0, T: float64(m.MS) / 1000, Name: m.Name})
	}
	return out
}

func trackTable(rs []Rendered) string {
	var b strings.Builder
	b.WriteString("| #   | Title | Key | BPM | Length | File |\n| --- | ----- | --- | --- | ------ | ---- |\n")
	for _, r := range rs {
		fmt.Fprintf(&b, "| %d | %s | %s | %g | %s | `%s` |\n", r.No, r.Title, r.Key, r.Song.BPM,
			setlist.MinSec(r.Length), r.File())
	}
	return b.String()
}

func cueTable(items []plan.Item) string {
	var b strings.Builder
	b.WriteString("| Track | IN (A) | BRIDGE (B) | DROP (C) | OUT (D) | EMERGENCY (H) | Memory cues |\n")
	b.WriteString("| ----- | ------ | ---------- | -------- | ------- | ------------- | ----------- |\n")
	for _, it := range items {
		hot := map[string]int{}
		for _, h := range it.Hot {
			hot[h.Name] = h.Beat
		}
		cell := func(n string) string {
			if v, ok := hot[n]; ok {
				return fmt.Sprint(v)
			}
			return "—"
		}
		var mem []string
		for _, m := range it.Mem {
			mem = append(mem, fmt.Sprintf("%s %d", m.Name, m.Beat))
		}
		fmt.Fprintf(&b, "| %s | %s | %s | %s | %s | %s | %s |\n", it.Title, cell("IN"), cell("BRIDGE"), cell("DROP"),
			cell("OUT"), cell("EMERGENCY"), strings.Join(mem, " · "))
	}
	return b.String()
}
