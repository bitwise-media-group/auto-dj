// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package setlist

import (
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/testtrack"
	"github.com/bitwise-media-group/auto-dj/internal/tracks"
)

var cue = testtrack.Cue

func TestCamelotAndKeyMoves(t *testing.T) {
	keys := map[string]Camelot{"Am": {8, "A"}, "C": {8, "B"}, "F#m": {11, "A"}, "Abm": {1, "A"}, "9A": {9, "A"}}
	for k, want := range keys {
		if got, ok := ToCamelot(k); !ok || got != want {
			t.Errorf("ToCamelot(%s) = %v", k, got)
		}
	}
	if ok, _, _ := KeyMove("F#m", "C#m"); !ok { // Camelot +1 (a fifth)
		t.Error("F#m -> C#m")
	}
	if ok, _, _ := KeyMove("Am", "C"); !ok { // relative major
		t.Error("Am -> C")
	}
	if _, _, c := KeyMove("F#m", "Em"); c != 1 { // -2 semitones energy boost
		t.Error("F#m -> Em")
	}
	if _, _, c := KeyMove("Am", "Bbm"); c != 2 { // +1 semitone energy boost
		t.Error("Am -> Bbm")
	}
	if ok, _, _ := KeyMove("F#m", "Am"); ok { // Camelot -3 clashes
		t.Error("F#m -> Am")
	}
}

func TestSuggestOrderFixesClashMinimally(t *testing.T) {
	keys := []string{"F#m", "Am", "F#m", "C#m", "G#m"}
	items := make([]OrderItem, len(keys))
	for i, k := range keys {
		items[i] = OrderItem{k, 124}
	}
	order, cost := SuggestOrder(items, true)
	if order[0] != 0 || cost >= 100 {
		t.Fatalf("order %v cost %d", order, cost)
	}
	for i := 0; i+1 < len(order); i++ {
		if ok, _, _ := KeyMove(keys[order[i]], keys[order[i+1]]); !ok {
			t.Errorf("clash left in %v", order)
		}
	}
	big := make([]OrderItem, 16) // local search above 14 tracks
	for i := range big {
		big[i] = OrderItem{keys[i%len(keys)], 124}
	}
	if order, _ := SuggestOrder(big, true); order[0] != 0 || len(order) != 16 {
		t.Errorf("local search: %v", order)
	}
}

func TestAlignmentPhraseAndPlayOut(t *testing.T) {
	a, b := testtrack.Synth(testtrack.Options{}), testtrack.Synth(testtrack.Options{})
	if !Align(a, 513, b, 65).PhraseAligned { // both on phrase starts
		t.Error("513 -> 65 should be aligned")
	}
	if Align(a, 513, b, 61).PhraseAligned { // E 4 beats early
		t.Error("513 -> 61 should not be aligned")
	}
}

func TestNamesMatchTypos(t *testing.T) {
	if !NamesMatch("DIALOG", "Dialogue (Original Mix)") || !NamesMatch("RAJ", "Rej (Original Mix)") ||
		!NamesMatch("LOST HAWK", "The Lost Hawk (Original Mix)") {
		t.Error("NamesMatch")
	}
	if CueName("Don't Wake Up (Original Mix)") != "DONT WAKE UP" {
		t.Error("CueName")
	}
}

// pair is two synthetic tracks: a (id 1) -> b (id 2).
func pair(ao testtrack.Options) (a, b *tracks.Track, order []db.PlaylistTrack, recs map[string]*tracks.Track) {
	a, b = testtrack.Synth(ao), testtrack.Synth(testtrack.Options{})
	b.ID, b.Title = "2", "Other (Original Mix)"
	for _, t := range []*tracks.Track{a, b} {
		order = append(order, db.PlaylistTrack{ID: t.ID, Title: t.Title, Key: "8A", BPM: 128})
	}
	return a, b, order, map[string]*tracks.Track{"1": a, "2": b}
}

func hasMarker(ms []Marker, m Marker) bool { return slices.Contains(ms, m) }

