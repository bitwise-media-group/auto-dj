// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package mixalign

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"math"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/bitwise-media-group/auto-dj/internal/anlz"
	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/demo"
	"github.com/bitwise-media-group/auto-dj/internal/demo/synth"
	"github.com/bitwise-media-group/auto-dj/internal/features"
	"github.com/bitwise-media-group/auto-dj/internal/preview"
	"github.com/bitwise-media-group/auto-dj/internal/setlist"
	"github.com/bitwise-media-group/auto-dj/internal/tracks"
)

// The test set: demo songs as 88-bar extended mixes (bass in bars 16-48 and 56-80), mixed at
// a fixed 126 BPM (the songs are 123-125: every track plays at r != 1). Each transition
// starts the next track at its beat 1 on the outgoing track's beat 257 and swaps the bass on
// the incoming beat 65, where its bassline comes in (and the outgoing one's stops). Track 2
// jumps back 64 beats (31 s) from beat 209 to beat 145, in its solo middle, and the history
// lists a track between 2 and 3 that was never played.
const (
	mixBPM   = 126.0
	gBeat    = 257
	swapBeat = 65
)

var layout = synth.Layout{Intro: 8, Groove: 16, Main: 24, Break: 8, Drop: 24, Outro: 8}

func ffmpegOK(t *testing.T) {
	t.Helper()
	for _, tool := range []string{"ffmpeg", "ffprobe"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skip("needs ffmpeg and ffprobe")
		}
	}
}

// testSet is the rendered songs (history order) and the mix made from them.
type testSet struct {
	dir    string
	tracks []*tracks.Track // history order: 1, 2 (loop), never played, 3
	segs   []*preview.Seg  // the played tracks
	mix    string
	err    error
}

var (
	setOnce sync.Once
	set     testSet
)

func TestMain(m *testing.M) {
	code := m.Run()
	if set.dir != "" {
		_ = os.RemoveAll(set.dir)
	}
	os.Exit(code)
}

func getSet(t *testing.T) *testSet {
	t.Helper()
	ffmpegOK(t)
	if testing.Short() || raceDetector {
		t.Skip("renders a 10-minute mix: too slow for -short or the race detector (plain go test runs it)")
	}
	setOnce.Do(func() { set.err = buildSet() })
	if set.err != nil {
		t.Fatal(set.err)
	}
	return &set
}

func buildSet() error {
	dir, err := os.MkdirTemp("", "mixalign-test-")
	if err != nil {
		return err
	}
	set.dir = dir
	for i, k := range []int{0, 1, 4, 3} { // demo tracks: Low Sun, Glasshouse, Copper Wire (never played), Night Bus
		dt := demo.Tracks[k]
		s := dt.Song
		s.Layout = layout
		path := filepath.Join(dir, fmt.Sprintf("%d.wav", i+1))
		if err := writeWAV(path, synth.Render(s)); err != nil {
			return err
		}
		set.tracks = append(set.tracks, analysed(fmt.Sprint(i+1), dt.Title, path, s.BPM))
	}
	loop := set.tracks[1]
	loop.Cues = []db.Cue{{Kind: 1, T: loop.Beats[144], Name: "JUMP"}, {Kind: 0, T: loop.Beats[208], Name: "JUMP"}}
	played := []*tracks.Track{set.tracks[0], set.tracks[1], set.tracks[3]}
	recs := map[string]*tracks.Track{}
	order := make([]db.PlaylistTrack, len(played))
	acts := make([]setlist.Action, len(played))
	for i, t := range played {
		recs[t.ID] = t
		order[i] = db.PlaylistTrack{No: i + 1, ID: t.ID, Title: t.Title, BPM: t.BPM}
		acts[i] = setlist.Action{ID: t.ID, Title: t.Title, E: &setlist.Slot{Name: "E", Beat: 1, Status: "new"}}
		if i+1 < len(played) {
			acts[i].G = &setlist.Slot{Name: "G", Beat: gBeat, Status: "new"}
		}
		if i > 0 {
			sw := swapBeat
			acts[i].Swap = &sw
		}
	}
	set.segs = preview.MixTimeline(order, acts, recs, 0, mixBPM)
	set.mix, err = preview.RenderSet(set.segs, filepath.Join(dir, "mix.wav"))
	return err
}

