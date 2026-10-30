// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package preview

import (
	"math"
	"os"

	"github.com/bitwise-media-group/adj/internal/db"
	"github.com/bitwise-media-group/adj/internal/num"
	"github.com/bitwise-media-group/adj/internal/rules"
	"github.com/bitwise-media-group/adj/internal/setlist"
	"github.com/bitwise-media-group/adj/internal/tracks"
)

// ExitPlan is how a track leaves the mix (mix seconds):
//
//	end    [end]                    plays to its end
//	fade   [from, to]               fades out
//	filter [sweep from, sweep to, end]  low-pass sweep to silence, then a fade out
//	cut    [at, at]                 cut
type ExitPlan struct {
	Kind string
	Xs   []float64
}

// Seg is one track in the mix timeline (mix seconds).
type Seg struct {
	N       int
	Title   string
	Missing bool // no local audio: the mix leaves a short gap

	Rec           *tracks.Track
	E             int
	Route         *Route
	Clock         *Clock
	Start, End    float64
	Exit          ExitPlan
	FadeIn        *[2]float64
	BassIn        *float64 // no bass until then
	BassOut       *float64 // bass gone after then
	GT, SwapT     *float64 // when it reaches G; the bass swap into the next track
	EstimatedSwap bool
	Sync          bool
	Jumps         []float64

	p0 float64 // playback second the track starts from (transition clips)
}

func f(v float64) *float64 { return &v }

func audioOK(t *tracks.Track) bool {
	if t == nil || t.Path == "" {
		return false
	}
	_, err := os.Stat(t.Path)
	return err == nil
}

// length is the mix time when the track's audio runs out.
func (s *Seg) length() float64 { return s.Clock.Out(s.Route.Dur()) }

func (s *Seg) playOut() float64 {
	s.End = math.Max(s.length(), s.Start)
	s.Exit = ExitPlan{"end", []float64{s.End}}
	return s.End
}

// MixTimeline plans the full-set mix. One Seg per track in order; tracks without local audio
// are Missing and the mix leaves a short gap (the previous track plays to its end).
// leadIn > 0 starts the first track this many beats before it reaches its G (transition clips).
func MixTimeline(order []db.PlaylistTrack, actions []setlist.Action, recs map[string]*tracks.Track, leadIn int) []*Seg {
	var segs []*Seg
	var prev *Seg // the playing track's segment, while the next one can still mix into it
	tFree := 0.0  // where the next track starts when there's no transition into it
	for i, x := range order {
		t, act := recs[x.ID], actions[i]
		seg := &Seg{N: i + 1, Title: x.Title, Missing: !audioOK(t)}
		segs = append(segs, seg)
		if seg.Missing {
			if prev != nil {
				tFree = prev.playOut() + GapS
			}
			prev = nil
			continue
		}
		seg.setRoute(t, act, i == 0 && leadIn > 0, leadIn)
		var pg float64
		hasPG := false
		if i > 0 && prev != nil {
			if gp := actions[i-1].G; gp != nil && gp.Status != "clear" {
				pg, hasPG = prev.Route.Play(beatTime(prev.Rec, gp.Beat), 0)
			}
		}
		if !hasPG {
			if prev != nil {
				tFree = prev.playOut() + GapS
			}
			seg.Start, seg.Clock = tFree, newClock(tFree, seg.p0, 1)
			prev = seg
			continue
		}
		transition(prev, seg, actions[i-1], act, pg)
		prev = seg
	}
	if prev != nil {
		prev.playOut()
	}
	for _, s := range segs {
		if !s.Missing {
			s.setJumps()
		}
	}
	return segs
}

// setRoute sets the track's E (the first downbeat without one) and its route from E, keeping
// its own G reachable. With lead, it starts lead beats before it reaches G.
func (s *Seg) setRoute(t *tracks.Track, act setlist.Action, lead bool, leadIn int) {
	var keep []float64
	if act.G != nil && act.G.Status != "clear" {
		keep = []float64{beatTime(t, act.G.Beat)}
	}
	s.Rec, s.E = t, rules.FirstDownbeat(t)
	if act.E != nil {
		s.E = act.E.Beat
	}
	s.Route = JumpRoute(t, beatTime(t, s.E), keep...)
	if lead && keep != nil {
		q, _ := s.Route.Play(keep[0], 0)
		s.p0 = math.Max(0, q-float64(leadIn)*60/t.BPM)
	}
}

// setJumps lists the mix times of the track's jumps while it plays.
func (s *Seg) setJumps() {
	s.Jumps = []float64{}
	for _, q := range s.Route.Jumps() {
		if m := s.Clock.Out(q); s.Start <= m && m < s.End {
			s.Jumps = append(s.Jumps, m)
		}
	}
}

