// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package setlist plans set-specific cues for a Rekordbox playlist.
//
// For each transition A -> B in the playlist order:
//   - A gets G = reserved OUT point, named after B (default: A's OUT hot cue)
//   - B gets E = reserved IN point, named after A (default: B's IN hot cue, moved earlier if
//     needed so B's bass swap lands before A runs out)
//   - B gets a BASS SWAP IN memory cue on a phrase, inside the overlap, unless it would sit
//     on a drop
//   - every transition marker is on both tracks, named by side: BASS SWAP IN / OUT, and where
//     A leaves the mix (its FILTER or CUT memory cue, or B's) FILTER IN / OUT or CUT IN / OUT,
//     and for an instant mashup (a SYNC memory cue on A's G or B's E) SYNC IN / OUT
//
// First track: E = START (first downbeat). Last track: no G.
//
// Mixing model: tracks are beat-matched, so positions are compared in beats (each track's
// own Rekordbox grid; at a common 120 BPM the grids line up). When A reaches G, B is started
// at E. B beat = E + (A beat - G). A "phrase" is 16 beats counted from the track's first
// downbeat.
//
// A transition is aligned when E and G sit at the same position in their phrase (so every
// phrase start in B lands on a phrase start in A, bass swap included), or when B starts a
// new phrase exactly as A finishes (letting A play to the end).
package setlist

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/bitwise-media-group/adj/internal/config"
	"github.com/bitwise-media-group/adj/internal/db"
	"github.com/bitwise-media-group/adj/internal/num"
	"github.com/bitwise-media-group/adj/internal/pairs"
	"github.com/bitwise-media-group/adj/internal/rules"
	"github.com/bitwise-media-group/adj/internal/tracks"
)

// Phrase is the phrase length in beats.
const Phrase = 16

// ------------------------------------------------------------------ action types

// Slot is an E or G hot cue decision. Status: existing (left as is) | new (empty slot) |
// replace (slot overwritten; Old cached) | clear (last track's G removed).
type Slot struct {
	Name   string
	Beat   int
	Status string
	Old    *Old
}

// Old is the cue a slot replaces.
type Old struct {
	Name string
	Beat int
}

// MarshalJSON writes [name, beat, status, old] like the Python version's tuple.
func (s Slot) MarshalJSON() ([]byte, error) {
	var old any
	if s.Old != nil {
		old = []any{s.Old.Name, s.Old.Beat}
	}
	return json.Marshal([]any{s.Name, s.Beat, s.Status, old})
}

// Marker is a memory cue that should be on a track: status existing | rename | new. For
// removals the status field holds the reason.
type Marker struct {
	Name   string
	Beat   int
	Status string
}

// MarshalJSON writes [name, beat, status].
func (m Marker) MarshalJSON() ([]byte, error) { return json.Marshal([]any{m.Name, m.Beat, m.Status}) }

// BassSwap is the planned BASS SWAP IN beat (0 = none) and why.
type BassSwap struct {
	Beat int
	Why  string
}

// MarshalJSON writes [beat|null, why].
func (b BassSwap) MarshalJSON() ([]byte, error) {
	var beat any
	if b.Beat != 0 {
		beat = b.Beat
	}
	return json.Marshal([]any{beat, b.Why})
}

// Exit is where the outgoing track leaves the mix: FILTER | CUT, its beat in the outgoing
// track (A), the same moment in the incoming one (B), and which track has the cue (out | in).
type Exit struct {
	Name string
	A, B int
	Side string
}

// MarshalJSON writes [name, a, b, side].
func (e Exit) MarshalJSON() ([]byte, error) { return json.Marshal([]any{e.Name, e.A, e.B, e.Side}) }

// Action is everything `set` decides for one track.
type Action struct {
	ID       string    `json:"id"`
	Title    string    `json:"title"`
	E        *Slot     `json:"E"`
	G        *Slot     `json:"G"`
	BassSwap *BassSwap `json:"bass_swap"`
	Warnings []string  `json:"warnings"`
	Exit     *Exit     `json:"exit"`
	Sync     bool      `json:"sync"`
	Markers  []Marker  `json:"markers"`
	Remove   []Marker  `json:"remove"`
	// Swap is B's bass swap beat for the previews: the BASS SWAP, else the drop it would sit on.
	// It is set (possibly nil) on every track a transition comes into.
	Swap    *int `json:"-"`
	swapSet bool
}

