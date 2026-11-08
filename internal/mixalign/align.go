// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package mixalign lines the tracks of a play history up against a recording of the set
// (docs/decisions/0017-split-recordings-by-alignment.md). The history gives the order, the
// audio gives the timing: each track is found by matching its onset envelope against the
// recording over a grid of CDJ tempo ratios, refitted locally at each transition, and the
// cut between two tracks goes where the incoming track takes the bass over, snapped to its
// nearest phrase start.
package mixalign

import (
	"cmp"
	"fmt"
	"math"
	"runtime"
	"slices"
	"sync"

	"github.com/bitwise-media-group/auto-dj/internal/features"
	"github.com/bitwise-media-group/auto-dj/internal/setlist"
	"github.com/bitwise-media-group/auto-dj/internal/tracks"
)

// Alignment parameters.
const (
	ProbeSec  = 8.0  // probe window length (s)
	MaxProbes = 12   // probes per fit, of which ...
	Agree     = 3    // ... the best this many score it (sets play parts of tracks, and mashups)
	RMin      = 0.90 // tempo ratios searched (the CDJ's ±10% range) ...
	RMax      = 1.10
	RStep     = 0.0025 // ... in 0.25% steps
	MaxGapSec = 600.0  // how far past the previous track's end the next one is searched for (s)
	LocalSec  = 40.0   // how far a transition's local fit may move from the global one (a loop, s)
	// NotFound is the score (the Agree best probes' mean correlation) below which a track
	// counts as not played. On a real hour-long set, the 20 tracks played scored 0.83-0.98
	// and 35 tracks from other sessions 0.14-0.73.
	NotFound = 0.78
	// LowConfidence is the score below which a fit is flagged for review. (The peak ratio, best
	// fit over the best half a beat or more away, is reported but not used: on real sets
	// correct fits ranged 1.00-1.37, music being repetitive.)
	LowConfidence = 0.88
	// Audible is the full-band gain (relative to the track playing alone) above which a
	// track counts as audible.
	Audible = 0.2
	// Rescue is the lowest score at which a track is traced anyway, in case it was played only
	// briefly: it counts as found when RunProbes probes in a row match at RunScore or better.
	Rescue    = 0.6
	RunProbes = 4
	RunScore  = 0.85
	// TraceBeats is the spacing of the probes a track's path is traced with.
	TraceBeats = 16
	// JumpPenalty is what a jump (loop, hot cue) costs a traced path, in probe correlation.
	JumpPenalty = 0.6
	// Continuous is how far (s) two probes' offsets may differ and still be one straight play.
	Continuous = 0.06
	// CueBeats is how far before the moment a track became audible its E may be on one of its
	// cues (the DJ starts it on a cue, the fader may come up much later).
	CueBeats = 64
	// SnapBeats is how far the cut may move to reach the incoming track's phrase start.
	SnapBeats = setlist.Phrase
)

// Statuses.
const (
	OK            = "ok"
	LowConf       = "low-confidence"
	NotFoundState = "not-found"
	NoAudio       = "no-audio"
)

const fps = features.FPS

// Input is one history entry to locate in the recording.
type Input struct {
	No    int
	ID    string
	Title string
	// Rec has the beat grid and phrases (nil without Rekordbox analysis: the cut is then not
	// snapped and no transition is recorded).
	Rec *tracks.Track
	// F is the track's frame features (features package), nil when its audio isn't here.
	F []features.Frame
}

// Fit maps track time to recording time: rec = Offset + track / R (seconds). R is the
// tempo ratio the track played at (1.02 = 2% faster).
type Fit struct {
	Offset float64 `json:"offset"`
	R      float64 `json:"r"`
	Score  float64 `json:"score"`
}

// Rec is the recording second where track second t plays.
func (f Fit) Rec(t float64) float64 { return f.Offset + t/f.R }

// Track is the track second playing at recording second rec.
func (f Fit) Track(rec float64) float64 { return (rec - f.Offset) * f.R }

