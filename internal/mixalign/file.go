// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package mixalign

import (
	"encoding/json"
	"fmt"
	"math"
	"os"

	"github.com/bitwise-media-group/auto-dj/internal/db"
)

// EditNote is the help the alignment file carries for whoever reviews it.
const EditNote = "Review before exporting. Each track's file starts at its 'cut' (h:mm:ss.sss into the " +
	"recording) and runs to the next kept track's cut. Edit a cut to move it, clear it (\"\") to leave the " +
	"track out, or give a no-audio track a cut to put it in. Re-runs keep this file (and its edits) unless " +
	"--realign is passed, which also keeps cuts edited by hand."

// File is alignment.json: the review step between aligning and exporting.
type File struct {
	History    string   `json:"history"`
	Date       string   `json:"date"`
	Recording  string   `json:"recording"`
	SampleRate int      `json:"sample_rate"`
	Channels   int      `json:"channels"`
	Samples    int64    `json:"samples"`
	Duration   string   `json:"duration"`
	Note       string   `json:"note"`
	Tracks     []*Entry `json:"tracks"`
}

// Load reads an alignment file.
func Load(path string) (*File, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var f File
	if err := json.Unmarshal(raw, &f); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &f, nil
}

// Save writes the alignment file.
func Save(path string, f *File) error {
	f.Note = EditNote
	return db.WriteJSON(path, f)
}

// Edited reports whether the entry's cut was changed by hand: it no longer says cut_sample
// (a cleared cut on a located track counts too).
func (e *Entry) Edited(sampleRate int) bool {
	if e.Cut == "" {
		return e.Located() && e.CutSample > 0
	}
	return e.Cut != FormatTime(float64(e.CutSample)/float64(sampleRate))
}

// Sample is where the entry's file starts: the hand-edited cut, else cut_sample.
func (e *Entry) Sample(sampleRate int) (int64, error) {
	if !e.Edited(sampleRate) {
		return e.CutSample, nil
	}
	s, err := ParseTime(e.Cut)
	if err != nil {
		return 0, fmt.Errorf("track %d (%s): cut: %w", e.No, e.Title, err)
	}
	return int64(math.Round(s * float64(sampleRate))), nil
}

// KeepEdits carries the cuts edited by hand in old over to a fresh alignment (matched by
// history position and track).
func KeepEdits(old, fresh *File) int {
	n := 0
	for i, o := range old.Tracks {
		if i >= len(fresh.Tracks) || fresh.Tracks[i].ID != o.ID || !o.Edited(old.SampleRate) {
			continue
		}
		e := fresh.Tracks[i]
		e.Cut = o.Cut
		e.Notes = append(e.Notes, "cut kept from the earlier alignment (edited by hand)")
		n++
	}
	return n
}

// Segment is one kept track's stretch of the recording, in samples [Start, End).
type Segment struct {
	*Entry
	Start, End int64
}

// Segments are the kept tracks' stretches in order: each runs to the next one's cut, the
// last to the end of the recording. Cuts must increase.
func (f *File) Segments() ([]Segment, error) {
	var out []Segment
	for _, e := range f.Tracks {
		if !e.Kept() {
			continue
		}
		s, err := e.Sample(f.SampleRate)
		if err != nil {
			return nil, err
		}
		if s < 0 || s >= f.Samples {
			return nil, fmt.Errorf("track %d (%s): cut %s is outside the recording", e.No, e.Title, e.Cut)
		}
		if n := len(out); n > 0 {
			if s <= out[n-1].Start {
				return nil, fmt.Errorf("track %d (%s): cut %s is not after track %d's (%s)", e.No, e.Title, e.Cut,
					out[n-1].No, out[n-1].Cut)
			}
			out[n-1].End = s
		}
		out = append(out, Segment{Entry: e, Start: s, End: f.Samples})
	}
	return out, nil
}