func TestSetWarnsOnMemoryCuesWithoutColourRule(t *testing.T) {
	a, _, order, recs := pair(testtrack.Options{})
	a.Cues = []db.Cue{cue(a, 1, "START", 0), cue(a, 97, "EARLY", 0), cue(a, 161, "Low Pass", 0),
		cue(a, 321, "filter", 0), cue(a, 577, "OUT", 0)}
	acts := PlanSet(order, recs, nil)
	var warn []string
	for _, w := range acts[0].Warnings {
		if strings.Contains(w, "no colour rule") {
			warn = append(warn, w)
		}
	}
	if len(warn) != 1 || !strings.Contains(warn[0], "'EARLY' @ beat 97") || strings.Contains(warn[0], "Low Pass") ||
		strings.Contains(warn[0], "START'") {
		t.Errorf("colour warning: %v", warn)
	}
	if !slices.ContainsFunc(acts[0].Warnings, func(w string) bool {
		return strings.Contains(w, "'Low Pass' (memory) @ beat 161 -> FILTER") &&
			strings.Contains(w, "'OUT' (memory) @ beat 577 -> CUT OUT")
	}) {
		t.Errorf("rename warning missing: %v", acts[0].Warnings)
	}
	if slices.ContainsFunc(acts[1].Warnings, func(w string) bool { return strings.Contains(w, "no colour rule") }) {
		t.Error("warned on the second track")
	}
	// markers from before FILTER OUT became FILTER
	if MemName(db.Cue{Name: "Filter Out Out"}) != "FILTER OUT" || MemName(db.Cue{Name: "FILTER OUT IN"}) != "FILTER IN" {
		t.Error("MemName")
	}
}

func TestSetPutsSwapAndExitMarkersOnBothTracks(t *testing.T) {
	a, b, order, recs := pair(testtrack.Options{})
	a.Cues = []db.Cue{cue(a, 577, "OUT", 5), cue(a, 601, "Low Pass", 0)} // FILTER once renamed
	b.Cues = []db.Cue{cue(b, 65, "IN", 1)}
	acts := PlanSet(order, recs, nil)
	g, e := acts[0].G.Beat, acts[1].E.Beat
	if *acts[0].Exit != (Exit{"FILTER", 601, e + 601 - g, "out"}) {
		t.Errorf("exit = %+v", acts[0].Exit)
	}
	if !hasMarker(acts[0].Markers, Marker{"FILTER OUT", 601, "rename"}) { // the plain cue gets its side
		t.Errorf("markers[0] = %v", acts[0].Markers)
	}
	if !hasMarker(acts[1].Markers, Marker{"FILTER IN", e + 601 - g, "new"}) { // same moment in the incoming track
		t.Errorf("markers[1] = %v", acts[1].Markers)
	}
	if acts[1].Swap == nil {
		t.Fatal("no swap")
	}
	sw := *acts[1].Swap
	if !hasMarker(acts[0].Markers, Marker{"BASS SWAP OUT", g + sw - e, "new"}) ||
		!hasMarker(acts[1].Markers, Marker{"BASS SWAP IN", sw, "new"}) {
		t.Errorf("bass swap markers: %v / %v", acts[0].Markers, acts[1].Markers)
	}
}