// Transition is the transition into a track as it was played, in track beats: G on the
// outgoing track (where the incoming one came in), E and BASS SWAP on the incoming one.
type Transition struct {
	FromID    string `json:"from_id"`
	FromTitle string `json:"from_title"`
	G         int    `json:"g_beat"`
	E         int    `json:"e_beat"`
	BassSwap  int    `json:"bass_swap_beat"`
	ECue      string `json:"e_cue,omitempty"` // the incoming track's cue E is on
	GCue      string `json:"g_cue,omitempty"` // the outgoing track's hot cue G is near, "<name> +n beats"
}

// Entry is one history track's alignment. Times are recording times as h:mm:ss.sss.
type Entry struct {
	No         int         `json:"no"`
	ID         string      `json:"id"`
	Title      string      `json:"title"`
	Status     string      `json:"status"`
	Confidence float64     `json:"confidence"`
	PeakRatio  float64     `json:"peak_ratio,omitempty"`
	Matched    float64     `json:"matched,omitempty"` // share of its probes heard where expected
	Fit        *Fit        `json:"fit,omitempty"`     // the whole track
	In         *Fit        `json:"in_fit,omitempty"`  // how it played at its start ...
	Out        *Fit        `json:"out_fit,omitempty"` // ... and at its end (differ after a loop or jump)
	Start      string      `json:"start,omitempty"`   // audible from
	End        string      `json:"end,omitempty"`     // audible until
	Takeover   string      `json:"takeover,omitempty"`
	Cut        string      `json:"cut"` // where its file starts; edit to move, clear to leave it out
	CutSample  int64       `json:"cut_sample"`
	Transition *Transition `json:"transition,omitempty"`
	Notes      []string    `json:"notes,omitempty"`
}

// Kept reports whether the track gets a file: it has a cut.
func (e *Entry) Kept() bool { return e.Cut != "" }

// Located reports whether the track was found in the recording.
func (e *Entry) Located() bool { return e.Status == OK || e.Status == LowConf }

// probe is a stretch of a track's channels, from track frame start.
type probe struct {
	start int
	q     [][]float64
}

// track is one input's working state.
type track struct {
	in         Input
	entry      *Entry
	env        [][]float64 // channels
	bass, full []float64
	dur        float64 // seconds
	global     *Fit
	probes     []probe // the global fit's probes
	pieces     []piece // how it played, in recording order (trace)
	heard      int     // the longest straight run of probes matching at RunScore (trace)
	start, end float64 // audible span (rec s)
}

// aligner holds the recording's envelopes.
type aligner struct {
	env        [][]float64 // channels
	bass, full []float64
	dur        float64
	m          int // probe length (frames)
}

// Align locates each input in the recording (its frame features) and plans the cuts.
// sampleRate and samples are the recording's own, for the cut samples.
func Align(rec []features.Frame, in []Input, sampleRate int, samples int64) []*Entry {
	a := &aligner{env: channels(rec), bass: amp(rec, 0), full: amp(rec, 1, 2, 3), dur: float64(len(rec)) / fps,
		m: int(math.Round(ProbeSec * fps))}
	if sampleRate > 0 && samples > 0 {
		a.dur = float64(samples) / float64(sampleRate)
	}
	ts := make([]*track, len(in))
	for i, x := range in {
		e := &Entry{No: x.No, ID: x.ID, Title: x.Title}
		ts[i] = &track{in: x, entry: e}
		if len(x.F) < 2*a.m {
			e.Status = NoAudio
			e.Notes = append(e.Notes, "no audio file here (streaming or missing): set its cut by hand")
			continue
		}
		t := ts[i]
		t.env, t.bass, t.full = channels(x.F), amp(x.F, 0), amp(x.F, 1, 2, 3)
		t.dur = float64(len(x.F)) / fps
	}
	a.locateAll(ts)
	var found []*track
	for _, t := range ts {
		if t.global != nil {
			if t.pieces == nil {
				a.trace(t)
			}
			found = append(found, t)
		}
	}
	for i, t := range found {
		if i == 0 {
			t.start = a.firstAudible(t)
			t.entry.Cut, t.entry.CutSample = FormatTime(0), 0
			continue
		}
		a.transition(found[i-1], t, sampleRate)
	}
	if n := len(found); n > 0 {
		found[n-1].end = a.lastAudible(found[n-1])
	}
	out := make([]*Entry, len(ts))
	for i, t := range ts {
		e := t.entry
		if t.global != nil {
			e.Fit, e.In, e.Out = round(t.global), round(&t.pieces[0].Fit), round(&t.pieces[len(t.pieces)-1].Fit)
			e.Start, e.End = FormatTime(t.start), FormatTime(t.end)
		}
		out[i] = e
	}
	return out
}