// MarshalJSON adds "swap" (possibly null) to the tracks a transition comes into, as the
// Python version did.
func (a Action) MarshalJSON() ([]byte, error) {
	type plain Action
	b, err := json.Marshal(plain(a))
	if err != nil || !a.swapSet {
		return b, err
	}
	sw, err := json.Marshal(a.Swap)
	if err != nil {
		return nil, err
	}
	return append(append(b[:len(b)-1], `,"swap":`...), append(sw, '}')...), nil
}

// ToDB converts the actions into what db.ApplySet writes.
func ToDB(acts []Action) []db.SetCues {
	out := make([]db.SetCues, 0, len(acts))
	for _, a := range acts {
		c := db.SetCues{ID: a.ID, Title: a.Title}
		if a.E != nil {
			c.E = &db.SetSlot{Name: a.E.Name, Beat: a.E.Beat, Status: a.E.Status}
		}
		if a.G != nil {
			c.G = &db.SetSlot{Name: a.G.Name, Beat: a.G.Beat, Status: a.G.Status}
		}
		for _, m := range a.Markers {
			c.Markers = append(c.Markers, db.SetMarker(m))
		}
		for _, m := range a.Remove {
			c.Remove = append(c.Remove, db.SetMarker(m))
		}
		out = append(out, c)
	}
	return out
}

// ------------------------------------------------------------------ names

// CueName is 'The Lost Hawk (Original Mix)' -> 'LOST HAWK' (Deavon's style: no mix name, no 'The').
func CueName(title string) string { return strings.ToUpper(tracks.TitleStem(title)) }

// NamesMatch is a fuzzy match: hand-typed set cues have typos ('DIALOG', 'RAJ').
func NamesMatch(cue, title string) bool {
	a, b := tracks.TitleStem(cue), tracks.TitleStem(title)
	if a == "" || b == "" {
		return false
	}
	return a == b || strings.HasPrefix(b, a) || strings.HasPrefix(a, b) || pairs.Ratio(a, b) >= 0.6
}

// ------------------------------------------------------------------ geometry

func beatOf(t *tracks.Track, sec float64) int { return tracks.BeatOf(t.Beats, sec) }

// GridPhase is the beats since the last 16-beat boundary counted from the first downbeat.
func GridPhase(t *tracks.Track, b int) int { return pyMod(b-rules.FirstDownbeat(t), Phrase) }

// PhrasePhase is the beats since the current Rekordbox phrase started. It catches tracks whose
// phrasing shifts by half a phrase mid-track. Only phrase starts on a bar downbeat count,
// because Rekordbox sometimes puts one a beat off.
func PhrasePhase(t *tracks.Track, b int) int {
	nb := len(t.BNum)
	base := rules.FirstDownbeat(t)
	for _, p := range t.Phrases {
		s := p.Beat
		if s <= b && s <= nb && pyIndex(t.BNum, s-1) == 1 {
			base = s
		}
	}
	return pyMod(b-base, Phrase)
}

// pyIndex is xs[i] with Python's negative indexing.
func pyIndex(xs []int, i int) int {
	if i < 0 {
		i += len(xs)
	}
	if i < 0 || i >= len(xs) {
		return 0
	}
	return xs[i]
}

var models = []func(*tracks.Track, int) int{GridPhase, PhrasePhase}

// SamePhase reports whether beat ya in a and beat yb in b sit at the same place in a phrase
// (either model).
func SamePhase(a *tracks.Track, ya int, b *tracks.Track, yb int) bool {
	return slices.ContainsFunc(models, func(m func(*tracks.Track, int) int) bool { return m(a, ya) == m(b, yb) })
}

// BothOnPhrase reports whether both beats start a phrase under the same model.
func BothOnPhrase(a *tracks.Track, ya int, b *tracks.Track, yb int) bool {
	return slices.ContainsFunc(models, func(m func(*tracks.Track, int) int) bool { return m(a, ya) == 0 && m(b, yb) == 0 })
}