func TestSetKeepsExistingBassSwapOffTheOutgoingPhrasing(t *testing.T) {
	// a plays to the end: b's beat 113 starts a phrase on a's last beat
	a, b, order, recs := pair(testtrack.Options{NB: 632})
	a.Cues = []db.Cue{cue(a, 585, "OTHER", 8)}                                // G half a phrase off a's grid
	b.Cues = []db.Cue{cue(b, 65, "SYNTHETIC", 6), cue(b, 97, "BASS SWAP", 0)} // 97 <-> a's beat 617: mid-phrase
	acts := PlanSet(order, recs, nil)
	if acts[0].G.Beat != 585 || acts[1].E.Beat != 65 {
		t.Fatalf("G/E = %d/%d", acts[0].G.Beat, acts[1].E.Beat)
	}
	if *acts[1].BassSwap != (BassSwap{97, "existing"}) || *acts[1].Swap != 97 {
		t.Errorf("bass swap = %+v", acts[1].BassSwap)
	}
	if !hasMarker(acts[1].Markers, Marker{"BASS SWAP IN", 97, "rename"}) ||
		!hasMarker(acts[0].Markers, Marker{"BASS SWAP OUT", 617, "new"}) {
		t.Errorf("markers: %v / %v", acts[0].Markers, acts[1].Markers)
	}
	if !slices.Contains(acts[0].Warnings, "G 'OTHER' at beat 585 is off-phrase (8 beats into a phrase); kept, check it") {
		t.Errorf("warnings[0] = %v", acts[0].Warnings)
	}
	if !slices.ContainsFunc(acts[1].Warnings, func(w string) bool {
		return strings.Contains(w, "BASS SWAP at beat 97 is off-phrase in Synthetic (Extended Mix) (8 beats")
	}) {
		t.Errorf("warnings[1] = %v", acts[1].Warnings)
	}
	if slices.ContainsFunc(acts[1].Warnings, func(w string) bool { return strings.Contains(w, "E 'SYNTHETIC'") }) {
		t.Error("E itself is on the phrase")
	}
}

func TestSetKeepsHandPlacedEOffThePhrase(t *testing.T) {
	a, b, order, recs := pair(testtrack.Options{})
	a.Cues = []db.Cue{cue(a, 577, "OTHER", 8)}
	b.Cues = []db.Cue{cue(b, 73, "SYNTHETIC", 6)} // half a phrase off G, and a doesn't play out on a phrase
	acts := PlanSet(order, recs, nil)
	if *acts[1].E != (Slot{"SYNTHETIC", 73, "existing", nil}) {
		t.Errorf("E = %+v", acts[1].E)
	}
	const off = "E 'SYNTHETIC' at beat 73 is off-phrase (8 beats into a phrase); kept, check it"
	if !slices.Contains(acts[1].Warnings, off) ||
		!slices.ContainsFunc(acts[1].Warnings, func(w string) bool {
			return strings.Contains(w, "E at beat 73 is 8 beats off G's phrase position; kept")
		}) {
		t.Errorf("warnings[1] = %v", acts[1].Warnings)
	}
	if slices.ContainsFunc(acts[0].Warnings, func(w string) bool { return strings.Contains(w, "off-phrase") }) {
		t.Errorf("warnings[0] = %v", acts[0].Warnings)
	}
}

func sortedMarkers(ms []Marker) []Marker {
	out := slices.Clone(ms)
	sort.Slice(out, func(i, j int) bool {
		if out[i].Name != out[j].Name {
			return out[i].Name < out[j].Name
		}
		if out[i].Beat != out[j].Beat {
			return out[i].Beat < out[j].Beat
		}
		return out[i].Status < out[j].Status
	})
	return out
}