func round(f *Fit) *Fit {
	if f == nil {
		return nil
	}
	return &Fit{math.Round(f.Offset*1e4) / 1e4, math.Round(f.R*1e6) / 1e6, math.Round(f.Score*1e3) / 1e3}
}

// ------------------------------------------------------------------ locating

// locateAll finds each track in turn, searching from the previous track's position.
func (a *aligner) locateAll(ts []*track) {
	lo, hi := 0.0, 0.0 // recording seconds the next track's middle is searched in
	first := true
	for _, t := range ts {
		if t.env == nil {
			continue
		}
		if first {
			hi = t.dur + MaxGapSec
		} else {
			hi += t.dur
		}
		t.probes = a.pickProbes(t, 0.1, 0.9)
		fit, ratio, ok := a.locate(t, t.probes, lo, hi, tempoGrid(RMin, RMax), false)
		e := t.entry
		rescued := false
		if ok && fit.Score >= Rescue && fit.Score < NotFound { // played only briefly?
			t.global = &fit
			a.trace(t)
			if rescued = t.heard >= RunProbes; !rescued {
				t.global, t.pieces = nil, nil
			}
		}
		if !ok || (fit.Score < NotFound && !rescued) {
			e.Status = NotFoundState
			if ok {
				e.Confidence = math.Round(fit.Score*1e3) / 1e3
			}
			e.Notes = append(e.Notes, "not heard in the recording: left out")
			continue
		}
		first = false
		t.global = &fit
		e.Confidence, e.PeakRatio = math.Round(fit.Score*1e3)/1e3, math.Round(ratio*1e3)/1e3
		e.Status = OK
		if fit.Score < LowConfidence {
			e.Status = LowConf
		}
		if rescued {
			sec := float64(t.heard) * ProbeSec // probes every 8 s without a grid
			if bpm := bpmOf(t); bpm > 0 {
				sec = float64(t.heard*TraceBeats) * 60 / bpm / fit.R
			}
			e.Notes = append(e.Notes, fmt.Sprintf("heard straight for only about %.0f s (a short excerpt?)", sec))
		}
		if fit.R <= RMin+RStep/2 || fit.R >= RMax-RStep/2 {
			e.Status = LowConf
			e.Notes = append(e.Notes, fmt.Sprintf("tempo ratio %.3f is at the edge of the CDJ range", fit.R))
		}
		lo = math.Max(fit.Offset, 0) // where its beat 1 would play: the next track's middle comes later
		hi = fit.Rec(t.dur) + MaxGapSec
	}
}

// bpmOf is the track's BPM (0 without a grid).
func bpmOf(t *track) float64 {
	if t.in.Rec == nil {
		return 0
	}
	return t.in.Rec.BPM
}

func tempoGrid(lo, hi float64) []float64 {
	var rs []float64
	for k := 0; ; k++ {
		r := lo + float64(k)*RStep
		if r > hi+1e-9 {
			return rs
		}
		rs = append(rs, r)
	}
}