// OnPhrase reports whether beat b starts a phrase under either model.
func OnPhrase(t *tracks.Track, b int) bool {
	return slices.ContainsFunc(models, func(m func(*tracks.Track, int) int) bool { return m(t, b) == 0 })
}

// OffPhrase is "" on a phrase start, else how far into the phrase b is (Rekordbox's phrases).
func OffPhrase(t *tracks.Track, b int) string {
	if OnPhrase(t, b) {
		return ""
	}
	return fmt.Sprintf("%d beats into a phrase", PhrasePhase(t, b))
}

// LastAudioBeat is the last beat with audio within 20 dB of the track's loud parts.
func LastAudioBeat(t *tracks.Track) int {
	if !t.HasFB() {
		return len(t.Beats)
	}
	tot := make([]float64, len(t.FB))
	for i, r := range t.FB {
		tot[i] = math.Log10(num.Sum(r[:4]) + 1e-9)
	}
	thr := num.Percentile(tot, 90) - 2.0
	for i := len(tot) - 1; i >= 0; i-- {
		if tot[i] > thr {
			return i + 1
		}
	}
	return len(t.Beats)
}

// BassEndBeat is where the track's bass ends.
func BassEndBeat(t *tracks.Track) int {
	nb := len(t.Beats)
	if !t.HasFB() {
		return nb
	}
	lo := tracks.NormLevel(t.Col(0))
	for b := nb; b > nb/2; b-- {
		i, j := max(0, b-17), max(b-1, 0)
		if num.Mean(lo[min(i, j):j]) >= 0.45 {
			return b
		}
	}
	return nb
}

// Alignment is how a transition lines up.
type Alignment struct {
	PhraseAligned, EndsOnPhrase bool
	Offset                      int
}

// Align says how transition a (out at beat g) -> b (in at beat e) lines up.
func Align(a *tracks.Track, g int, b *tracks.Track, e int) Alignment {
	last := LastAudioBeat(a)
	// B's beat at A's final beat (or just after it): a new phrase there = 'play to the end' mix
	ends := OnPhrase(b, e+(last-g)) || OnPhrase(b, e+(last+1-g))
	off := math.MaxInt
	for _, m := range models {
		off = min(off, pyMod(m(b, e)-m(a, g), Phrase))
	}
	return Alignment{SamePhase(a, g, b, e), ends, off}
}

// ------------------------------------------------------------------ planning

// bassSwap finds a phrase-aligned bass swap point in b inside the overlap: where b's bass
// comes in and/or a's bass drops out, on a phrase start in both tracks. 0 = none.
func bassSwap(a *tracks.Track, g int, b *tracks.Track, e int, drops, existing []int) (int, string) {
	overlapEnd := e + (BassEndBeat(a) - g)             // b's beat when a's bass ends
	hardEnd := max(overlapEnd, e+(LastAudioBeat(a)-g)) // ... and when a has finished
	// the user's own BASS SWAP wins inside the overlap, phrase-aligned or not
	for _, x := range existing {
		if e+16 <= x && x <= hardEnd {
			return x, "existing"
		}
	}
	if !b.HasFB() || !a.HasFB() {
		return 0, "no audio analysis"
	}
	lb, la := tracks.NormLevel(b.Col(0)), tracks.NormLevel(a.Col(0))
	mean := func(lo []float64, s, t int) float64 {
		s, t = max(s, 1), min(t, len(lo)+1)
		if t > s {
			return num.Mean(lo[s-1 : t-1])
		}
		return 0
	}
	bestX, bestScore := 0, 0.0
	for _, limit := range []int{overlapEnd, hardEnd} {
		for x := e + 16; x <= min(limit, len(b.Beats)-16); x++ {
			if e+16 > x || x > limit || !BothOnPhrase(b, x, a, x-e+g) {
				continue
			}
			y := x - e + g // same moment in a
			score := (mean(lb, x, x+16) - mean(lb, x-16, x)) + pyMax(0, mean(la, y-16, y)-mean(la, y, y+16))
			if score >= 0.3 && (bestX == 0 || score > bestScore+0.15) {
				bestX, bestScore = x, score
			}
		}
		if bestX != 0 {
			break
		}
	}
	if bestX == 0 {
		return 0, "no clear bass change inside the overlap"
	}
	if slices.ContainsFunc(drops, func(d int) bool { return abs(bestX-d) <= 1 }) {
		return 0, fmt.Sprintf("bass comes in on a drop (beat %d); no BASS SWAP needed", bestX)
	}
	return bestX, "new"
}

