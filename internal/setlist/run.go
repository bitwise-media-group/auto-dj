// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package setlist

import (
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/bitwise-media-group/adj/internal/config"
	"github.com/bitwise-media-group/adj/internal/db"
	"github.com/bitwise-media-group/adj/internal/num"
	"github.com/bitwise-media-group/adj/internal/pairs"
	"github.com/bitwise-media-group/adj/internal/text"
	"github.com/bitwise-media-group/adj/internal/tracks"
)

// ErrOrder means a hand-picked order doesn't list every track exactly once.
var ErrOrder = errors.New("order must list every track number exactly once")

// Result is a planned set.
type Result struct {
	Report  string
	Order   []db.PlaylistTrack
	Actions []Action
	Recs    map[string]*tracks.Track
	Clashes int
	Cache   *pairs.Cache
}

// Run loads a playlist, checks keys, suggests an order and plans the set cues. orderSpec is
// "", "suggested" or a comma-separated track-number order (1,3,2,...).
func Run(paths config.Paths, playlist, orderSpec string, freeStart bool) (*Result, error) {
	rb, err := db.ReadCopy(paths.MasterDB())
	if err != nil {
		return nil, err
	}
	order, err := db.LoadPlaylist(rb, playlist)
	var titles []db.IDTitle
	if err == nil {
		titles, err = db.Titles(rb)
	}
	if cerr := rb.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return nil, err
	}
	if orderSpec != "" && orderSpec != "suggested" { // a hand-picked order is checked as given
		if order, err = pickOrder(order, orderSpec); err != nil {
			return nil, err
		}
	}
	lines, clashes := keyReport(playlist, order)
	items := make([]OrderItem, len(order))
	for i, x := range order {
		items[i] = OrderItem{x.Key, x.BPM}
	}
	suggested, cost := SuggestOrder(items, !freeStart)
	if clashes > 0 {
		lines = append(lines, "", fmt.Sprintf("%d key clash(es). Suggested order (key cost %d):", clashes, cost))
		for n, k := range suggested {
			lines = append(lines, fmt.Sprintf("  %2d. %s  %s", n+1, text.PadLeft(orQ(order[k].Key), 4), order[k].Title))
		}
		lines = append(lines, "Plan with order 'suggested' (or a list like 1,3,2,...) once you agree.")
	}
	if orderSpec == "suggested" {
		re := make([]db.PlaylistTrack, len(suggested))
		for i, k := range suggested {
			re[i] = order[k]
		}
		order = re
	}
	recs, cache, err := loadAndHarvest(paths, titles)
	if err != nil {
		return nil, err
	}
	acts := PlanSet(order, recs, cache)
	lines = append(lines, "", "Set cues (beat @ m:ss; existing = kept as is, new = empty slot, "+
		"replace = slot overwritten (old cue saved in the transition cache), clear = removed from the last track):")
	for _, x := range acts {
		lines = append(lines, reportTrack(x, recs[x.ID])...)
	}
	return &Result{strings.Join(lines, "\n"), order, acts, recs, clashes, cache}, nil
}

// loadAndHarvest loads every analysed track and the transition cache, and records every E/G
// pair in the library before anything changes.
func loadAndHarvest(paths config.Paths, titles []db.IDTitle) (map[string]*tracks.Track, *pairs.Cache, error) {
	all, err := tracks.Build(paths, "manual", "auto", "mik", "nohot", "other")
	if err != nil {
		return nil, nil, err
	}
	recs := map[string]*tracks.Track{}
	for _, t := range all {
		recs[t.ID] = t
	}
	cache, err := pairs.Load(paths.Transitions())
	if err != nil {
		return nil, nil, err
	}
	cache.Harvest(all, pairs.NewResolver(titles))
	return recs, cache, pairs.Save(cache, paths.Transitions())
}

// pickOrder reorders the playlist by a comma-separated track-number list (1,3,2,...).
func pickOrder(order []db.PlaylistTrack, spec string) ([]db.PlaylistTrack, error) {
	var idx []int
	for _, v := range strings.Split(spec, ",") {
		n, err := strconv.Atoi(strings.TrimSpace(v))
		if err != nil {
			return nil, fmt.Errorf("%w: %q is not a track number", ErrOrder, v)
		}
		idx = append(idx, n-1)
	}
	if len(idx) != len(order) {
		return nil, ErrOrder
	}
	for i, v := range slices.Sorted(slices.Values(idx)) {
		if v != i {
			return nil, ErrOrder
		}
	}
	re := make([]db.PlaylistTrack, len(idx))
	for i, k := range idx {
		re[i] = order[k]
	}
	return re, nil
}

