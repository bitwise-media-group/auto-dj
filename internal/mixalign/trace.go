// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package mixalign

import (
	"fmt"
	"math"
	"slices"
)

// piece is a stretch of the recording, from recording second from, where a track played
// straight through (between loops or hot cue jumps).
type piece struct {
	Fit
	from float64
}

// fitAt is the track's mapping at recording second rec: the last piece starting at or before
// it (the first piece reaches back to the track's start, the last one on to its end).
func (t *track) fitAt(rec float64) Fit {
	f := t.pieces[0].Fit
	for _, p := range t.pieces[1:] {
		if p.from > rec {
			break
		}
		f = p.Fit
	}
	return f
}

// last is the mapping of the track's last piece.
func (t *track) last() Fit { return t.pieces[len(t.pieces)-1].Fit }

// candidate is a place a probe may have played: where it starts in the recording (s), the
// implied offset (s) and its correlation.
type candidate struct {
	pos, off, score float64
}

// Path states: before the track is heard, a probe heard at a candidate, a probe not heard
// in between (it carries the offset it came from), after the track has gone.
const (
	stLead = iota
	stReal
	stMid
	stTrail
)

type state struct {
	kind     int
	off, pos float64
	seen     bool    // the path has been on the global fit
	match    float64 // the candidate's correlation (stReal)
	score    float64
	prev     *state
}

// trace follows the track through the recording: a probe every TraceBeats beats (8 s
// without a grid) is matched within LocalSec of the global fit, keeping its best few
// candidates, then a path through them (Viterbi) collects the most correlation while paying
// JumpPenalty for every change of offset. The path must pass through the global fit (the
// best-agreed one), or it may wander off on a bar-shifted lookalike. Probes before the track
// is heard and after it has gone score a fixed 0.85 x NotFound, so weak matches under the
// other track in a transition drop out rather than pull the path; a probe nobody can hear in
// between (a breakdown, a mashup, a fader down) scores 0.55 x NotFound and keeps the offset
// it came with. Straight runs of the path become pieces; the first reaches back to the
// track's start and the last on to its end, so a transition is mapped from the solo playing
// next to it. Loops and jumps inside a transition are not resolved.
func (a *aligner) trace(t *track) {
	g := *t.global
	starts := a.traceStarts(t)
	p := pathScores{tau: NotFound * 0.85, tauMid: NotFound * 0.55, global: g.Offset}
	layers := make([][]*state, 0, len(starts))
	prev := []*state{{kind: stLead}}
	for _, s := range starts {
		prev = p.step(prev, a.candidates(t, s, g))
		layers = append(layers, prev)
	}
	var end *state
	for _, s := range prev {
		if end == nil || (s.seen && !end.seen) || (s.seen == end.seen && s.score > end.score) {
			end = s
		}
	}
	path := make([]*state, len(layers))
	for k, s := len(layers)-1, end; k >= 0 && s != nil; k, s = k-1, s.prev {
		path[k] = s
	}
	a.piecesOf(t, starts, path)
}

// pathScores are the trace's scores: before / after the track (tau), not heard in between
// (tauMid), and the global fit's offset the path must pass through.
type pathScores struct {
	tau, tauMid, global float64
}

func (p pathScores) jump(o, off float64) float64 {
	if math.Abs(o-off) > Continuous {
		return -JumpPenalty
	}
	return 0
}

// step is the next probe's states from the previous probe's and its candidates: the best
// path to each (kind, offset, seen).
func (p pathScores) step(prev []*state, cands []candidate) []*state {
	var layer []*state
	put := func(s *state) {
		i := slices.IndexFunc(layer, func(x *state) bool {
			return x.kind == s.kind && x.seen == s.seen && math.Abs(x.off-s.off) <= Continuous/2
		})
		switch {
		case i < 0:
			layer = append(layer, s)
		case s.score > layer[i].score:
			layer[i] = s
		}
	}
	for _, ps := range prev {
		switch ps.kind {
		case stLead:
			put(&state{kind: stLead, score: ps.score + p.tau, prev: ps})
		case stReal, stMid:
			put(&state{kind: stMid, off: ps.off, pos: ps.pos, seen: ps.seen, score: ps.score + p.tauMid, prev: ps})
		}
		put(&state{kind: stTrail, seen: ps.seen, score: ps.score + p.tau, prev: ps})
	}
	for _, c := range cands {
		for _, ps := range prev {
			gain := 0.0
			switch ps.kind {
			case stTrail:
				continue
			case stReal:
				if c.pos <= ps.pos {
					continue
				}
				gain = p.jump(ps.off, c.off)
			case stMid:
				gain = p.jump(ps.off, c.off)
			}
			put(&state{kind: stReal, off: c.off, pos: c.pos, seen: ps.seen || math.Abs(c.off-p.global) <= 2*Continuous,
				match: c.score, score: ps.score + gain + c.score, prev: ps})
		}
	}
	return layer
}