// pyMax is Python's max(a, b) (a wins unless b > a, so a NaN b loses).
func pyMax(a, b float64) float64 {
	if b > a {
		return b
	}
	return a
}

// chooseE picks E for incoming u: the nearest beat at/before e0 with the same phrase
// position as G in t, moving earlier only when that is what makes a bass swap fit.
func chooseE(t *tracks.Track, g int, u *tracks.Track, e0 int, drops, bss []int) int {
	var cands []int
	for c := e0; c > rules.FirstDownbeat(u)-1 && len(cands) < 8; c-- {
		if SamePhase(t, g, u, c) {
			cands = append(cands, c)
		}
	}
	if len(cands) == 0 {
		for c := e0; c < e0+Phrase; c++ {
			if SamePhase(t, g, u, c) {
				cands = []int{c}
				break
			}
		}
	}
	if len(cands) == 0 {
		cands = []int{e0}
	}
	for _, c := range cands {
		if bs, why := bassSwap(t, g, u, c, drops, bss); bs != 0 || strings.Contains(why, "drop") {
			return c
		}
	}
	return cands[0]
}

// exitNames are the memory cues where the outgoing track leaves the mix.
var exitNames = []string{"FILTER", "CUT"}

// MemName is a memory cue's name as `set --write` leaves it (config.RenameTo applied).
func MemName(c db.Cue) string {
	if to := config.RenameTo(c.Name, false); to != "" {
		return to
	}
	return config.Norm(c.Name)
}

// markerBase is 'CUT' for 'CUT OUT' on side 'OUT'; plain 'CUT' counts for either side.
func markerBase(name, side string) string {
	for _, base := range []string{"BASS SWAP", "FILTER", "CUT"} {
		if name == base || name == base+" "+side {
			return base
		}
	}
	return ""
}

// exitMarker is where a leaves the mix: the first FILTER / CUT (or ... OUT) memory cue at or
// after G in a, or FILTER / CUT (or ... IN) at or after E in b while a is still playing. A CUT
// in b beats any CUT in a: a CUT OUT that doesn't line up with the next track's CUT IN gets
// removed (staleCues).
func exitMarker(a *tracks.Track, g int, b *tracks.Track, e int) *Exit {
	last := len(a.Beats)
	type found struct {
		beat       int
		name, side string
	}
	var fs []found
	for _, c := range a.Cues {
		if n := markerBase(MemName(c), "OUT"); c.Kind == 0 && slices.Contains(exitNames, n) && beatOf(a, c.T) >= g {
			fs = append(fs, found{beatOf(a, c.T), n, "out"})
		}
	}
	for _, c := range b.Cues {
		if n := markerBase(MemName(c), "IN"); c.Kind == 0 && slices.Contains(exitNames, n) {
			if y := beatOf(b, c.T); e <= y && y <= e+last-g {
				fs = append(fs, found{g + y - e, n, "in"})
			}
		}
	}
	if slices.ContainsFunc(fs, func(f found) bool { return f.name == "CUT" && f.side == "in" }) {
		fs = slices.DeleteFunc(fs, func(f found) bool { return f.name == "CUT" && f.side == "out" })
	}
	if len(fs) == 0 {
		return nil
	}
	m := slices.MinFunc(fs, func(x, y found) int {
		if x.beat != y.beat {
			return x.beat - y.beat
		}
		if c := strings.Compare(x.name, y.name); c != 0 {
			return c
		}
		return strings.Compare(x.side, y.side)
	})
	return &Exit{m.name, m.beat, e + m.beat - g, m.side}
}

// sync is an instant mashup: a SYNC (or SYNC OUT) memory cue on a's G, or SYNC (or SYNC IN)
// on b's E, within a beat. b then comes in at E at full volume.
func sync(a *tracks.Track, g int, b *tracks.Track, e int) bool {
	on := func(t *tracks.Track, beat int, side string) bool {
		return slices.ContainsFunc(t.Cues, func(c db.Cue) bool {
			n := MemName(c)
			return c.Kind == 0 && (n == "SYNC" || n == "SYNC "+side) && abs(beatOf(t, c.T)-beat) <= 1
		})
	}
	return on(a, g, "OUT") || on(b, e, "IN")
}

