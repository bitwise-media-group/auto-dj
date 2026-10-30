// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package plan turns rule output into a concrete, reviewable write plan (JSON).
package plan

import (
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"strings"

	"github.com/bitwise-media-group/adj/internal/config"
	"github.com/bitwise-media-group/adj/internal/db"
	"github.com/bitwise-media-group/adj/internal/num"
	"github.com/bitwise-media-group/adj/internal/rules"
	"github.com/bitwise-media-group/adj/internal/tracks"
)

// Order is the hot cue order the flags check.
var Order = []string{"IN", "BRIDGE", "DROP", "OUT", "EMERGENCY"}

// HotCue is a planned hot cue. Loop and OutMS are set on EMERGENCY only.
type HotCue struct {
	Kind  int    `json:"kind"`
	Slot  string `json:"slot"`
	Name  string `json:"name"`
	Beat  int    `json:"beat"`
	MS    int    `json:"ms"`
	Loop  *int   `json:"loop,omitempty"`
	OutMS *int   `json:"out_ms,omitempty"`
}

// MemCue is a planned memory cue.
type MemCue struct {
	Name string `json:"name"`
	Beat int    `json:"beat"`
	MS   int    `json:"ms"`
}

// Item is one track's plan.
type Item struct {
	ID     string   `json:"id"`
	Title  string   `json:"title"`
	Path   string   `json:"path"`
	BPM    float64  `json:"bpm"`
	NBeats int      `json:"nbeats"`
	Audio  bool     `json:"audio"`
	Hot    []HotCue `json:"hot"`
	Mem    []MemCue `json:"mem"`
	Flags  []string `json:"flags"`
}

// MS is beat b's position in milliseconds (clamped to the grid).
func MS(beats []float64, b int) int {
	return num.Round(beats[min(max(b, 1), len(beats))-1] * 1000)
}

// Track plans one track.
func Track(t *tracks.Track, R config.Rules) Item {
	hot := rules.HotCues(t, R)
	mem := rules.MemoryCues(t, hot, R)
	B := t.Beats
	nb := len(B)
	ms := func(b int) int { return MS(B, b) }
	it := Item{ID: t.ID, Title: t.Title, Path: t.Path, BPM: t.BPM, NBeats: nb, Audio: t.HasFB(),
		Hot: []HotCue{}, Mem: []MemCue{}, Flags: []string{}}
	for _, hs := range config.HotTemplate {
		b, ok := hot[hs.Name]
		if !ok {
			continue
		}
		c := HotCue{Kind: config.Kind[hs.Slot], Slot: hs.Slot, Name: hs.Name, Beat: b, MS: ms(b)}
		if hs.Name == "EMERGENCY" {
			end := b + config.EmergencyLoopBeats
			loop, out := config.EmergencyLoopBeats, 0
			if end <= nb {
				out = ms(end)
			} else {
				out = num.Round((B[nb-1] + 60/t.BPM) * 1000)
			}
			c.Loop, c.OutMS = &loop, &out
		}
		it.Hot = append(it.Hot, c)
	}
	it.Mem = append(it.Mem, MemCue{"START", mem.Start, ms(mem.Start)})
	for _, b := range mem.Drops {
		it.Mem = append(it.Mem, MemCue{"DROP", b, ms(b)})
	}
	if mem.BassSwap != 0 {
		it.Mem = append(it.Mem, MemCue{"BASS SWAP", mem.BassSwap, ms(mem.BassSwap)})
	}
	if _, ok := hot["BRIDGE"]; !ok {
		it.Flags = append(it.Flags, "no bridge")
	}
	if mem.BassSwap == 0 {
		it.Flags = append(it.Flags, "no bass swap")
	}
	if !t.HasFB() {
		it.Flags = append(it.Flags, "phrase analysis only")
	}
	var pos []int
	for _, k := range Order {
		if b, ok := hot[k]; ok {
			pos = append(pos, b)
		}
	}
	if !slices.IsSorted(pos) {
		it.Flags = append(it.Flags, "cue order")
	}
	return it
}

// Make plans every track whose category is in categories.
func Make(ts []*tracks.Track, categories []string, R config.Rules) []Item {
	out := []Item{}
	for _, t := range ts {
		if slices.Contains(categories, t.Category) {
			out = append(out, Track(t, R))
		}
	}
	return out
}

// Summary counts the flags (most common first, ties in first-seen order).
func Summary(p []Item) string {
	counts := map[string]int{}
	var seen []string
	drops := 0
	for _, x := range p {
		for _, f := range x.Flags {
			if counts[f] == 0 {
				seen = append(seen, f)
			}
			counts[f]++
		}
		for _, m := range x.Mem {
			if m.Name == "DROP" {
				drops++
			}
		}
	}
	slices.SortStableFunc(seen, func(a, b string) int { return counts[b] - counts[a] })
	lines := make([]string, 0, len(seen)+2)
	lines = append(lines, fmt.Sprintf("%d tracks planned", len(p)))
	for _, f := range seen {
		lines = append(lines, fmt.Sprintf("  %s: %d", f, counts[f]))
	}
	lines = append(lines, fmt.Sprintf("  memory DROP cues: %d", drops))
	return strings.Join(lines, "\n")
}

// Save writes the plan as JSON.
func Save(p []Item, path string) error {
	return db.WriteJSON(path, p)
}

// Load reads a plan written by Save (or by the Python version).
func Load(path string) ([]Item, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var p []Item
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return p, nil
}

// ToDB converts plan items into what db.ApplyPlan writes.
func ToDB(p []Item) []db.PlanTrack {
	out := make([]db.PlanTrack, 0, len(p))
	for _, x := range p {
		t := db.PlanTrack{ID: x.ID, Title: x.Title}
		for _, h := range x.Hot {
			c := db.PlanHot{Kind: h.Kind, Name: h.Name, MS: h.MS}
			if h.Loop != nil {
				c.Loop = *h.Loop
			}
			if h.OutMS != nil {
				c.OutMS = *h.OutMS
			}
			t.Hot = append(t.Hot, c)
		}
		for _, m := range x.Mem {
			t.Mem = append(t.Mem, db.PlanMem{Name: m.Name, MS: m.MS})
		}
		out = append(out, t)
	}
	return out
}
