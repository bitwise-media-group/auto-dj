// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package rules holds the cue-placement rules.
//
// Inputs per track (see the tracks package):
//
//	Beats   - Rekordbox beat grid times (s); index i is beat i+1
//	BNum    - beat-in-bar number (1..4) for each beat
//	Phrases - Rekordbox phrase starts [(beat, Intro|Up|Down|Chorus|Outro), ...]
//	FB      - optional per-beat band energies (features package); without it the rules fall
//	          back to phrase labels only (e.g. streaming tracks)
//
// All positions are 1-based beat indices. Everything snaps to the "grid": Rekordbox phrase
// starts plus every 16 beats from the first downbeat. See docs/DECISIONS.md for the why.
package rules

import (
	"math"
	"slices"

	"github.com/bitwise-media-group/adj/internal/config"
	"github.com/bitwise-media-group/adj/internal/num"
	"github.com/bitwise-media-group/adj/internal/tracks"
)

// Segment is a phrase as [Start, End) with its label.
type Segment struct {
	Start, End int
	Label      string
}

// Segments returns the phrases covering the whole track, and the beat count.
func Segments(t *tracks.Track) ([]Segment, int) {
	nb := len(t.Beats)
	segs := make([]Segment, len(t.Phrases))
	for i, p := range t.Phrases {
		e := nb + 1
		if i+1 < len(t.Phrases) {
			e = t.Phrases[i+1].Beat
		}
		segs[i] = Segment{p.Beat, e, p.Label}
	}
	return segs, nb
}

// Hot maps cue names (IN, BRIDGE, DROP, OUT, EMERGENCY, plus the BASS_END diagnostic) to
// beats; a missing name means no such cue.
type Hot map[string]int

// FirstDownbeat is the first beat of the first full bar (np.argmax(bnum == 1) + 1).
func FirstDownbeat(t *tracks.Track) int {
	for i, b := range t.BNum {
		if b == 1 {
			return i + 1
		}
	}
	return 1
}

// Grid is the sorted union of the phrase starts and every 16 beats from d1 to nb.
func Grid(starts []int, d1, nb int) []int {
	set := map[int]bool{}
	for _, s := range starts {
		set[s] = true
	}
	for b := d1; b <= nb; b += 16 {
		set[b] = true
	}
	out := make([]int, 0, len(set))
	for b := range set {
		out = append(out, b)
	}
	slices.Sort(out)
	return out
}

