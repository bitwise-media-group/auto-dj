// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package mixalign

import (
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"

	"github.com/bitwise-media-group/auto-dj/internal/config"
	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/setlist"
	"github.com/bitwise-media-group/auto-dj/internal/tracks"
)

// mapped is track series x as heard through the track's path, over recording frames
// [f0, f0+n): 0 where the track has no audio.
func (t *track) mapped(x []float64, f0, n int) []float64 {
	out := make([]float64, n)
	for i := range out {
		rec := float64(f0+i) / fps
		if v, ok := at(x, t.fitAt(rec).Track(rec)*fps); ok {
			out[i] = v
		}
	}
	return out
}

// gains solves rec ≈ a·A + b·B with a, b >= 0 by least squares over a centred window of w
// frames at every frame (B may be nil: a alone).
func gains(rec, A, B []float64, w int) (ga, gb []float64) {
	n := len(rec)
	if B == nil {
		B = make([]float64, n)
	}
	prod := func(x, y []float64) []float64 {
		p := make([]float64, n)
		for i := range p {
			p[i] = x[i] * y[i]
		}
		return prefix(p)
	}
	aa, bb, ab, ar, br := prod(A, A), prod(B, B), prod(A, B), prod(A, rec), prod(B, rec)
	ga, gb = make([]float64, n), make([]float64, n)
	h := max(w/2, 1)
	for i := range n {
		lo, hi := max(i-h, 0), min(i+h+1, n)
		s := func(p []float64) float64 { return p[hi] - p[lo] }
		saa, sbb, sab, sar, sbr := s(aa), s(bb), s(ab), s(ar), s(br)
		ridge := 1e-6 * (saa + sbb)
		saa, sbb = saa+ridge+1e-12, sbb+ridge+1e-12
		det := saa*sbb - sab*sab
		a := (sbb*sar - sab*sbr) / det
		b := (saa*sbr - sab*sar) / det
		if a < 0 || b < 0 { // one of them alone: the better fit of the two
			a1, b1 := math.Max(sar/saa, 0), math.Max(sbr/sbb, 0)
			if a1*sar >= b1*sbr {
				a, b = a1, 0
			} else {
				a, b = 0, b1
			}
		}
		ga[i], gb[i] = a, b
	}
	return ga, gb
}

// refGain is how loud the track is in the recording while playing alone: the least-squares
// gain of its series x against the recording's rec over its global probes.
func (a *aligner) refGain(t *track, x, rec []float64) float64 {
	g := *t.global
	f0 := int(g.Rec(float64(t.probes[0].start)/fps) * fps)
	f1 := int(g.Rec(float64(t.probes[len(t.probes)-1].start+a.m)/fps) * fps)
	f0, f1 = max(f0, 0), min(f1, len(rec))
	if f1 <= f0 {
		return 1
	}
	m := make([]float64, f1-f0)
	for i := range m {
		m[i], _ = at(x, g.Track(float64(f0+i)/fps)*fps)
	}
	var sxy, sxx float64
	for i, v := range m {
		sxy += v * rec[f0+i]
		sxx += v * v
	}
	if sxy <= 0 || sxx <= 0 {
		return 1
	}
	return sxy / sxx
}

// beatFrames is n beats of t at its playing tempo, in frames (4 s per 8 beats without a grid).
func beatFrames(t *track, f Fit, n float64) int {
	bpm := 0.0
	if t.in.Rec != nil {
		bpm = t.in.Rec.BPM
	}
	if bpm <= 0 {
		return int(n / 2 * fps)
	}
	return int(n * 60 / (bpm * f.R) * fps)
}

// sustained is the first index i in [lo, hi) where ok holds for every index up to i+w
// (clipped to hi), or -1.
func sustained(lo, hi, w int, ok func(int) bool) int {
	if hi <= lo {
		return -1
	}
	run := make([]int, hi-lo+1) // run[i-lo]: how many indices from i on hold ok
	for i := hi - 1; i >= lo; i-- {
		if ok(i) {
			run[i-lo] = run[i-lo+1] + 1
		}
	}
	for i := lo; i < hi; i++ {
		if run[i-lo] > 0 && run[i-lo] >= min(w, hi-i) {
			return i
		}
	}
	return -1
}

// firstAudible is where the first track becomes audible.
func (a *aligner) firstAudible(t *track) float64 {
	f := t.pieces[0].Fit
	f0 := max(0, int(f.Rec(0)*fps))
	f1 := min(len(a.full), int(t.last().Rec(t.dur)*fps))
	if f1 <= f0 {
		return math.Max(f.Rec(0), 0)
	}
	m := t.mapped(t.full, f0, f1-f0)
	g, _ := gains(a.full[f0:f1], m, nil, beatFrames(t, f, 4))
	ref := a.refGain(t, t.full, a.full)
	i := sustained(0, len(g), beatFrames(t, f, 4), func(i int) bool { return g[i]/ref > Audible })
	if i < 0 {
		return float64(f0) / fps
	}
	return float64(f0+i) / fps
}

