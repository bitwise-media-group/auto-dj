// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package tracks assembles one record per track: beat grid, phrases, per-beat audio
// features and existing cues.
package tracks

import (
	"errors"
	"fmt"
	"math"
	"os"
	"regexp"
	"strings"
	"unicode"

	"github.com/bitwise-media-group/auto-dj/internal/anlz"
	"github.com/bitwise-media-group/auto-dj/internal/config"
	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/features"
	"github.com/bitwise-media-group/auto-dj/internal/num"
)

// Track is everything the rules know about one track.
type Track struct {
	ID       string
	Title    string
	Rating   int
	Path     string
	BPM      float64
	Length   float64 // djmdContent.Length (s), 0 when unknown
	Beats    []float64
	BNum     []int
	Phrases  []anlz.Phrase
	Mood     int
	Cues     []db.Cue
	Category string
	Local    bool // the audio file exists here (streaming tracks have none)
	// FB holds per-beat features (features package columns), nil without audio analysis.
	FB [][features.Cols]float64
}

// HasFB reports whether the track has audio features (the rules fall back to phrases).
func (t *Track) HasFB() bool { return t.FB != nil }

// Col returns feature column j of FB.
func (t *Track) Col(j int) []float64 {
	out := make([]float64, len(t.FB))
	for i, r := range t.FB {
		out[i] = r[j]
	}
	return out
}

// Build loads every track whose category is in want and that has Rekordbox analysis.
func Build(paths config.Paths, want ...string) ([]*Track, error) {
	rb, err := db.ReadCopy(paths.MasterDB())
	if err != nil {
		return nil, err
	}
	rows, cues, err := db.LoadTracksAndCues(rb)
	_ = rb.Close()
	if err != nil {
		return nil, err
	}
	auto, err := db.LoadLedger(paths.Ledger())
	if err != nil {
		return nil, err
	}
	wanted := map[string]bool{}
	for _, w := range want {
		wanted[w] = true
	}
	var out []*Track
	for _, r := range rows {
		cs := cues[r.ID]
		cat := db.Classify(r.Rating, cs, auto[r.ID])
		if !wanted[cat] || r.AnalysisDataPath == "" {
			continue
		}
		a, err := anlz.Load(paths.ShareDir(), r.AnalysisDataPath)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "  skipped %s: %v\n", r.Title, err)
			continue
		}
		if len(a.Beats) == 0 {
			continue
		}
		fp := config.MapPath(r.FolderPath)
		t := &Track{
			ID: r.ID, Title: r.Title, Rating: r.Rating, Path: fp, BPM: r.BPM, Length: r.Length,
			Beats: a.Beats, BNum: a.BNum, Phrases: a.Phrases, Mood: a.Mood, Cues: cs, Category: cat,
		}
		if fp != "" {
			if _, err := os.Stat(fp); err == nil {
				t.Local = true
			}
			fb, err := features.PerBeat(paths.FeatureDir(), fp, t.Beats, t.BPM)
			if err != nil {
				return nil, err
			}
			t.FB = fb
		}
		out = append(out, t)
	}
	return out, nil
}

// BeatOf is the 1-based beat nearest sec (np.argmin(abs(beats - sec)) + 1).
func BeatOf(beats []float64, sec float64) int {
	best := 0
	for i, b := range beats {
		if math.Abs(b-sec) < math.Abs(beats[best]-sec) {
			best = i
		}
	}
	return best + 1
}

// NormLevel is log-energy normalised so the track's loudest 5% sits at ~1.0, silence at 0.
func NormLevel(band []float64) []float64 {
	x := make([]float64, len(band))
	for i, v := range band {
		x[i] = math.Log10(v + 1e-9)
	}
	p := num.Percentile(x, 95)
	for i, v := range x {
		x[i] = num.Clip((v-p)+1, 0, 1.5)
	}
	return x
}

var (
	reBrackets = regexp.MustCompile(`\(.*?\)|\[.*?\]`)
	reNonAlnum = regexp.MustCompile(`[^a-z0-9 ]+`)
	reSpaces   = regexp.MustCompile(`\s+`)
)

// TitleStem turns "Don't Wake Up (Original Mix)" into "dont wake up": no mix names, no
// feat., no leading "the".
func TitleStem(x string) string {
	x = strings.ToLower(x)
	x = reBrackets.ReplaceAllString(x, " ")
	x = x[:featIndex(x)]
	x = strings.NewReplacer("'", "", "’", "").Replace(x)
	x = reNonAlnum.ReplaceAllString(x, " ")
	x = strings.TrimPrefix(config.Strip(x), "the ")
	return config.Strip(reSpaces.ReplaceAllString(x, " "))
}

// featIndex is where Python's re.split(r"\bfeat\.?\b|\bft\.?\b", x)[0] ends: the first
// "feat" or "ft" with a word boundary on both sides, where word characters are Unicode
// letters, numbers and '_' (Go's \b only knows ASCII).
func featIndex(x string) int {
	r := []rune(x)
	pos := 0 // byte offset of r[i]
	for i := range r {
		if i == 0 || !isWord(r[i-1]) {
			for _, w := range []string{"feat", "ft"} {
				n := len(w)
				if i+n <= len(r) && string(r[i:i+n]) == w && (i+n == len(r) || !isWord(r[i+n])) {
					return pos
				}
			}
		}
		pos += len(string(r[i]))
	}
	return len(x)
}

func isWord(r rune) bool {
	return r == '_' || unicode.IsLetter(r) || unicode.IsNumber(r)
}