// analysed is a rendered song with the grid and phrases Rekordbox would give it.
func analysed(id, title, path string, bpm float64) *tracks.Track {
	nb := layout.Bars() * 4
	t := &tracks.Track{ID: id, Title: title, Path: path, BPM: bpm, Local: true, Beats: make([]float64, nb),
		BNum: make([]int, nb), Cues: []db.Cue{}, Length: float64(nb)*60/bpm + 2}
	for i := range nb {
		t.Beats[i], t.BNum[i] = float64(i)*60/bpm, i%4+1
	}
	bar := 0
	for _, sec := range []struct {
		label string
		bars  int
	}{{"Intro", layout.Intro}, {"Up", layout.Groove}, {"Chorus", layout.Main}, {"Down", layout.Break},
		{"Chorus", layout.Drop}, {"Outro", layout.Outro}} {
		for b := 0; b < sec.bars; b += 16 {
			t.Phrases = append(t.Phrases, anlz.Phrase{Beat: (bar+b)*4 + 1, Label: sec.label})
		}
		bar += sec.bars
	}
	return t
}

func writeWAV(path string, pcm []float32) error {
	cmd := exec.Command("ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", fmt.Sprint(synth.SR), "-ac", "2",
		"-i", "-", "-c:a", "pcm_s16le", path)
	in, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	w := bufio.NewWriterSize(in, 1<<20)
	var b [4]byte
	for _, v := range pcm {
		binary.LittleEndian.PutUint32(b[:], math.Float32bits(v))
		if _, err := w.Write(b[:]); err != nil {
			break
		}
	}
	_ = w.Flush()
	_ = in.Close()
	if err := cmd.Wait(); err != nil {
		return fmt.Errorf("ffmpeg: %w: %s", err, stderr.String())
	}
	return nil
}

func inputs(t *testing.T, ts []*tracks.Track) []Input {
	t.Helper()
	out := make([]Input, len(ts))
	for i, x := range ts {
		y, err := features.Decode(x.Path)
		if err != nil {
			t.Fatal(err)
		}
		F, err := features.FrameFeatures(y)
		if err != nil {
			t.Fatal(err)
		}
		out[i] = Input{No: i + 1, ID: x.ID, Title: x.Title, Rec: x, F: F}
	}
	return out
}