// lastAudible is where the last track stops being audible.
func (a *aligner) lastAudible(t *track) float64 {
	f := t.last()
	f0 := max(0, int(t.start*fps))
	f1 := min(len(a.full), int(f.Rec(t.dur)*fps))
	if f1 <= f0 {
		return math.Min(f.Rec(t.dur), a.dur)
	}
	m := t.mapped(t.full, f0, f1-f0)
	g, _ := gains(a.full[f0:f1], m, nil, beatFrames(t, f, 4))
	ref := a.refGain(t, t.full, a.full)
	for i := len(g) - 1; i >= 0; i-- {
		if g[i]/ref > Audible {
			return float64(f0+i+1) / fps
		}
	}
	return float64(f1) / fps
}

// transition finds where B (incoming) takes over from A, cuts there (snapped to B's phrase
// start) and works out the transition as played.
func (a *aligner) transition(A, B *track, sampleRate int) {
	e := B.entry
	prevCut := float64(A.entry.CutSample) / float64(sampleRate)
	takeover := a.takeover(A, B, prevCut)
	e.Takeover = FormatTime(takeover)
	cut, swap := a.cutAt(B, takeover, prevCut)
	e.CutSample = int64(math.Round(cut * float64(sampleRate)))
	e.Cut = FormatTime(float64(e.CutSample) / float64(sampleRate))
	if ar, br := A.in.Rec, B.in.Rec; ar != nil && br != nil && len(ar.Beats) > 0 && len(br.Beats) > 0 {
		e.Transition = played(A, B, swap, takeover)
	}
}

// takeover is where B takes over from A: over their overlap, the first sustained stretch
// where B explains the recording's bass better than A (each relative to its level playing
// alone). It also sets B's audible start and A's audible end.
func (a *aligner) takeover(A, B *track, prevCut float64) float64 {
	fa, fb := A.last(), B.pieces[0].Fit
	oStart, oEnd := fb.Rec(0), math.Min(fa.Rec(A.dur), a.dur)
	r0 := math.Max(math.Max(prevCut, A.start), math.Min(oStart, oEnd)-10)
	r1 := math.Min(a.dur, math.Max(oStart, oEnd)+10)
	f0, f1 := max(int(r0*fps), 0), min(int(r1*fps), len(a.bass))
	n := f1 - f0
	e := B.entry
	takeover, startB, endA := oStart, oStart, oEnd
	if n > 0 {
		w := beatFrames(A, fa, 8)
		ga, gb := gains(a.bass[f0:f1], A.mapped(A.bass, f0, n), B.mapped(B.bass, f0, n), w)
		a0, b0 := a.refGain(A, A.bass, a.bass), a.refGain(B, B.bass, a.bass)
		gaf, gbf := gains(a.full[f0:f1], A.mapped(A.full, f0, n), B.mapped(B.full, f0, n), w/2)
		a0f, b0f := a.refGain(A, A.full, a.full), a.refGain(B, B.full, a.full)
		idx := func(t float64) int { return min(max(int(t*fps)-f0, 0), n) }
		sec := func(i int) float64 { return float64(f0+i) / fps }
		lo, hi := idx(oStart), idx(oEnd)
		switch i := sustained(lo, hi, w/2, func(i int) bool { return gb[i]/b0 > ga[i]/a0 && gb[i]/b0 > Audible }); {
		case lo >= hi:
			e.Notes = append(e.Notes, "no overlap with the previous track")
		case i >= 0:
			takeover = sec(i)
		default:
			takeover = oEnd
			e.Notes = append(e.Notes, "no clear bass swap: cut where the previous track ends")
		}
		startB = takeover
		if i := sustained(lo, idx(takeover), w/2, func(i int) bool { return gbf[i]/b0f > Audible }); i >= 0 {
			startB = sec(i)
		}
		endA = takeover
		for i := idx(math.Min(oEnd, r1)) - 1; i >= idx(takeover); i-- {
			if gaf[i]/a0f > Audible {
				endA = sec(i + 1)
				break
			}
		}
	}
	startB, takeover = math.Max(startB, 0), math.Max(takeover, 0)
	B.start, A.end = math.Min(startB, takeover), math.Max(endA, takeover)
	return takeover
}

// cutAt is where B's file starts: the takeover moved to B's nearest phrase start (within
// SnapBeats), and that beat (0 when not snapped). It stays after the previous cut.
func (a *aligner) cutAt(B *track, takeover, prevCut float64) (cut float64, swap int) {
	e := B.entry
	cut = takeover
	if b := B.in.Rec; b != nil && len(b.Beats) > 0 {
		fb := B.fitAt(takeover)
		beat := tracks.BeatOf(b.Beats, fb.Track(takeover))
		if s := snapPhrase(b, beat, -SnapBeats, SnapBeats); s > 0 {
			beat = s
		}
		swap, cut = beat, fb.Rec(b.Beats[beat-1])
	}
	if cut <= prevCut+1 || cut >= a.dur {
		cut, swap = takeover, 0
		e.Notes = append(e.Notes, "the phrase start is outside the previous track's span: cut at the takeover")
	}
	if cut <= prevCut+1 {
		cut = math.Min(prevCut+1, a.dur)
		e.Status = LowConf
		e.Notes = append(e.Notes, "the takeover falls inside the previous track's file: check the cut")
	}
	return cut, swap
}