// marker is the transition marker '<base> <side>' that should be on t at beat.
// Status: existing | rename (a plain '<base>' cue is there; gets the side added) | new.
func marker(t *tracks.Track, base, side string, beat int) Marker {
	var near []string
	for _, c := range t.Cues {
		if c.Kind == 0 && abs(beatOf(t, c.T)-beat) <= 1 {
			near = append(near, MemName(c))
		}
	}
	name := base + " " + side
	switch {
	case slices.Contains(near, name):
		return Marker{name, beat, "existing"}
	case slices.Contains(near, base):
		return Marker{name, beat, "rename"}
	}
	return Marker{name, beat, "new"}
}

// slotCue is a slot's current cue: the first cue of that kind, with its beat.
type slotCue struct {
	name string
	beat int
}

func slotOf(t *tracks.Track, kind int) *slotCue {
	for _, c := range t.Cues {
		if c.Kind == kind {
			return &slotCue{c.Name, beatOf(t, c.T)}
		}
	}
	return nil
}

func decideSlot(name string, beat int, cur *slotCue, matches bool) *Slot {
	if cur == nil {
		return &Slot{name, beat, "new", nil}
	}
	if matches && cur.beat == beat {
		return &Slot{cur.name, beat, "existing", nil}
	}
	return &Slot{name, beat, "replace", &Old{cur.name, cur.beat}}
}

// lastByKind maps hot cue kinds to the track's last cue of that kind.
func lastByKind(t *tracks.Track) map[int]db.Cue {
	m := map[int]db.Cue{}
	for _, c := range t.Cues {
		if c.Kind > 0 {
			m[c.Kind] = c
		}
	}
	return m
}

var reOnDrop = regexp.MustCompile(`on a drop \(beat (\d+)\)`)

// PlanSet plans the set cues. order: playlist tracks in play order; recs: id -> track;
// cache: the transition cache (may be nil).
func PlanSet(order []db.PlaylistTrack, recs map[string]*tracks.Track, cache *pairs.Cache) []Action {
	if cache == nil {
		cache = pairs.New()
	}
	out := make([]Action, len(order))
	for i, x := range order {
		out[i] = Action{ID: x.ID, Title: x.Title, Warnings: []string{}, Markers: []Marker{}, Remove: []Marker{}}
	}
	warn := func(i int, w string) { out[i].Warnings = append(out[i].Warnings, w) }
	for i, x := range order {
		t := recs[x.ID]
		if t == nil {
			warn(i, "no Rekordbox analysis for this track; skipped")
			continue
		}
		trackWarnings(t, func(w string) { warn(i, w) })
		hot := lastByKind(t)
		if i == 0 { // first track: E = START
			cur := slotOf(t, 6)
			out[i].E = decideSlot("START", rules.FirstDownbeat(t), cur, cur != nil && strings.ToUpper(cur.name) == "START")
		}
		if i == len(order)-1 { // last track: no G
			if cur := slotOf(t, 8); cur != nil {
				out[i].G = &Slot{cur.name, cur.beat, "clear", &Old{cur.name, cur.beat}}
			}
			continue
		}
		nxt := order[i+1]
		u := recs[nxt.ID]
		if u == nil {
			continue
		}
		planTransition(out, i, x, nxt, t, u, hot, cache)
	}
	for i, x := range order {
		t := recs[x.ID]
		if t != nil && (i == len(order)-1 || recs[order[i+1].ID] != nil) {
			out[i].Remove = staleCues(t, out[i].Markers)
			if len(out[i].Remove) > 0 {
				var parts []string
				for _, r := range out[i].Remove {
					parts = append(parts, fmt.Sprintf("%s @ beat %d (%s)", r.Name, r.Beat, r.Status))
				}
				warn(i, "memory cue(s) removed on write: "+strings.Join(parts, ", "))
			}
		}
	}
	return out
}

