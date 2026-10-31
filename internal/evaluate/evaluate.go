// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package evaluate scores the rules against the user's own hand-placed cues (the
// 'manual' tracks).
package evaluate

import (
	"fmt"
	"strings"

	"github.com/bitwise-media-group/auto-dj/internal/config"
	"github.com/bitwise-media-group/auto-dj/internal/rules"
	"github.com/bitwise-media-group/auto-dj/internal/text"
	"github.com/bitwise-media-group/auto-dj/internal/tracks"
)

// names maps hot cue kinds to the template names they are scored as, in report order.
var names = []struct {
	Kind int
	Name string
}{{1, "IN"}, {2, "BRIDGE"}, {3, "DROP"}, {5, "OUT"}, {9, "EMERGENCY"}}

func nameOf(kind int) string {
	for _, n := range names {
		if n.Kind == kind {
			return n.Name
		}
	}
	return ""
}

// CueScore counts how close the rules came to one hot cue.
type CueScore struct {
	N, Exact, Within16, Within32, Missing int
}

// Report is the evaluation result.
type Report struct {
	Cues                     map[string]CueScore
	DropHit, DropMissed      int
	DropExtra                int
	BassSwapN, BassSwapExact int
	BassSwapWithin16         int
	Rows                     []Row // with verbose only
}

// Row is one track's cue-by-cue comparison (verbose).
type Row struct {
	Title string
	Cells []string
}

// Score runs the rules on every manual track and compares them with the user's cues.
func Score(ts []*tracks.Track, R config.Rules, verbose bool) Report {
	res := map[string][]*int{}
	rep := Report{Cues: map[string]CueScore{}}
	var bassSwap []int
	var rows []Row
	for _, t := range ts {
		if t.Category != "manual" {
			continue
		}
		hot := rules.HotCues(t, R)
		row := scoreHot(t, hot, res)
		if t.HasFB() {
			if d, ok := scoreMemory(t, rules.MemoryCues(t, hot, R), &rep); ok {
				bassSwap = append(bassSwap, d)
			}
		}
		rows = append(rows, Row{t.Title, row})
	}
	for _, n := range names {
		rep.Cues[n.Name] = summarise(res[n.Name])
	}
	rep.BassSwapN = len(bassSwap)
	for _, x := range bassSwap {
		if x == 0 {
			rep.BassSwapExact++
		}
		if x <= 16 {
			rep.BassSwapWithin16++
		}
	}
	if verbose {
		rep.Rows = rows
	}
	return rep
}

// scoreHot records predicted - placed (nil: not predicted) per hot cue in res and returns
// the verbose row ("IN:33/33 ...").
func scoreHot(t *tracks.Track, hot rules.Hot, res map[string][]*int) []string {
	var row []string
	for _, c := range t.Cues {
		n := nameOf(c.Kind)
		if n == "" || c.Name != n {
			continue
		}
		bi := tracks.BeatOf(t.Beats, c.T)
		pr, ok := hot[n]
		if !ok {
			res[n] = append(res[n], nil)
			row = append(row, fmt.Sprintf("%s:%d/None", n, bi))
			continue
		}
		d := pr - bi
		res[n] = append(res[n], &d)
		row = append(row, fmt.Sprintf("%s:%d/%d", n, bi, pr))
	}
	return row
}

// scoreMemory adds the memory DROP hits, misses and extras to rep, and returns the distance
// from the user's nearest BASS SWAP to the predicted one (ok false when the user has none).
func scoreMemory(t *tracks.Track, mem rules.Memory, rep *Report) (int, bool) {
	md, pd := map[int]bool{}, map[int]bool{}
	var mbs []int
	for _, c := range t.Cues {
		switch {
		case c.Kind == 0 && c.Name == "DROP":
			md[tracks.BeatOf(t.Beats, c.T)] = true
		case c.Kind == 0 && c.Name == "BASS SWAP":
			mbs = append(mbs, tracks.BeatOf(t.Beats, c.T))
		}
	}
	for _, b := range mem.Drops {
		pd[b] = true
	}
	near := func(a int, set map[int]bool) bool {
		for b := range set {
			if abs(a-b) <= 1 {
				return true
			}
		}
		return false
	}
	hit, extra := 0, len(pd)
	for a := range md {
		if near(a, pd) {
			hit++
		}
	}
	for b := range pd {
		if near(b, md) {
			extra--
		}
	}
	rep.DropHit += hit
	rep.DropMissed += len(md) - hit
	rep.DropExtra += extra
	if len(mbs) == 0 {
		return 0, false
	}
	p := mem.BassSwap
	if p == 0 {
		p = -999
	}
	best := abs(mbs[0] - p)
	for _, x := range mbs[1:] {
		best = min(best, abs(x-p))
	}
	return best, true
}

func summarise(v []*int) CueScore {
	s := CueScore{N: len(v)}
	for _, x := range v {
		if x == nil {
			s.Missing++
			continue
		}
		if *x == 0 {
			s.Exact++
		}
		if abs(*x) <= 16 {
			s.Within16++
		}
		if abs(*x) <= 32 {
			s.Within32++
		}
	}
	return s
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// Format renders the report as the evaluate command prints it.
func Format(rep Report) string {
	out := make([]string, 0, 3+len(names)+len(rep.Rows))
	out = append(out, fmt.Sprintf("%-12s %3s %6s %6s %6s %5s", "cue", "n", "exact", "<=16", "<=32", "none"))
	for _, n := range names {
		r := rep.Cues[n.Name]
		out = append(out, fmt.Sprintf("%-12s %3d %6d %6d %6d %5d",
			n.Name, r.N, r.Exact, r.Within16, r.Within32, r.Missing))
	}
	out = append(out, fmt.Sprintf("memory DROP  hit %d  missed %d  extra %d", rep.DropHit, rep.DropMissed, rep.DropExtra))
	out = append(out, fmt.Sprintf("BASS SWAP    n %d  exact %d  <=16 %d",
		rep.BassSwapN, rep.BassSwapExact, rep.BassSwapWithin16))
	for _, r := range rep.Rows {
		out = append(out, "  "+text.PadRight(text.Truncate(r.Title, 34), 34)+" "+strings.Join(r.Cells, " "))
	}
	return strings.Join(out, "\n")
}