// played is the transition as played. E: where B started, at or before it became audible
// (the fader may come up much later). A DJ starts the incoming track on one of its cues,
// usually within a phrase of one of the outgoing track's hot cues: the latest of B's cues up
// to CueBeats before it was heard that falls that close to one of A's hot cues; else its
// latest cue up to a phrase before; else a phrase start. G is A's beat at that same moment,
// BASS SWAP the cut's beat (else the takeover's).
func played(A, B *track, swap int, takeover float64) *Transition {
	ar, br := A.in.Rec, B.in.Rec
	heard := tracks.BeatOf(br.Beats, B.fitAt(B.start).Track(B.start))
	gAt := func(eb int) int {
		te := B.fitAt(B.start).Rec(br.Beats[eb-1])
		return tracks.BeatOf(ar.Beats, A.fitAt(te).Track(te))
	}
	tr := &Transition{FromID: A.in.ID, FromTitle: A.in.Title}
	cueAt := 0
	for _, c := range br.Cues {
		cb := tracks.BeatOf(br.Beats, c.T)
		if cb > heard+setlist.Phrase/4 || cb < heard-CueBeats || cb < 1 {
			continue
		}
		name, near := nearHotCue(ar, gAt(cb))
		switch {
		case near && (tr.GCue == "" || cb > tr.E):
			tr.E, tr.ECue, tr.GCue = cb, cueName(c), name
		case tr.GCue == "" && cb <= heard && cb >= heard-SnapBeats && cb > cueAt:
			cueAt, tr.ECue = cb, cueName(c)
		}
	}
	switch {
	case tr.GCue != "":
	case cueAt > 0:
		tr.E = cueAt
	default:
		tr.E, tr.ECue = heard, ""
		for x := heard; x >= max(1, heard-SnapBeats); x-- {
			if setlist.OnPhrase(br, x) {
				tr.E = x
				break
			}
		}
	}
	tr.G = gAt(tr.E)
	if tr.GCue == "" {
		B.entry.Notes = append(B.entry.Notes, fmt.Sprintf("started at beat %d, on beat %d of the previous track: not "+
			"within %d beats of one of its hot cues, check this transition", tr.E, tr.G, SnapBeats))
	}
	tr.BassSwap = swap
	if swap == 0 {
		tr.BassSwap = tracks.BeatOf(br.Beats, B.fitAt(takeover).Track(takeover))
	}
	return tr
}

// nearHotCue is t's hot cue nearest beat g, as "<cue> +n beats", and whether it is within
// SnapBeats.
func nearHotCue(t *tracks.Track, g int) (string, bool) {
	best, name := SnapBeats+1, ""
	for _, c := range t.Cues {
		if c.Kind == 0 {
			continue
		}
		if d := g - tracks.BeatOf(t.Beats, c.T); abs(d) < abs(best) || (abs(d) == abs(best) && d > best) {
			best, name = d, fmt.Sprintf("%s %+d beats", cueName(c), d)
		}
	}
	return name, abs(best) <= SnapBeats
}

// cueName is a cue as the report names it: "C DROP" for a hot cue, "mem DROP" for a memory cue.
func cueName(c db.Cue) string {
	slot := "mem"
	for name, k := range config.Kind {
		if k == c.Kind && k > 0 {
			slot = name
		}
	}
	return strings.TrimSpace(slot + " " + c.Name)
}

// snapPhrase is the phrase start nearest beat b within [b+lo, b+hi] (the earlier on a tie),
// or 0.
func snapPhrase(t *tracks.Track, b, lo, hi int) int {
	best := 0
	for x := max(1, b+lo); x <= min(len(t.Beats), b+hi); x++ {
		if setlist.OnPhrase(t, x) && (best == 0 || abs(x-b) < abs(best-b)) {
			best = x
		}
	}
	return best
}

// ------------------------------------------------------------------ times

// FormatTime is seconds as h:mm:ss.sss.
func FormatTime(s float64) string {
	ms := int64(math.Round(s * 1000))
	return fmt.Sprintf("%d:%02d:%02d.%03d", ms/3600000, ms/60000%60, ms/1000%60, ms%1000)
}

// ErrTime means a time isn't h:mm:ss.sss (or m:ss.sss, or seconds).
var ErrTime = errors.New("not a time like 1:02:03.456")

// ParseTime reads h:mm:ss.sss, m:ss.sss or plain seconds.
func ParseTime(v string) (float64, error) {
	parts := strings.Split(strings.TrimSpace(v), ":")
	if len(parts) > 3 {
		return 0, fmt.Errorf("%w: %q", ErrTime, v)
	}
	s := 0.0
	for i, p := range parts {
		x, err := strconv.ParseFloat(p, 64)
		if err != nil || x < 0 || (i > 0 && x >= 60) {
			return 0, fmt.Errorf("%w: %q", ErrTime, v)
		}
		s = s*60 + x
	}
	return s, nil
}