// trackWarnings flags a shifted bar 1, cues `set` renames and memory cues with no colour rule.
func trackWarnings(t *tracks.Track, warn func(string)) {
	n, onBar := 0, 0
	for _, p := range t.Phrases {
		if p.Beat <= len(t.BNum) {
			n++
			if pyIndex(t.BNum, p.Beat-1) == 1 {
				onBar++
			}
		}
	}
	if n > 0 && float64(onBar)/float64(n) < 0.5 {
		warn("Rekordbox's phrases don't start on this track's bar downbeats: the " +
			"beat grid's bar 1 is probably shifted; check the downbeat in Rekordbox")
	}
	var renamed, odd []string
	for _, c := range t.Cues {
		if to := config.RenameTo(c.Name, c.Kind > 0); to != "" {
			kind := "memory"
			if c.Kind != 0 {
				kind = "hot cue"
			}
			renamed = append(renamed, fmt.Sprintf("'%s' (%s) @ beat %d -> %s", c.Name, kind, beatOf(t, c.T), to))
		}
		if _, ok := config.MemoryColor[MemName(c)]; c.Kind == 0 && !ok {
			name := c.Name
			if name == "" {
				name = "(unnamed)"
			}
			odd = append(odd, fmt.Sprintf("'%s' @ beat %d", name, beatOf(t, c.T)))
		}
	}
	if len(renamed) > 0 {
		warn("cue(s) renamed on write: " + strings.Join(renamed, ", "))
	}
	if len(odd) > 0 {
		warn("memory cue(s) with no colour rule (expected " + strings.Join(config.MemoryColorOrder, ", ") + "): " +
			strings.Join(odd, ", "))
	}
}

// transition plans one A -> B transition: x/t outgoing (track i), nxt/u incoming.
type transition struct {
	out        []Action
	i          int
	x, nxt     db.PlaylistTrack
	t, u       *tracks.Track
	hot, uhot  map[int]db.Cue
	gCur, eCur *slotCue
	gMatch     bool
	eMatch     bool
	cached     *pairs.Entry
	drops, bss []int // u's DROP and BASS SWAP (IN) memory cues
	note       []string
	g, e       int
	al         Alignment
}

func (tr *transition) warn(k int, w string) { tr.out[k].Warnings = append(tr.out[k].Warnings, w) }

// planTransition decides G on track i, E on track i+1 and the markers between them.
func planTransition(out []Action, i int, x, nxt db.PlaylistTrack, t, u *tracks.Track, hot map[int]db.Cue,
	cache *pairs.Cache) {
	tr := &transition{out: out, i: i, x: x, nxt: nxt, t: t, u: u, hot: hot, uhot: lastByKind(u),
		gCur: slotOf(t, 8), eCur: slotOf(u, 6), cached: cache.Get(x.ID, nxt.ID)}
	tr.gMatch = tr.gCur != nil && NamesMatch(tr.gCur.name, nxt.Title)
	tr.eMatch = tr.eCur != nil && NamesMatch(tr.eCur.name, x.Title)
	if tr.cached == nil {
		tr.cached = &pairs.Entry{}
	}
	for _, c := range u.Cues {
		if c.Kind == 0 && strings.ToUpper(c.Name) == "DROP" {
			tr.drops = append(tr.drops, beatOf(u, c.T))
		}
		if c.Kind == 0 && markerBase(MemName(c), "IN") == "BASS SWAP" {
			tr.bss = append(tr.bss, beatOf(u, c.T))
		}
	}
	tr.chooseG()
	tr.chooseE()
	tr.slots()
	tr.markers()
}

// chooseG: the pair's own G (in place, else cached), else the outgoing OUT.
func (tr *transition) chooseG() {
	t := tr.t
	gSrc := "" // the hand-placed cue G follows, if any
	switch {
	case tr.gMatch:
		tr.g, gSrc = tr.gCur.beat, fmt.Sprintf("G '%s'", tr.gCur.name)
	case tr.cached.GMS != nil:
		tr.g = beatOf(t, float64(*tr.cached.GMS)/1000)
		tr.note = append(tr.note, "G restored from the transition cache")
	default:
		if d, ok := tr.hot[5]; ok {
			tr.g, gSrc = beatOf(t, d.T), fmt.Sprintf("OUT hot cue '%s'", d.Name)
		} else {
			tr.g = rules.HotCues(t, config.DefaultRules)["OUT"]
		}
	}
	if off := OffPhrase(t, tr.g); gSrc != "" && off != "" {
		tr.warn(tr.i, fmt.Sprintf("%s at beat %d is off-phrase (%s); kept, check it", gSrc, tr.g, off))
	}
}