// keyReport is the key check of each neighbouring pair, and the number of clashes.
func keyReport(playlist string, order []db.PlaylistTrack) ([]string, int) {
	lines := make([]string, 0, 3+len(order))
	lines = append(lines, fmt.Sprintf("%s: %d tracks", playlist, len(order)), "",
		"Key check (Mixed In Key chart: same / Camelot +-1 / relative; energy boosts +-1 and +-2 semitones):")
	clashes := 0
	for _, k := range CheckOrder(order) {
		mark := "ok"
		if !k.OK {
			clashes++
			mark = "XX"
		}
		lines = append(lines, fmt.Sprintf("  %s  %s -> %s %s -> %s %s", mark,
			text.PadLeft(orQ(order[k.I].Key), 4), text.PadRight(orQ(order[k.J].Key), 4),
			text.PadRight(text.Truncate(order[k.I].Title, 34), 34), text.PadRight(text.Truncate(order[k.J].Title, 34), 34),
			k.Desc))
	}
	return lines, clashes
}

func orQ(s string) string {
	if s == "" {
		return "?"
	}
	return s
}

// at is beat b's position as m:ss.
func at(t *tracks.Track, b int) string {
	sec := t.Beats[min(max(b, 1), len(t.Beats))-1]
	return MinSec(sec)
}

// MinSec formats seconds as m:ss (Python's f"{int(s // 60)}:{int(s % 60):02d}").
func MinSec(sec float64) string {
	m := int(floorDiv(sec, 60))
	s := int(sec - floorDiv(sec, 60)*60)
	return fmt.Sprintf("%d:%02d", m, s)
}

func floorDiv(a, b float64) float64 {
	q := a / b
	if q < 0 {
		return float64(int(q) - 1)
	}
	return float64(int(q))
}

func reportTrack(x Action, t *tracks.Track) []string {
	lines := []string{"  " + x.Title}
	if t == nil {
		return lines
	}
	for _, s := range []struct {
		name string
		v    *Slot
	}{{"E", x.E}, {"G", x.G}} {
		if v := s.v; v != nil {
			was := ""
			if v.Old != nil && v.Status == "replace" {
				was = fmt.Sprintf(" (was '%s' @ beat %d)", v.Old.Name, v.Old.Beat)
			}
			lines = append(lines, fmt.Sprintf("     %s %s beat %4d @ %s  %s%s", s.name, text.PadRight(v.Name, 22),
				v.Beat, at(t, v.Beat), v.Status, was))
		}
	}
	bs := x.BassSwap
	if bs != nil && bs.Beat == 0 {
		lines = append(lines, "     BASS SWAP IN: none: "+bs.Why)
	}
	for _, m := range x.Markers {
		why := ""
		if m.Name == "BASS SWAP IN" && bs != nil && bs.Why != "new" && bs.Why != "existing" {
			why = " (" + bs.Why + ")"
		}
		lines = append(lines, fmt.Sprintf("     %s beat %4d @ %s  %s%s", text.PadRight(m.Name, 24), m.Beat, at(t, m.Beat),
			m.Status, why))
	}
	if ex := x.Exit; ex != nil {
		src := "own cue"
		if ex.Side != "out" {
			src = "from the next track's cue"
		}
		lines = append(lines, fmt.Sprintf("     leaves the mix: %s at beat %d @ %s (%s)", ex.Name, ex.A, at(t, ex.A), src))
	}
	for _, w := range x.Warnings {
		lines = append(lines, "     ! "+w)
	}
	return lines
}

// RecordWritten remembers this set's pairs after a write (G on track i, E + BASS SWAP on
// track i+1).
func RecordWritten(cache *pairs.Cache, playlist string, order []db.PlaylistTrack, actions []Action,
	recs map[string]*tracks.Track) {
	for i := 0; i+1 < len(order); i++ {
		a, b := actions[i], actions[i+1]
		t, u := recs[order[i].ID], recs[order[i+1].ID]
		if t == nil || u == nil || a.G == nil || b.E == nil {
			continue
		}
		ms := func(r *tracks.Track, x int) *int {
			v := num.Round(r.Beats[min(max(x, 1), len(r.Beats))-1] * 1000)
			return &v
		}
		v := pairs.Vals{GMS: ms(t, a.G.Beat), EMS: ms(u, b.E.Beat)}
		if b.BassSwap != nil && b.BassSwap.Beat != 0 {
			v.BassSwapMS = ms(u, b.BassSwap.Beat)
		}
		cache.Record(order[i].ID, order[i].Title, order[i+1].ID, order[i+1].Title, "set:"+playlist, v)
	}
}