// pyMax is Python's max(a, b): b only when b > a, so a NaN first argument wins.
func pyMax(a, b float64) float64 {
	if b > a {
		return b
	}
	return a
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

func starts(segs []Segment) []int {
	out := make([]int, len(segs))
	for i, s := range segs {
		out[i] = s.Start
	}
	return out
}

// minKey returns the first element with the smallest key (Python's min(xs, key=...)).
func minKey(xs []int, key func(int) float64) int {
	best, bk := xs[0], key(xs[0])
	for _, x := range xs[1:] {
		if k := key(x); k < bk {
			best, bk = x, k
		}
	}
	return best
}

func filter(xs []int, keep func(int) bool) []int {
	var out []int
	for _, x := range xs {
		if keep(x) {
			out = append(out, x)
		}
	}
	return out
}

// hotCtx is what the hot cue steps share.
type hotCtx struct {
	R     config.Rules
	segs  []Segment
	nb    int
	lo    []float64 // normalised bass level per beat, nil without audio analysis
	st    []int     // phrase starts
	grid  []int
	out   Hot
	em    int // EMERGENCY
	first int // first Chorus
}

// bass is the mean bass over beats [a, b); ok is false without audio analysis.
func (c *hotCtx) bass(a, b int) (float64, bool) {
	if c.lo == nil {
		return 0, false
	}
	a, b = max(a-1, 0), min(b-1, c.nb)
	if b > a {
		return num.Mean(c.lo[a:b]), true
	}
	return 0, true
}

func (c *hotCtx) bassV(a, b int) float64 {
	v, _ := c.bass(a, b)
	return v
}

func (c *hotCtx) isStart(b int) bool { return slices.Contains(c.st, b) }

// HotCues places IN, BRIDGE?, DROP?, OUT and EMERGENCY (plus the BASS_END diagnostic).
func HotCues(t *tracks.Track, R config.Rules) Hot {
	segs, nb := Segments(t)
	c := &hotCtx{R: R, segs: segs, nb: nb, st: starts(segs), out: Hot{}, first: 1}
	if t.HasFB() {
		c.lo = tracks.NormLevel(t.Col(0))
	}
	c.grid = Grid(c.st, FirstDownbeat(t), nb)
	for _, s := range segs {
		if s.Label == "Chorus" {
			c.first = s.Start
			break
		}
	}
	c.placeIn()
	c.placeEmergency()
	r := c.chooseBridge(c.breakdownRuns())
	if r == nil { // fallback: a mid-track Rekordbox 'Down' phrase, else the lowest-bass window
		r = c.fallbackBridge()
	}
	if r != nil && r[1]-r[0] < R.BridgeMin { // user rule: < 16 beats means "no bridge"
		r = nil
	}
	c.placeDrop(r)
	c.placeOut()
	c.keepOrder()
	return c.out
}

// placeIn: start of the first phrase after Rekordbox's Intro, kept within beats 33..129.
func (c *hotCtx) placeIn() {
	introEnd := 1
	for _, s := range c.segs {
		if s.Label != "Intro" {
			introEnd = s.Start
			break
		}
	}
	if introEnd > c.R.InMax || introEnd < c.R.InMin {
		cand := filter(c.st, func(b int) bool { return 33 <= b && b <= c.R.InMax })
		introEnd = 33
		if len(cand) > 0 {
			introEnd = cand[0]
		}
	}
	c.out["IN"] = introEnd
}

// placeEmergency: a 32-beat loop near nb-68, on the grid, with bass throughout, ending
// before the bass runs out.
func (c *hotCtx) placeEmergency() {
	nb := c.nb
	be := nb
	if c.lo != nil {
		be = bassEnd(c.lo, nb, c.R.BassPresent)
		c.out["BASS_END"] = be
	}
	target := nb - c.R.EmBack
	cands := filter(c.grid, func(b int) bool { return b+32 <= min(nb-8, be) && float64(b) > float64(nb)*0.6 })
	if c.lo != nil {
		good := filter(cands, func(b int) bool { return c.bassV(b, b+32) >= c.R.BassPresent })
		if len(good) > 0 {
			cands = good
		}
	}
	c.em = nb - 64
	if len(cands) > 0 {
		c.em = minKey(cands, func(b int) float64 {
			k := abs(b - target)
			if c.isStart(b) {
				k -= c.R.PhraseBonus
			}
			return float64(k)
		})
	}
	c.out["EMERGENCY"] = c.em
}

// bassEnd is the last beat whose preceding 16 beats still have bass (searching the second
// half of the track), else nb.
func bassEnd(lo []float64, nb int, present float64) int {
	for b := nb; b > int(float64(nb)*0.5); b-- {
		hi := min(max(b-1, 0), len(lo))
		if num.Mean(lo[min(max(0, b-17), hi):hi]) >= present {
			return b
		}
	}
	return nb
}

// breakdownRuns are the runs of phrases without bass (or Rekordbox 'Down' phrases).
func (c *hotCtx) breakdownRuns() [][2]int {
	startsBreak := func(s Segment) bool {
		if b, ok := c.bass(s.Start, s.End); ok {
			return b < c.R.BassLow || (s.Label == "Down" && b < 0.6)
		}
		return s.Label == "Down"
	}
	contBreak := func(s Segment) bool {
		if b, ok := c.bass(s.Start, s.End); ok {
			return b < c.R.BassCont
		}
		return s.Label == "Down" || s.Label == "Up"
	}
	var runs [][2]int
	cur := -1 // index into runs of the run being extended
	for _, s := range c.segs {
		if s.Label == "Intro" || s.Label == "Outro" {
			cur = -1
			continue
		}
		switch {
		case cur >= 0 && runs[cur][1] == s.Start && contBreak(s):
			runs[cur][1] = s.End
		case startsBreak(s):
			runs = append(runs, [2]int{s.Start, s.End})
			cur = len(runs) - 1
		default:
			cur = -1
		}
	}
	return runs
}

// chooseBridge picks the breakdown: after the first chorus, not in the last quarter,
// followed by a chorus; the first big one unless a later one is at least twice as long,
// else the longest.
func (c *hotCtx) chooseBridge(runs [][2]int) *[2]int {
	var ok, big [][2]int
	for _, r := range runs {
		if r[0] <= c.first || float64(r[0]) > 0.75*float64(c.nb) {
			continue
		}
		if slices.ContainsFunc(c.segs, func(s Segment) bool {
			return s.Label == "Chorus" && r[1] <= s.Start && s.Start <= c.em-16
		}) {
			ok = append(ok, r)
			if r[1]-r[0] >= c.R.BridgeBig {
				big = append(big, r)
			}
		}
	}
	if len(big) > 0 {
		r := &big[0]
		for i := 1; i < len(big); i++ {
			if big[i][1]-big[i][0] >= 2*(r[1]-r[0]) {
				return &big[i]
			}
		}
		return r
	}
	if len(ok) == 0 {
		return nil
	}
	r := &ok[0]
	for i := 1; i < len(ok); i++ {
		if ok[i][1]-ok[i][0] > r[1]-r[0] {
			r = &ok[i]
		}
	}
	return r
}

// fallbackBridge is a mid-track Rekordbox 'Down' phrase, else the lowest-bass window.
func (c *hotCtx) fallbackBridge() *[2]int {
	nb := float64(c.nb)
	for _, s := range c.segs {
		if s.Label == "Down" && 0.25*nb <= float64(s.Start) && float64(s.Start) <= math.Min(0.75*nb, float64(c.em-48)) &&
			s.Start > c.first {
			return &[2]int{s.Start, s.End}
		}
	}
	if c.lo == nil {
		return nil
	}
	cand := filter(c.st, func(b int) bool {
		return 0.25*nb <= float64(b) && float64(b) <= math.Min(0.7*nb, float64(c.em-48))
	})
	if len(cand) == 0 {
		return nil
	}
	b := minKey(cand, func(b int) float64 { return c.bassV(b, b+32) })
	if c.bassV(b, b+16) >= c.R.BassLow {
		return nil
	}
	r := &[2]int{b, b + 16}
	for r[1] < c.nb && c.bassV(r[1], r[1]+16) < c.R.BassCont {
		r[1] += 16
	}
	return r
}

// placeDrop: with a bridge, the first Chorus after it; without one, the first bass return
// after a break past IN, else the first Chorus after IN.
func (c *hotCtx) placeDrop(r *[2]int) {
	if r != nil {
		c.out["BRIDGE"] = r[0]
		c.out["DROP"] = r[1]
		for _, s := range c.segs {
			if s.Start >= r[1] && s.Label == "Chorus" {
				c.out["DROP"] = s.Start
				break
			}
		}
		return
	}
	in := c.out["IN"]
	var ev []int
	for _, s := range c.segs {
		if s.Label == "Chorus" && s.Start > in && s.Start <= c.em-32 {
			ev = append(ev, s.Start)
		}
	}
	if c.lo != nil {
		evb := filter(c.grid, func(b int) bool {
			return in < b && b <= c.em-32 && c.bassV(b, b+16) >= c.R.DropOn && c.bassV(b-16, b) <= c.R.BassLow
		})
		if len(evb) > 0 {
			ev = evb
		}
	}
	if len(ev) > 0 {
		c.out["DROP"] = ev[0]
	}
}

// placeOut: the grid point ~64 beats before EMERGENCY (32..128 allowed) with bass present.
func (c *hotCtx) placeOut() {
	em := c.em
	cands := filter(c.grid, func(b int) bool {
		return em-128 <= b && b <= em-32 && (c.lo == nil || c.bassV(b, b+16) >= c.R.BassPresent)
	})
	c.out["OUT"] = em - 64
	if len(cands) == 0 {
		return
	}
	key := func(b int) int {
		k := abs((em - b) - 64)
		if c.isStart(b) {
			k -= c.R.PhraseBonus
		}
		return k
	}
	best := cands[0]
	for _, b := range cands[1:] { // min by (key, b)
		if kb, kc := key(b), key(best); kb < kc || (kb == kc && b < best) {
			best = b
		}
	}
	c.out["OUT"] = best
}

// keepOrder keeps IN < BRIDGE < DROP < OUT < EMERGENCY on short edits.
func (c *hotCtx) keepOrder() {
	drop, has := c.out["DROP"]
	if !has || c.out["OUT"] > drop {
		return
	}
	if later := filter(c.grid, func(b int) bool { return drop+32 <= b && b <= c.em-16 }); len(later) > 0 {
		c.out["OUT"] = later[0]
		return
	}
	ems := filter(c.grid, func(b int) bool { return b >= drop+16 && b+32 <= c.nb+1 })
	if len(ems) == 0 {
		return
	}
	c.out["EMERGENCY"] = ems[0]
	o2 := filter(c.grid, func(b int) bool { return drop+8 <= b && b <= ems[0]-8 })
	c.out["OUT"] = drop + 8
	if len(o2) > 0 {
		c.out["OUT"] = o2[len(o2)-1]
	}
}

// Memory is the memory cue placement: START, the DROPs and an optional BASS SWAP (0 = none).
type Memory struct {
	Start    int
	Drops    []int
	BassSwap int
}

// memCtx is what the memory cue steps share.
type memCtx struct {
	R      config.Rules
	segs   []Segment
	st     []int
	nb     int
	lo, lm []float64 // normalised sub and low-mid levels
	hot    Hot
	outB   int // OUT, else the last beat
}

// mean is the mean of arr over beats [a, b) (0 unless b > a >= 1).
func mean(arr []float64, a, b int) float64 {
	if b <= a || a < 1 {
		return 0
	}
	j := min(max(b-1, 0), len(arr))
	return num.Mean(arr[min(a-1, j):j])
}

func (c *memCtx) label(b int) string {
	for _, s := range c.segs {
		if s.Start <= b && b < s.End {
			return s.Label
		}
	}
	return ""
}

// MemoryCues places START, the memory DROPs and the BASS SWAP.
func MemoryCues(t *tracks.Track, hot Hot, R config.Rules) Memory {
	segs, nb := Segments(t)
	c := &memCtx{R: R, segs: segs, st: starts(segs), nb: nb, hot: hot}
	d1 := FirstDownbeat(t)
	res := Memory{Start: d1, Drops: []int{}}
	var hasOut bool
	if c.outB, hasOut = hot["OUT"]; !hasOut {
		c.outB = nb
	}
	if !t.HasFB() { // phrase-only fallback: every Chorus that follows a non-Chorus
		res.Drops = c.phraseDrops()
		return res
	}
	c.lo, c.lm = tracks.NormLevel(t.Col(0)), tracks.NormLevel(t.Col(1))
	grid := Grid(c.st, d1, nb)
	ev := c.bassEntries(grid, d1)
	res.BassSwap = c.bassSwap(grid, ev)
	res.Drops = c.drops(ev, res.BassSwap)
	return res
}

func (c *memCtx) phraseDrops() []int {
	set := map[int]bool{}
	for i, s := range c.segs {
		if s.Label == "Chorus" && i > 0 && c.segs[i-1].Label != "Chorus" && c.hot["IN"] < s.Start && s.Start < c.outB {
			set[s.Start] = true
		}
	}
	if d, ok := c.hot["DROP"]; ok {
		set[d] = true
	}
	return sortedKeys(set)
}

// bassEntries are the grid beats (snapped to a phrase start within 4 beats) where the bass
// comes in hard after 16 quiet beats.
func (c *memCtx) bassEntries(grid []int, d1 int) []int {
	snap := func(b int) int {
		for _, s := range c.st {
			if abs(s-b) <= 4 {
				return s
			}
		}
		return b
	}
	set := map[int]bool{}
	for _, b := range grid {
		if d1 < b && b <= c.nb-32 && mean(c.lo, b, b+16) >= c.R.DropOn && mean(c.lo, b-16, b) <= c.R.DropOff &&
			mean(c.lo, b-8, b) <= c.R.DropOff {
			set[snap(b)] = true
		}
	}
	return sortedKeys(set)
}

// bassSwap is the first bass entry >= 16 beats after IN and before the bridge, else the
// biggest sub/low-mid jump in that window (0 = none).
func (c *memCtx) bassSwap(grid, ev []int) int {
	in := c.hot["IN"]
	lim, ok := c.hot["BRIDGE"]
	if !ok {
		lim = c.nb / 2
	}
	if bs := filter(ev, func(b int) bool { return in+16 <= b && b < lim }); len(bs) > 0 {
		return bs[0]
	}
	var bestJ float64
	bestB := 0
	for _, b := range grid {
		if b < in+16 || b >= lim {
			continue
		}
		j := pyMax(mean(c.lo, b, b+16)-mean(c.lo, b-16, b), mean(c.lm, b, b+16)-mean(c.lm, b-16, b))
		if slices.Contains(c.st, b) {
			j += 0.05
		}
		if j >= c.R.BassSwapMin && (bestB == 0 || j > bestJ) {
			bestJ, bestB = j, b
		}
	}
	return bestB
}

// drops are the bass entries after a >= 32-beat low-bass stretch, on a Chorus, before OUT,
// at least 32 beats apart.
func (c *memCtx) drops(ev []int, bassSwap int) []int {
	isDrop := func(b int) bool {
		return mean(c.lo, b-c.R.DropPre, b) <= c.R.DropOff && (c.label(b) == "Chorus" || !c.R.DropNeedsChorus)
	}
	after := bassSwap
	if after == 0 {
		after = c.hot["IN"]
	}
	dr := map[int]bool{}
	for _, b := range ev {
		if (after < b || (b == after && mean(c.lo, b-64, b) <= c.R.DropOff)) && b < c.outB && isDrop(b) {
			dr[b] = true
		}
	}
	if d, ok := c.hot["DROP"]; ok {
		dr[d] = true
	}
	out := []int{}
	for _, b := range sortedKeys(dr) {
		if n := len(out); n > 0 && b-out[n-1] < 32 {
			continue
		}
		out = append(out, b)
	}
	return out
}

func sortedKeys(m map[int]bool) []int {
	out := make([]int, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	slices.Sort(out)
	return out
}