// inOf is u's IN hot cue beat, else fallback().
func (tr *transition) inOf(fallback func() int) int {
	if a, ok := tr.uhot[1]; ok {
		return beatOf(tr.u, a.T)
	}
	return fallback()
}

// chooseE: the pair's own E (in place, else cached), else computed; a computed E off G's
// phrase position is moved, a hand-placed one only flagged.
func (tr *transition) chooseE() {
	t, u, g := tr.t, tr.u, tr.g
	switch {
	case tr.eMatch:
		tr.e = tr.eCur.beat
	case tr.cached.EMS != nil:
		tr.e = beatOf(u, float64(*tr.cached.EMS)/1000)
		tr.note = append(tr.note, "E restored from the transition cache")
	default:
		tr.e = chooseE(t, g, u, tr.inOf(func() int { return rules.HotCues(u, config.DefaultRules)["IN"] }), tr.drops, tr.bss)
	}
	tr.al = Align(t, g, u, tr.e)
	if off := OffPhrase(u, tr.e); tr.eMatch && off != "" {
		tr.warn(tr.i+1, fmt.Sprintf("E '%s' at beat %d is off-phrase (%s); kept, check it", tr.eCur.name, tr.e, off))
	}
	if tr.al.PhraseAligned || tr.al.EndsOnPhrase {
		return
	}
	if tr.eMatch { // hand-placed: kept, never moved
		tr.note = append(tr.note, fmt.Sprintf("E at beat %d is %d beats off G's phrase position; kept, check it",
			tr.e, min(tr.al.Offset, Phrase-tr.al.Offset)))
		return
	}
	oldE, off := tr.e, tr.al.Offset
	tr.e = chooseE(t, g, u, tr.inOf(func() int { return oldE }), tr.drops, tr.bss)
	tr.al = Align(t, g, u, tr.e)
	tr.note = append(tr.note, fmt.Sprintf("E at beat %d was %d beats off the phrase; fixed to beat %d",
		oldE, min(off, Phrase-off), tr.e))
	if !tr.al.PhraseAligned && !tr.al.EndsOnPhrase {
		tr.note = append(tr.note, "still not phrase-aligned; check the beat grids")
	}
}

// slots decides the G and E slots and reports the notes.
func (tr *transition) slots() {
	i, x, nxt := tr.i, tr.x, tr.nxt
	gName := CueName(nxt.Title)
	if tr.gMatch {
		gName = tr.gCur.name
	}
	tr.out[i].G = decideSlot(gName, tr.g, tr.gCur, tr.gMatch)
	eName := CueName(x.Title)
	if tr.eMatch && tr.eCur.beat == tr.e {
		eName = tr.eCur.name
	}
	tr.out[i+1].E = decideSlot(eName, tr.e, tr.eCur, tr.eMatch)
	for _, s := range []struct {
		slot, title string
		act         *Slot
		who         int
	}{{"G", nxt.Title, tr.out[i].G, i}, {"E", x.Title, tr.out[i+1].E, i + 1}} {
		if s.act.Status == "replace" && s.act.Old != nil && !NamesMatch(s.act.Old.Name, s.title) {
			tr.warn(s.who, fmt.Sprintf("%s '%s' (another set) replaced; saved in the transition cache", s.slot, s.act.Old.Name))
		}
	}
	for _, n := range tr.note {
		tr.warn(i+1, fmt.Sprintf("%s -> %s: %s", x.Title, nxt.Title, n))
	}
}

