// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package preview

import (
	"math"
	"slices"

	"github.com/bitwise-media-group/auto-dj/internal/config"
	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/tracks"
)

// BeatTime is the source second of (possibly fractional / out-of-range) beat b on t's grid.
func BeatTime(t *tracks.Track, b float64) float64 {
	B := t.Beats
	spb := 60 / math.Max(t.BPM, 1)
	if b < 1 {
		return B[0] + (b-1)*spb
	}
	if b > float64(len(B)) {
		return B[len(B)-1] + (b-float64(len(B)))*spb
	}
	i := int(math.Floor(b)) - 1
	frac := b - math.Floor(b)
	nxt := B[i] + spb
	if i+1 < len(B) {
		nxt = B[i+1]
	}
	return B[i] + frac*(nxt-B[i])
}

func beatTime(t *tracks.Track, b int) float64 { return BeatTime(t, float64(b)) }

// Piece is a stretch of source seconds [S0, S1) played in one go.
type Piece struct{ S0, S1 float64 }

// Route is a track's playback from its start point, through its jumps: playback seconds
// (0 = the start point, at the track's own tempo) <-> source seconds. The first piece
// extends back before the start point and the last past the end of the file as needed.
type Route struct {
	Pieces []Piece
}

// Dur is the playback length.
func (r *Route) Dur() float64 {
	s := 0.0
	for _, p := range r.Pieces {
		s += p.S1 - p.S0
	}
	return s
}

// Jumps are the playback seconds of each jump.
func (r *Route) Jumps() []float64 {
	out := make([]float64, 0, len(r.Pieces)-1)
	q := 0.0
	for _, p := range r.Pieces[:len(r.Pieces)-1] {
		q += p.S1 - p.S0
		out = append(out, q)
	}
	return out
}

// Play is the playback second where source second src plays first at or after `after`;
// ok is false when it never plays.
func (r *Route) Play(src, after float64) (float64, bool) {
	q, last := 0.0, len(r.Pieces)-1
	for k, p := range r.Pieces {
		if p.S0 <= src && (src < p.S1 || k == last) && q+src-p.S0 >= after-1e-6 {
			return q + src - p.S0, true
		}
		q += p.S1 - p.S0
	}
	return 0, false
}

// SpanPiece is a piece playing from playback second Q, source [S0, S1).
type SpanPiece struct{ Q, S0, S1 float64 }

// Span lists the pieces playing within playback [p0, p1).
func (r *Route) Span(p0, p1 float64) []SpanPiece {
	var out []SpanPiece
	q, last := 0.0, len(r.Pieces)-1
	for k, p := range r.Pieces {
		lo, hi := q, q+p.S1-p.S0
		if k == 0 {
			lo = math.Inf(-1)
		}
		if k == last {
			hi = math.Inf(1)
		}
		a, b := math.Max(p0, lo), math.Min(p1, hi)
		if a < b {
			out = append(out, SpanPiece{a, p.S0 + a - q, p.S0 + b - q})
		}
		q += p.S1 - p.S0
	}
	return out
}

// TrackEnd is the source second where t's audio ends.
func TrackEnd(t *tracks.Track) float64 {
	if t.Length != 0 {
		return t.Length
	}
	return beatTime(t, len(t.Beats)+1)
}

// JumpRoute is how t plays from source second start. On reaching a JUMP memory cue playback
// goes to a hot cue named JUMP... (JUMP, JUMP TO DROP, JUMP AGAIN): the n-th jump to the n-th
// of those in time order, the last one again after that. Each memory cue jumps once, so a
// jump back doesn't loop forever; one within a beat of a JUMP hot cue marks where a jump
// lands. Jumps that would skip a source second in keep (the track's G) aren't taken: the
// track plays straight through.
func JumpRoute(t *tracks.Track, start float64, keep ...float64) *Route {
	end := TrackEnd(t)
	spb := 60 / math.Max(t.BPM, 1)
	isJump := func(c db.Cue) bool {
		n := config.RenameTo(c.Name, c.Kind > 0)
		if n == "" {
			n = config.Norm(c.Name)
		}
		return n == "JUMP"
	}
	var hot, trig []float64
	for _, c := range t.Cues {
		if c.Kind > 0 && isJump(c) {
			hot = append(hot, c.T)
		}
	}
	slices.Sort(hot)
	for _, c := range t.Cues {
		if c.Kind == 0 && isJump(c) && !slices.ContainsFunc(hot, func(h float64) bool { return math.Abs(c.T-h) <= spb }) {
			trig = append(trig, c.T)
		}
	}
	slices.Sort(trig)
	straight := &Route{[]Piece{{start, math.Max(end, start)}}}
	if len(hot) == 0 {
		return straight
	}
	var pieces []Piece
	cur := start
	for {
		i := slices.IndexFunc(trig, func(x float64) bool { return cur+1e-3 < x && x < end })
		if i < 0 {
			break
		}
		nxt := trig[i]
		trig = slices.Delete(trig, i, i+1)
		pieces = append(pieces, Piece{cur, nxt})
		cur = hot[min(len(pieces), len(hot))-1]
	}
	if len(pieces) == 0 {
		return straight
	}
	route := &Route{append(pieces, Piece{cur, math.Max(end, cur)})}
	for _, k := range keep {
		if _, ok := route.Play(k, 0); k >= start && !ok {
			return straight
		}
	}
	return route
}

// Clock maps source seconds to mix seconds for one track: stretched by Rate (source s per
// mix s) until mix time Split (when the previous track has left), by Own after (1 at its own
// tempo, else the stretch to the set's fixed tempo).
type Clock struct {
	Out0, Src0, Rate, Split, Own float64
}

// newClock plays at rate throughout.
func newClock(out0, src0, rate float64) *Clock { return &Clock{out0, src0, rate, out0, rate} }

// SrcSplit is the source second playing at Split.
func (c *Clock) SrcSplit() float64 { return c.Src0 + (c.Split-c.Out0)*c.Rate }

// Out is the mix second where source second src plays.
func (c *Clock) Out(src float64) float64 {
	if src < c.SrcSplit() {
		return c.Out0 + (src-c.Src0)/c.Rate
	}
	return c.Split + (src-c.SrcSplit())/c.Own
}

// RateAt is the stretch at mix second t.
func (c *Clock) RateAt(t float64) float64 {
	if t < c.Split {
		return c.Rate
	}
	return c.Own
}