// probeStarts are the places a probe may start (track frames): the phrase starts and every
// 32 beats with a beat grid, and every 4 s regardless (a phrase grid can miss what was played).
func probeStarts(t *track, n int) []int {
	var starts []int
	if r := t.in.Rec; r != nil && len(r.Beats) > 0 {
		for _, p := range r.Phrases {
			if p.Beat >= 1 && p.Beat <= len(r.Beats) {
				starts = append(starts, int(math.Round(r.Beats[p.Beat-1]*fps)))
			}
		}
		for b := 1; b <= len(r.Beats); b += 32 {
			starts = append(starts, int(math.Round(r.Beats[b-1]*fps)))
		}
	}
	for s := 0; s < n; s += int(math.Round(4 * fps)) {
		starts = append(starts, s)
	}
	return starts
}

// probeCand is a possible probe start and how busy the track is there.
type probeCand struct {
	start int
	v     float64
}

// pickProbes chooses up to MaxProbes probe windows (probeStarts) between fractions lo and hi
// of the track: the busiest (largest channel variance) in each of MaxProbes equal stretches,
// at least a probe length apart. A set plays only part of a track, so they must cover it all.
func (a *aligner) pickProbes(t *track, lo, hi float64) []probe {
	n := len(t.env[0])
	from, to := int(lo*float64(n)), int(hi*float64(n))
	var cs []probeCand
	for _, s := range probeStarts(t, n) {
		if s < from || s+a.m > to || s+a.m > n {
			continue
		}
		v := 0.0
		for _, ch := range t.env {
			v += variance(ch[s : s+a.m])
		}
		cs = append(cs, probeCand{s, v})
	}
	if len(cs) == 0 { // a short track: its middle
		cs = append(cs, probeCand{max(0, min(n-a.m, (from+to)/2-a.m/2)), 1})
	}
	strata := max(1, min(MaxProbes, (to-from)/a.m))
	span := float64(to-from) / float64(strata)
	best := make([]*probeCand, strata)
	for i := range cs {
		k := min(strata-1, max(0, int(float64(cs[i].start-from)/span)))
		if best[k] == nil || cs[i].v > best[k].v {
			best[k] = &cs[i]
		}
	}
	out := make([]probe, 0, strata)
	for _, c := range best {
		if c != nil && !slices.ContainsFunc(out, func(p probe) bool { return abs(p.start-c.start) < a.m }) {
			out = append(out, t.probeAt(c.start, a.m))
		}
	}
	slices.SortFunc(out, func(x, y probe) int { return x.start - y.start })
	return out
}

// probeAt is the probe of m frames from track frame start.
func (t *track) probeAt(start, m int) probe {
	q := make([][]float64, len(t.env))
	for k, ch := range t.env {
		q[k] = ch[start : start+m]
	}
	return probe{start, q}
}