// markers places the bass swap and the BASS SWAP / exit / SYNC markers on both tracks.
func (tr *transition) markers() {
	i, x, nxt, t, u, g, e := tr.i, tr.x, tr.nxt, tr.t, tr.u, tr.g, tr.e
	A, B := &tr.out[i], &tr.out[i+1]
	bs, why := bassSwap(t, g, u, e, tr.drops, tr.bss)
	B.BassSwap = &BassSwap{bs, why}
	B.swapSet = true
	switch m := reOnDrop.FindStringSubmatch(why); {
	case bs != 0:
		B.Swap = &bs
	case m != nil:
		d, _ := strconv.Atoi(m[1])
		B.Swap = &d
	}
	if bs != 0 {
		B.Markers = append(B.Markers, marker(u, "BASS SWAP", "IN", bs))
	}
	if why == "existing" && !BothOnPhrase(u, bs, t, bs-e+g) {
		var offs []string
		if o := OffPhrase(t, bs-e+g); o != "" {
			offs = append(offs, fmt.Sprintf("%s (%s)", x.Title, o))
		}
		if o := OffPhrase(u, bs); o != "" {
			offs = append(offs, fmt.Sprintf("%s (%s)", nxt.Title, o))
		}
		if len(offs) == 0 {
			offs = []string{"the two tracks' phrases don't line up there"}
		}
		tr.warn(i+1, fmt.Sprintf("BASS SWAP at beat %d is off-phrase in %s; kept, check it", bs, strings.Join(offs, ", ")))
	}
	if B.Swap != nil { // the outgoing track's bass leaves at the same moment
		A.Markers = append(A.Markers, marker(t, "BASS SWAP", "OUT", g+*B.Swap-e))
	}
	if ex := exitMarker(t, g, u, e); ex != nil {
		A.Exit = ex
		A.Markers = append(A.Markers, marker(t, ex.Name, "OUT", ex.A))
		B.Markers = append(B.Markers, marker(u, ex.Name, "IN", ex.B))
	}
	if sync(t, g, u, e) {
		B.Sync = true
		A.Markers = append(A.Markers, marker(t, "SYNC", "OUT", g))
		B.Markers = append(B.Markers, marker(u, "SYNC", "IN", e))
	}
	if bs != 0 && why == "new" && bs-e+g > BassEndBeat(t) {
		tr.warn(i+1, fmt.Sprintf("BASS SWAP at beat %d comes after %s's bass has ended", bs, x.Title))
	}
	if !tr.al.PhraseAligned && tr.al.EndsOnPhrase {
		tr.warn(i+1, fmt.Sprintf("%s -> %s: not phrase-aligned during the overlap; works only if "+
			"%s plays to the end (a new phrase starts on its last beat)", x.Title, nxt.Title, x.Title))
	}
}

// staleCues are the memory cues `set --write` deletes from t (name, beat, why): a CUT OUT more
// than a beat from this set's CUT OUT marker (where t is cut into the next track, which gets
// the CUT IN), and a JUMP on the same beat as a JUMP hot cue (a duplicate).
func staleCues(t *tracks.Track, markers []Marker) []Marker {
	var cutOut []int
	for _, m := range markers {
		if m.Name == "CUT OUT" {
			cutOut = append(cutOut, m.Beat)
		}
	}
	pads := map[int]bool{}
	for _, c := range t.Cues {
		name := config.RenameTo(c.Name, true)
		if name == "" {
			name = config.Norm(c.Name)
		}
		if c.Kind > 0 && name == "JUMP" {
			pads[beatOf(t, c.T)] = true
		}
	}
	out := []Marker{}
	for _, c := range t.Cues {
		if c.Kind != 0 {
			continue
		}
		n, b := MemName(c), beatOf(t, c.T)
		switch {
		case n == "CUT OUT" && !slices.ContainsFunc(cutOut, func(k int) bool { return abs(b-k) <= 1 }):
			out = append(out, Marker{n, b, "no CUT IN on the next track there"})
		case n == "JUMP" && pads[b]:
			out = append(out, Marker{n, b, "same beat as the JUMP hot cue"})
		}
	}
	return out
}

// KeyCheck is the key move between order[I] and order[J].
type KeyCheck struct {
	I, J int
	OK   bool
	Desc string
	Cost int
}

// CheckOrder returns the key move between each pair of neighbours.
func CheckOrder(order []db.PlaylistTrack) []KeyCheck {
	var out []KeyCheck
	for i := 0; i+1 < len(order); i++ {
		ok, desc, cost := KeyMove(order[i].Key, order[i+1].Key)
		out = append(out, KeyCheck{i, i + 1, ok, desc, cost})
	}
	return out
}
