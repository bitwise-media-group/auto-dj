// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package pairs is the transition cache: every E/G pair seen in the library or written by
// `set`, so a pair can be restored when the two tracks meet again in another playlist (a
// track has only one E and one G, so sets overwrite each other).
//
// File: <backup dir>/transitions.json  {"pairs": {"<out_id>><in_id>": entry}}
// entry: out_id, out_title, in_id, in_title, g_ms, e_ms, bass_swap_ms, source, updated, history[]
package pairs

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/pmezard/go-difflib/difflib"

	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/num"
	"github.com/bitwise-media-group/auto-dj/internal/tracks"
)

// History is an entry's earlier values.
type History struct {
	GMS        *int   `json:"g_ms"`
	EMS        *int   `json:"e_ms"`
	BassSwapMS *int   `json:"bass_swap_ms"`
	Source     string `json:"source"`
	Updated    string `json:"updated"`
}

// Entry is one A -> B transition: G on A, E and BASS SWAP on B (milliseconds).
type Entry struct {
	OutID      string    `json:"out_id"`
	OutTitle   string    `json:"out_title"`
	InID       string    `json:"in_id"`
	InTitle    string    `json:"in_title"`
	GMS        *int      `json:"g_ms"`
	EMS        *int      `json:"e_ms"`
	BassSwapMS *int      `json:"bass_swap_ms"`
	Source     string    `json:"source"`
	Updated    string    `json:"updated"`
	History    []History `json:"history"`
}

// Cache is the transition cache file.
type Cache struct {
	Pairs map[string]*Entry `json:"pairs"`
}

// New returns an empty cache.
func New() *Cache { return &Cache{Pairs: map[string]*Entry{}} }

// Load reads the cache (empty when the file doesn't exist).
func Load(path string) (*Cache, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return New(), nil
	}
	if err != nil {
		return nil, err
	}
	c := New()
	if err := json.Unmarshal(raw, c); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if c.Pairs == nil {
		c.Pairs = map[string]*Entry{}
	}
	return c, nil
}

// Save writes the cache.
func Save(c *Cache, path string) error { return db.WriteJSON(path, c) }

// Key is the pair's key in the cache.
func Key(outID, inID string) string { return outID + ">" + inID }

// Get returns the pair's entry, or nil.
func (c *Cache) Get(outID, inID string) *Entry { return c.Pairs[Key(outID, inID)] }

// Vals are the positions to record (nil = leave as is).
type Vals struct {
	GMS, EMS, BassSwapMS *int
}

// Record sets g_ms / e_ms / bass_swap_ms for a pair; changed values (by more than 20 ms) push
// the old entry to history.
func (c *Cache) Record(outID, outTitle, inID, inTitle, source string, v Vals) {
	k := Key(outID, inID)
	now := time.Now().Format("2006-01-02T15:04:05")
	cur := c.Pairs[k]
	if cur == nil {
		cur = &Entry{OutID: outID, OutTitle: outTitle, InID: inID, InTitle: inTitle, Source: source,
			Updated: now, History: []History{}}
		c.Pairs[k] = cur
	}
	type field struct{ cur, val **int }
	var changed []field
	for _, f := range []field{{&cur.GMS, &v.GMS}, {&cur.EMS, &v.EMS}, {&cur.BassSwapMS, &v.BassSwapMS}} {
		if *f.val == nil {
			continue
		}
		if *f.cur == nil || abs(**f.cur-**f.val) > 20 {
			changed = append(changed, f)
		}
	}
	if len(changed) == 0 {
		return
	}
	for _, f := range changed {
		if *f.cur != nil {
			cur.History = append(cur.History, History{cur.GMS, cur.EMS, cur.BassSwapMS, cur.Source, cur.Updated})
			break
		}
	}
	for _, f := range changed {
		val := **f.val
		*f.cur = &val
	}
	cur.Source, cur.Updated = source, now
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// Ratio is difflib.SequenceMatcher(None, a, b).ratio() over characters.
func Ratio(a, b string) float64 {
	return difflib.NewMatcher(chars(a), chars(b)).Ratio()
}

func chars(s string) []string {
	out := make([]string, 0, len(s))
	for _, r := range s {
		out = append(out, string(r))
	}
	return out
}

// Resolver maps hand-typed cue names ('RAJ', 'LOST HAWK') to track IDs.
type Resolver struct {
	titles []db.IDTitle
	stems  []string
	byID   map[string]string
}

// NewResolver indexes the library's titles (in table order, which breaks ties).
func NewResolver(titles []db.IDTitle) *Resolver {
	r := &Resolver{titles: titles, byID: map[string]string{}}
	for _, t := range titles {
		r.stems = append(r.stems, tracks.TitleStem(t.Title))
		r.byID[t.ID] = t.Title
	}
	return r
}

// Title is the track's title.
func (r *Resolver) Title(id string) string { return r.byID[id] }

// Resolve returns the ID of the track the cue name means, or "".
func (r *Resolver) Resolve(name string) string {
	n := tracks.TitleStem(name)
	if len(n) < 3 || n == "start" {
		return ""
	}
	best, bestR := "", 0.0
	for i, t := range r.titles {
		s := r.stems[i]
		q := 1.0
		if s != n {
			q = Ratio(n, s)
		}
		if q > bestR {
			best, bestR = t.ID, q
		}
	}
	if bestR >= 0.75 {
		return best
	}
	return ""
}

// Harvest records every E/G cue in the library that names another track. It returns the
// number of pairs touched.
func (c *Cache) Harvest(recs []*tracks.Track, r *Resolver) int {
	n := 0
	for _, t := range recs {
		for _, cue := range t.Cues {
			if cue.Kind != 6 && cue.Kind != 8 {
				continue
			}
			other := r.Resolve(cue.Name)
			if other == "" || other == t.ID {
				continue
			}
			ms := num.Round(cue.T * 1000)
			if cue.Kind == 6 { // E on this track: other -> this
				c.Record(other, r.Title(other), t.ID, r.Title(t.ID), "library", Vals{EMS: &ms})
			} else { // G on this track: this -> other
				c.Record(t.ID, r.Title(t.ID), other, r.Title(other), "library", Vals{GMS: &ms})
			}
			n++
		}
	}
	return n
}