func parse(t *testing.T, s string) float64 {
	t.Helper()
	v, err := ParseTime(s)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestAlignRenderedSet(t *testing.T) {
	s := getSet(t)
	rec, err := features.DecodeFrames(s.mix)
	if err != nil {
		t.Fatal(err)
	}
	const sr = preview.SR
	samples := int64(float64(len(rec)) * features.Hop * sr / features.SR)
	es := Align(rec, inputs(t, s.tracks), sr, samples)
	for _, e := range es {
		t.Logf("%d %-14s %-14s conf %.3f ratio %.2f fit %+v in %+v out %+v start %s takeover %s cut %s end %s %+v %v",
			e.No, e.Title, e.Status, e.Confidence, e.PeakRatio, e.Fit, e.In, e.Out, e.Start, e.Takeover, e.Cut, e.End,
			e.Transition, e.Notes)
	}
	// every played track is found (the synthetic songs repeat their 4-bar loops, so a fit can
	// come out low-confidence against its bar-shifted neighbours); the other one is not
	for i, e := range es {
		if e.Located() == (i == 2) {
			t.Errorf("track %d: status %s", e.No, e.Status)
		}
	}
	if es[2].Status != NotFoundState {
		t.Errorf("the track that wasn't played: status %s", es[2].Status)
	}
	if es[2].Kept() {
		t.Error("the track that wasn't played must not get a file")
	}
	// Track 2's loop repeats bars of a section that repeats one 4-bar loop for 24 bars: the
	// stretch before the loop matches the after-loop mapping as well as its own, so which
	// mapping its start gets is not determined by this material (real tracks are less
	// repetitive). What is: every cut, the loop track's end, and the other tracks' fits.
	checkPlayed(t, s, []*Entry{es[0], es[1], es[3]})
}

// checkPlayed checks the played tracks' fits, cuts and transitions against the rendered mix.
func checkPlayed(t *testing.T, s *testSet, played []*Entry) {
	t.Helper()
	spb := 60 / mixBPM
	for k, seg := range s.segs {
		e := played[k]
		truthIn := seg.Clock.Out0 - seg.Clock.Src0/seg.Clock.Rate
		if k != 1 && (e.In == nil || math.Abs(e.In.Offset-truthIn) > 0.1 || math.Abs(e.In.R-seg.Clock.Rate) > 0.002) {
			t.Errorf("%s: in-fit %+v, want offset %.3f r %.4f", e.Title, e.In, truthIn, seg.Clock.Rate)
		}
		if k == 0 {
			if e.Cut != "0:00:00.000" {
				t.Errorf("the first file must start at 0, got %s", e.Cut)
			}
			continue
		}
		swap := *s.segs[k-1].SwapT
		if cut := parse(t, e.Cut); math.Abs(cut-swap) > spb {
			t.Errorf("%s: cut at %.3f s, the bass swap was at %.3f s", e.Title, cut, swap)
		}
		// E is where the track became audible (snapped back to a phrase start), in its intro
		// under the bass cut; G is the outgoing beat playing then
		tr := e.Transition
		if tr == nil || (tr.E-1)%setlist.Phrase != 0 {
			t.Errorf("%s: transition %+v, want E on a phrase start", e.Title, tr)
		} else if k == 2 && (tr.E > swapBeat || tr.G-tr.E != gBeat-1 || tr.BassSwap != swapBeat) {
			t.Errorf("%s: transition %+v, want E before %d, G-E = %d and BASS SWAP %d", e.Title, tr, swapBeat,
				gBeat-1, swapBeat)
		}
	}
	// the loop: track 2 ends 64 of its beats later than it started
	seg, e := s.segs[1], played[1]
	truthOut := seg.Clock.Out0 - seg.Clock.Src0/seg.Clock.Rate + 64*60/s.tracks[1].BPM/seg.Clock.Rate
	if e.Out == nil || math.Abs(e.Out.Offset-truthOut) > 0.1 {
		t.Errorf("loop track: out-fit %+v, want offset %.3f", e.Out, truthOut)
	}
}

func TestTimes(t *testing.T) {
	for _, s := range []float64{0, 1.2344, 59.9996, 3723.456} {
		v, err := ParseTime(FormatTime(s))
		if err != nil || math.Abs(v-s) > 0.0005 {
			t.Errorf("%v -> %s -> %v %v", s, FormatTime(s), v, err)
		}
	}
	if FormatTime(3723.456) != "1:02:03.456" {
		t.Error(FormatTime(3723.456))
	}
	for _, bad := range []string{"", "1:61:00", "a", "1:2:3:4", "-3"} {
		if _, err := ParseTime(bad); err == nil {
			t.Errorf("%q parsed", bad)
		}
	}
	if v, _ := ParseTime("2:03.5"); v != 123.5 {
		t.Error(v)
	}
}

// featureTrack is n frames of random features with a 4-beat pulse and a slow arrangement,
// so every probe is distinct (seeded: the same every run).
func featureTrack(seed int64, n int) []features.Frame {
	rng := rand.New(rand.NewSource(seed))
	F := make([]features.Frame, n)
	section := 1.0
	for i := range F {
		if i%400 == 0 {
			section = 0.5 + rng.Float64()
		}
		pulse := 0.2
		if i%20 == 0 {
			pulse = 1
		}
		for c := range F[i] {
			F[i][c] = float32(section * (pulse + 0.5*rng.Float64()))
		}
	}
	return F
}

// TestAlignFeatures runs the whole alignment (in parallel, so the race detector sees it) on
// feature-level tracks: B overlaps A's last 600 frames and takes over after 300 of them.
func TestAlignFeatures(t *testing.T) {
	A, B, C := featureTrack(1, 3000), featureTrack(2, 3000), featureTrack(3, 3000)
	const at = 2400 // B starts at A's frame 2400
	rec := make([]features.Frame, at+len(B))
	for i := range rec {
		for c := range rec[i] {
			var v float32
			if i < len(A) && i < at+300 {
				v += A[i][c]
			}
			if i >= at && (c != 0 || i >= at+300) { // B's bass only after the swap
				v += B[i-at][c]
			}
			rec[i][c] = v
		}
	}
	in := []Input{{No: 1, ID: "a", Title: "A", F: A}, {No: 2, ID: "c", Title: "C", F: C},
		{No: 3, ID: "b", Title: "B", F: B}}
	es := Align(rec, in, int(features.SR), int64(len(rec))*features.Hop)
	if !es[0].Located() || es[1].Status != NotFoundState || !es[2].Located() {
		t.Fatalf("statuses %s %s %s", es[0].Status, es[1].Status, es[2].Status)
	}
	if es[2].In == nil || math.Abs(es[2].In.Offset-at/fps) > 0.05 || math.Abs(es[2].In.R-1) > 0.002 {
		t.Errorf("B's fit %+v, want offset %.3f", es[2].In, at/fps)
	}
	if cut := parse(t, es[2].Cut); math.Abs(cut-(at+300)/fps) > 0.5 {
		t.Errorf("cut at %.3f s, the bass swapped at %.3f s", cut, (at+300)/fps)
	}
}