// traceStarts are the trace's probe starts (track frames).
func (a *aligner) traceStarts(t *track) []int {
	n := len(t.env[0])
	var out []int
	if r := t.in.Rec; r != nil && len(r.Beats) > 0 {
		for b := 1; b <= len(r.Beats); b += TraceBeats {
			if s := int(math.Round(r.Beats[b-1] * fps)); s+a.m <= n {
				out = append(out, s)
			}
		}
	} else {
		for s := 0; s+a.m <= n; s += a.m {
			out = append(out, s)
		}
	}
	return out
}

// candidates are the best few places (at least a quarter second apart) the probe starting
// at track frame p plays within LocalSec of where the global fit puts it.
func (a *aligner) candidates(t *track, p int, g Fit) []candidate {
	const keep = 16
	m := int(float64(a.m) / g.R)
	x0 := max(0, int((g.Rec(float64(p)/fps)-LocalSec)*fps))
	x1 := min(len(a.env[0]), int((g.Rec(float64(p)/fps)+LocalSec)*fps)+m)
	if x1-x0 < m+1 {
		return nil
	}
	var avg []float64
	q := make([]float64, m)
	for k, ch := range a.env {
		for j := range q {
			q[j], _ = at(t.env[k], float64(p)+float64(j)*g.R)
		}
		if !normalise(q) {
			continue
		}
		x := newCorrelator(ch[x0:x1]).ncc(q)
		if avg == nil {
			avg = make([]float64, len(x))
		}
		for L, v := range x {
			avg[L] += v / float64(len(a.env))
		}
	}
	type peak struct {
		L int
		v float64
	}
	var peaks []peak
	for L := range avg {
		if (L == 0 || avg[L] >= avg[L-1]) && (L == len(avg)-1 || avg[L] > avg[L+1]) && avg[L] > 0 {
			peaks = append(peaks, peak{L, avg[L]})
		}
	}
	slices.SortFunc(peaks, func(x, y peak) int { return int(math.Copysign(1, y.v-x.v)) })
	sep := int(math.Round(0.25 * fps))
	var out []candidate
	for _, pk := range peaks {
		if len(out) == keep {
			break
		}
		pos := float64(x0+pk.L) / fps
		if slices.ContainsFunc(out, func(c candidate) bool { return math.Abs(c.pos-pos)*fps < float64(sep) }) {
			continue
		}
		out = append(out, candidate{pos: pos, off: pos - float64(p)/fps/g.R, score: pk.v})
	}
	return out
}

// piecesOf turns the traced path into pieces, each refitted on its own probes.
func (a *aligner) piecesOf(t *track, starts []int, path []*state) {
	g := *t.global
	type run struct {
		off    float64
		probes []probe
		from   float64
		match  float64 // summed
	}
	var runs []*run
	heard := 0
	for k, s := range path {
		if s == nil || s.kind != stReal {
			continue
		}
		heard++
		p := starts[k]
		q := make([][]float64, len(t.env))
		for c, ch := range t.env {
			q[c] = ch[p : p+a.m]
		}
		if n := len(runs); n == 0 || math.Abs(runs[n-1].off-s.off) > Continuous {
			runs = append(runs, &run{off: s.off, from: s.pos})
		}
		r := runs[len(runs)-1]
		r.probes = append(r.probes, probe{p, q})
		r.match += s.match
	}
	t.heard = 0
	for _, r := range runs {
		if r.match/float64(len(r.probes)) >= RunScore {
			t.heard = max(t.heard, len(r.probes))
		}
	}
	if len(starts) > 0 {
		t.entry.Matched = math.Round(float64(heard)/float64(len(starts))*1e3) / 1e3
	}
	if len(runs) == 0 {
		t.pieces = []piece{{g, math.Inf(-1)}}
		return
	}
	t.pieces = nil
	for i, r := range runs {
		pc := 0.0
		for _, p := range r.probes {
			pc += float64(p.start)
		}
		pc /= float64(len(r.probes))
		f := a.refine(r.probes, pc, r.off+pc/fps/g.R, g.R)
		from := r.from
		if i == 0 {
			from = math.Inf(-1)
		} else if prev := t.pieces[i-1].Fit; math.Abs(prev.Track(from)-f.Track(from)) > 0.5 {
			// (a change of tempo also starts a piece: the track time runs on)
			t.entry.Notes = append(t.entry.Notes, fmt.Sprintf("jumps at %s from %s to %s of the track (a loop or hot cue)",
				FormatTime(from), FormatTime(prev.Track(from)), FormatTime(f.Track(from))))
		}
		t.pieces = append(t.pieces, piece{f, from})
	}
}