func variance(x []float64) float64 {
	m, v := 0.0, 0.0
	for _, y := range x {
		m += y
	}
	m /= float64(len(x))
	for _, y := range x {
		v += (y - m) * (y - m)
	}
	return v / float64(len(x))
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// locate fits the probes against the recording, with the probes' centre playing between
// recording seconds lo and hi, over tempo ratios rs: the mean (max-filtered) correlation of
// the Agree best probes, then a fine refinement of the best couple of dozen peaks (the max
// filter flatters lookalikes). ratio is the best score over the best one at least half a
// beat away; ok is false when there was nowhere to search. Equal scores go to the earliest
// position, or the latest with late (a looped stretch plays twice: a track's start is in the
// first pass, its end after the last).
func (a *aligner) locate(t *track, probes []probe, lo, hi float64, rs []float64, late bool) (fit Fit, ratio float64,
	ok bool) {
	if len(probes) == 0 {
		return Fit{}, 0, false
	}
	pc, maxDist := centre(probes)
	// the segment holds every lag of every probe for centres in [lo, hi]
	span := maxDist/RMin + float64(a.m)/RMin
	x0 := max(0, int(lo*fps-span)-1)
	x1 := min(len(a.env[0]), int(hi*fps+span)+2)
	if x1-x0 < 2*a.m {
		return Fit{}, 0, false
	}
	res := a.coarse(t, probes, pc, x0, x1, rs, int(math.Ceil(RStep/2*maxDist))+1)
	cLo, cHi := max(int(lo*fps)-x0, 0), int(hi*fps)-x0
	cands := bestPeaks(res, cLo, cHi, late)
	if len(cands) == 0 {
		return Fit{}, 0, false
	}
	fits := make([]Fit, len(cands))
	var wg sync.WaitGroup
	for k, pk := range cands {
		wg.Go(func() { fits[k] = a.refine(probes, pc, float64(x0+pk.c)/fps, rs[pk.i]) })
	}
	wg.Wait()
	bk := 0
	for k, f := range fits {
		if f.Score > fits[bk].Score+1e-9 {
			bk = k
		}
	}
	bp := cands[bk]
	second := math.Inf(-1)
	excl := int(math.Round(0.25 * fps))
	for c := cLo; c <= min(cHi, len(res[bp.i])-1); c++ {
		if abs(c-bp.c) > excl {
			second = math.Max(second, res[bp.i][c])
		}
	}
	ratio = 10
	if second > 1e-6 {
		ratio = math.Min(bp.v/second, 10)
	}
	return fits[bk], ratio, true
}

// centre is the probes' mean start frame and the furthest any is from it.
func centre(probes []probe) (pc, maxDist float64) {
	for _, p := range probes {
		pc += float64(p.start)
	}
	pc /= float64(len(probes))
	for _, p := range probes {
		maxDist = math.Max(maxDist, math.Abs(float64(p.start)-pc))
	}
	return pc, maxDist
}

// coarse is the consensus curve of every tempo ratio over recording frames [x0, x1), computed
// in parallel.
func (a *aligner) coarse(t *track, probes []probe, pc float64, x0, x1 int, rs []float64, w int) [][]float64 {
	base := make([]*correlator, len(a.env))
	for k, ch := range a.env {
		base[k] = newCorrelator(ch[x0:x1])
	}
	res := make([][]float64, len(rs))
	jobs := make(chan int)
	var wg sync.WaitGroup
	for range min(runtime.GOMAXPROCS(0), len(rs)) {
		c := make([]*correlator, len(base))
		for k, b := range base {
			c[k] = b.fork()
		}
		wg.Go(func() {
			for i := range jobs {
				res[i] = a.consensus(c, t, probes, pc, rs[i], w)
			}
		})
	}
	for i := range rs {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
	return res
}

// peak is a local maximum of tempo ratio i's consensus curve, at centre frame c.
type peak struct {
	i, c int
	v    float64
}

// bestPeaks pools each tempo ratio's best four peaks (half a second apart) between centre
// frames cLo and cHi and returns the best 24 places.
func bestPeaks(res [][]float64, cLo, cHi int, late bool) []peak {
	sep := int(math.Round(0.5 * fps))
	var peaks []peak
	for i, r := range res {
		var local []peak
		for c := cLo; c <= min(cHi, len(r)-1); c++ {
			if v := r[c]; !math.IsInf(v, -1) && (c == cLo || r[c-1] <= v) && (c == len(r)-1 || r[c+1] <= v) {
				local = append(local, peak{i, c, v})
			}
		}
		slices.SortStableFunc(local, func(x, y peak) int {
			if x.v == y.v && late {
				return y.c - x.c
			}
			return cmp.Compare(y.v, x.v)
		})
		kept := 0
		for k, pk := range local {
			if kept == 4 {
				break
			}
			if !slices.ContainsFunc(local[:k], func(q peak) bool { return abs(q.c-pk.c) < sep && q.v >= pk.v }) {
				peaks = append(peaks, pk)
				kept++
			}
		}
	}
	slices.SortStableFunc(peaks, func(x, y peak) int { return cmp.Compare(y.v, x.v) })
	var out []peak
	for _, pk := range peaks {
		if len(out) == 24 {
			break
		}
		if !slices.ContainsFunc(out, func(q peak) bool { return abs(q.c-pk.c) < 3 }) {
			out = append(out, pk)
		}
	}
	return out
}

// agree is how many of n probes score a fit.
func agree(n int) int { return min(n, Agree) }

// topMean is the mean of the k largest of xs (-Inf when fewer than k are finite).
func topMean(xs []float64, k int) float64 {
	ys := make([]float64, 0, len(xs))
	for _, x := range xs {
		if !math.IsInf(x, 0) && !math.IsNaN(x) {
			ys = append(ys, x)
		}
	}
	if len(ys) < k || k == 0 {
		return math.Inf(-1)
	}
	slices.Sort(ys)
	s := 0.0
	for _, y := range ys[len(ys)-k:] {
		s += y
	}
	return s / float64(k)
}

// consensus is, for tempo ratio r, the mean max-filtered correlation of the Agree best
// probes by the recording frame (segment-relative) where the probes' centre pc plays; -Inf
// where too few probes fall inside the segment.
func (a *aligner) consensus(cs []*correlator, t *track, probes []probe, pc, r float64, w int) []float64 {
	n := len(cs[0].x)
	per := make([][]float64, len(probes)) // per probe, by centre frame
	m := int(float64(a.m) / r)
	q := make([]float64, m)
	for pi, p := range probes {
		per[pi] = make([]float64, n)
		for k := range per[pi] {
			per[pi][k] = math.Inf(-1)
		}
		var avg []float64
		for k, c := range cs {
			for j := range q {
				q[j], _ = at(t.env[k], float64(p.start)+float64(j)*r)
			}
			if !normalise(q) {
				continue
			}
			x := c.ncc(q)
			if avg == nil {
				avg = make([]float64, len(x))
			}
			for L, v := range x {
				avg[L] += v / float64(len(cs))
			}
		}
		if avg == nil {
			continue
		}
		ncc := maxFilter(avg, w)
		shift := int(math.Round((pc - float64(p.start)) / r))
		for L, v := range ncc {
			if k := L + shift; k >= 0 && k < n {
				per[pi][k] = v
			}
		}
	}
	out := make([]float64, n)
	vals := make([]float64, len(probes))
	ag := agree(len(probes))
	for k := range out {
		for pi := range per {
			vals[pi] = per[pi][k]
		}
		out[k] = topMean(vals, ag)
	}
	return out
}

// score is the mean correlation of the Agree best probes with the recording when the
// probes' centre pc plays at recording second rc at tempo ratio r (no max filter: the fine
// fit).
func (a *aligner) score(probes []probe, pc, rc, r float64) float64 {
	y := make([]float64, a.m)
	per := make([]float64, len(probes))
	for pi, p := range probes {
		for k, ch := range a.env {
			for j := range y {
				y[j], _ = at(ch, rc*fps+(float64(p.start+j)-pc)/r)
			}
			per[pi] += pearson(p.q[k], y) / float64(len(a.env))
		}
	}
	return topMean(per, agree(len(probes)))
}

// refine searches centre positions within three frames of rc (quarter frames), then tempo
// ratios within a grid step of r (tenth steps), then the positions again, for the best
// unfiltered fit.
func (a *aligner) refine(probes []probe, pc, rc, r float64) Fit {
	best := a.score(probes, pc, rc, r)
	byPos := func() {
		c0 := rc
		for dc := -3.0; dc <= 3; dc += 0.25 {
			if v := a.score(probes, pc, c0+dc/fps, r); v > best {
				rc, best = c0+dc/fps, v
			}
		}
	}
	byPos()
	r0 := r
	for dr := -RStep; dr <= RStep+1e-12; dr += RStep / 10 {
		if v := a.score(probes, pc, rc, r0+dr); v > best {
			r, best = r0+dr, v
		}
	}
	byPos()
	return Fit{Offset: rc - pc/fps/r, R: r, Score: best}
}