func TestSetRemovesStaleCutOutsAndDuplicateJumps(t *testing.T) {
	a, b, order, recs := pair(testtrack.Options{})
	a.Cues = []db.Cue{cue(a, 577, "OUT", 5)}
	b.Cues = []db.Cue{cue(b, 65, "IN", 1)}
	g := PlanSet(order, recs, nil)[0].G.Beat
	a.Cues = append(a.Cues,
		cue(a, g-64, "CUT OUT", 0),     // before G: never this set's exit
		cue(a, g+16, "Cut-Out RES", 0), // the exit, once renamed
		cue(a, g+48, "CUT OUT", 0),     // after the exit
		cue(a, 129, "JUMP TO DROP", 7),
		cue(a, 129, "JUMP", 0), // on the JUMP pad: duplicate
		cue(a, 33, "JUMP", 0),  // the jump itself
	)
	b.Cues = append(b.Cues, cue(b, 600, "CUT OUT", 0)) // last track: nothing to cut into
	acts := PlanSet(order, recs, nil)
	if ex := acts[0].Exit; ex.Name != "CUT" || ex.A != g+16 {
		t.Errorf("exit = %+v", ex)
	}
	if !hasMarker(acts[0].Markers, Marker{"CUT OUT", g + 16, "existing"}) {
		t.Errorf("markers = %v", acts[0].Markers)
	}
	want := []Marker{
		{"CUT OUT", g - 64, "no CUT IN on the next track there"},
		{"CUT OUT", g + 48, "no CUT IN on the next track there"},
		{"JUMP", 129, "same beat as the JUMP hot cue"},
	}
	if got := sortedMarkers(acts[0].Remove); !slices.Equal(got, want) {
		t.Errorf("remove = %v", got)
	}
	if !slices.Equal(acts[1].Remove, []Marker{{"CUT OUT", 600, "no CUT IN on the next track there"}}) {
		t.Errorf("remove[1] = %v", acts[1].Remove)
	}
	has := func(sub string) bool {
		return slices.ContainsFunc(acts[0].Warnings, func(w string) bool { return strings.Contains(w, sub) })
	}
	if !has("'JUMP TO DROP' (hot cue) @ beat 129 -> JUMP") || !has("'Cut-Out RES' (memory) @ beat ") {
		t.Errorf("warnings = %v", acts[0].Warnings)
	}
	b.Cues = append(b.Cues, cue(b, acts[1].E.Beat+32, "CUT-IN A", 0)) // the next track's CUT IN wins
	acts = PlanSet(order, recs, nil)
	if *acts[0].Exit != (Exit{"CUT", g + 32, acts[1].E.Beat + 32, "in"}) {
		t.Errorf("exit = %+v", acts[0].Exit)
	}
	if !hasMarker(acts[0].Markers, Marker{"CUT OUT", g + 32, "new"}) ||
		!hasMarker(acts[0].Remove, Marker{"CUT OUT", g + 16, "no CUT IN on the next track there"}) {
		t.Errorf("markers %v remove %v", acts[0].Markers, acts[0].Remove)
	}
}

func TestSetExitCueOnIncomingTrackIsMarkedOnOutgoing(t *testing.T) {
	a, b, order, recs := pair(testtrack.Options{})
	a.Cues = []db.Cue{cue(a, 577, "OUT", 5)}
	b.Cues = []db.Cue{cue(b, 65, "IN", 1)}
	acts := PlanSet(order, recs, nil)
	g, e := acts[0].G.Beat, acts[1].E.Beat
	// B's own CUT OUT is its exit marker: not about this transition
	b.Cues = append(b.Cues, cue(b, e+32, "CUT IN", 0), cue(b, e+24, "CUT OUT", 0))
	acts = PlanSet(order, recs, nil)
	if *acts[0].Exit != (Exit{"CUT", g + 32, e + 32, "in"}) {
		t.Errorf("exit = %+v", acts[0].Exit)
	}
	if !hasMarker(acts[0].Markers, Marker{"CUT OUT", g + 32, "new"}) ||
		!hasMarker(acts[1].Markers, Marker{"CUT IN", e + 32, "existing"}) {
		t.Errorf("markers %v / %v", acts[0].Markers, acts[1].Markers)
	}
}

func TestSetSyncMarkersOnBothTracks(t *testing.T) {
	a, b, order, recs := pair(testtrack.Options{})
	a.Cues = []db.Cue{cue(a, 577, "OUT", 5)}
	b.Cues = []db.Cue{cue(b, 65, "IN", 1)}
	acts := PlanSet(order, recs, nil)
	g, e := acts[0].G.Beat, acts[1].E.Beat
	if acts[1].Sync {
		t.Fatal("sync without a SYNC cue")
	}
	b.Cues = append(b.Cues, cue(b, e, "sync", 0)) // on B's E: an instant mashup
	acts = PlanSet(order, recs, nil)
	if !acts[1].Sync || !hasMarker(acts[0].Markers, Marker{"SYNC OUT", g, "new"}) ||
		!hasMarker(acts[1].Markers, Marker{"SYNC IN", e, "rename"}) {
		t.Errorf("sync %v markers %v / %v", acts[1].Sync, acts[0].Markers, acts[1].Markers)
	}
	b.Cues[len(b.Cues)-1] = cue(b, e+16, "SYNC IN", 0) // not on E: no sync
	if PlanSet(order, recs, nil)[1].Sync {
		t.Error("SYNC IN off E made a sync")
	}
}