// transition beat-matches seg into prev, which reaches its G at playback second pg.
func transition(prev, seg *Seg, pact, act setlist.Action, pg float64) {
	a, ca, ra := prev.Rec, prev.Clock, prev.Route
	t, route, e := seg.Rec, seg.Route, seg.E
	tg := ca.Out(pg)
	rate := a.BPM * ca.RateAt(tg) / t.BPM // this track stretched to the playing tempo
	clock := newClock(tg, 0, rate)
	// stretched until the outgoing track has left (set below)
	clock.Split = math.Inf(1)
	spb := func(m float64) float64 { return 60 / (a.BPM * ca.RateAt(m)) } // one beat in mix seconds
	outB := func(b int) (float64, bool) {
		q, ok := route.Play(beatTime(t, b), 0)
		if !ok {
			return 0, false
		}
		return clock.Out(q), true
	}
	var ts float64
	est := true
	if act.Swap != nil && *act.Swap > e {
		ts, est = outB(*act.Swap)
		est = !est
	}
	if est {
		ts = tg + 32*spb(tg)
	}
	ex := pact.Exit
	var x0 float64
	hasX0 := false
	switch {
	case ex != nil && ex.Side == "out":
		if q, ok := ra.Play(beatTime(a, ex.A), pg); ok {
			x0, hasX0 = ca.Out(q), true
		}
	case ex != nil:
		x0, hasX0 = outB(ex.B)
	}
	var exit ExitPlan
	switch {
	case !hasX0:
		x1 := math.Max(tg, math.Min(ts+FadeOut*spb(ts), prev.length()))
		exit = ExitPlan{"fade", []float64{math.Min(ts, x1), x1}}
	case ex.Name == "FILTER":
		xs, x1 := x0+FilterBeats*spb(x0), x0+(FilterBeats+FilterFadeBeats)*spb(x0)
		x1 = math.Max(tg, math.Min(x1, prev.length()))
		exit = ExitPlan{"filter", []float64{math.Min(x0, x1), math.Min(xs, x1), x1}}
	default:
		x1 := math.Max(tg, math.Min(x0, prev.length()))
		exit = ExitPlan{"cut", []float64{x1, x1}}
	}
	x1 := exit.Xs[len(exit.Xs)-1]
	prev.End, prev.Exit, prev.GT, prev.SwapT, prev.EstimatedSwap = x1, exit, f(tg), f(ts), est
	prev.BassOut = nil
	if ts < x1 {
		prev.BassOut = f(ts)
	}
	clock.Split = x1
	seg.Sync = act.Sync // instant mashup: in at full volume
	if !seg.Sync {
		seg.FadeIn = &[2]float64{tg, math.Min(tg+FadeIn*spb(tg), x1)}
	}
	seg.Start, seg.Clock, seg.BassIn = tg, clock, f(math.Min(ts, x1))
}

// PairTimeline is one transition clip: MixTimeline of A -> B with A from Lead beats before
// it reaches G (after its jumps from E), ending Tail beats after A has left.
func PairTimeline(order []db.PlaylistTrack, actions []setlist.Action, recs map[string]*tracks.Track) (sa, sb *Seg) {
	segs := MixTimeline(order, actions, recs, Lead)
	sa, sb = segs[0], segs[1]
	end := sa.End + Tail*60/sa.Rec.BPM
	if sb.End > end {
		sb.End, sb.Exit = end, ExitPlan{"end", []float64{end}}
		var j []float64
		for _, m := range sb.Jumps {
			if m < end {
				j = append(j, m)
			}
		}
		sb.Jumps = j
	}
	return sa, sb
}

// MixTrack is the page's view of one Seg.
type MixTrack struct {
	N             int       `json:"n"`
	Title         string    `json:"title"`
	Start         float64   `json:"start"`
	End           float64   `json:"end"`
	G             *float64  `json:"g"`
	Swap          *float64  `json:"swap"`
	EstimatedSwap bool      `json:"estimated_swap"`
	Exit          string    `json:"exit"`
	ExitT         []float64 `json:"exit_t"`
	Sync          bool      `json:"sync"`
	Jumps         []float64 `json:"jumps"`
}

// MissingTrack is a track without local audio in the page's view.
type MissingTrack struct {
	N       int    `json:"n"`
	Title   string `json:"title"`
	Missing bool   `json:"missing"`
}

func r2(v *float64) *float64 {
	if v == nil {
		return nil
	}
	return f(num.RoundTo(*v, 2))
}

func r2s(vs []float64) []float64 {
	out := make([]float64, len(vs))
	for i, v := range vs {
		out[i] = num.RoundTo(v, 2)
	}
	return out
}

// MixInfo is the page's view of MixTimeline: when each track plays and how it leaves.
func MixInfo(segs []*Seg) (dur float64, out []any) {
	out = []any{}
	for _, s := range segs {
		if s.Missing {
			out = append(out, MissingTrack{s.N, s.Title, true})
			continue
		}
		dur = math.Max(dur, s.End)
		out = append(out, MixTrack{N: s.N, Title: s.Title, Start: num.RoundTo(s.Start, 2), End: num.RoundTo(s.End, 2),
			G:    r2(s.GT),
			Swap: r2(s.SwapT), EstimatedSwap: s.EstimatedSwap, Exit: s.Exit.Kind, ExitT: r2s(s.Exit.Xs),
			Sync: s.Sync, Jumps: r2s(s.Jumps)})
	}
	return num.RoundTo(dur, 2), out
}
