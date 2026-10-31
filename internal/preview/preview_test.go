// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package preview

import (
	"math"
	"math/cmplx"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"gonum.org/v1/gonum/dsp/fourier"

	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/setlist"
	"github.com/bitwise-media-group/auto-dj/internal/testtrack"
	"github.com/bitwise-media-group/auto-dj/internal/tracks"
)

var cue = testtrack.Cue

func near(a, b float64) bool { return math.Abs(a-b) <= 1e-6*math.Max(1, math.Abs(b)) }

func nearAll(t *testing.T, what string, got, want []float64) {
	t.Helper()
	if len(got) != len(want) {
		t.Errorf("%s = %v, want %v", what, got, want)
		return
	}
	for i := range got {
		if !near(got[i], want[i]) {
			t.Errorf("%s = %v, want %v", what, got, want)
			return
		}
	}
}

// mixPair is A (120 BPM) -> B (125 BPM), 160 beats each, 80 s of audio in dir.
func mixPair(t *testing.T, exit *setlist.Exit) (a, b *tracks.Track, order []db.PlaylistTrack, acts []setlist.Action) {
	t.Helper()
	dir := t.TempDir()
	a = testtrack.Synth(testtrack.Options{NB: 160, BPM: 120})
	b = testtrack.Synth(testtrack.Options{NB: 160, BPM: 125})
	for _, x := range []struct {
		t    *tracks.Track
		name string
	}{{a, "a.wav"}, {b, "b.wav"}} {
		x.t.Path, x.t.Length = filepath.Join(dir, x.name), 80
	}
	b.ID = "2"
	order = []db.PlaylistTrack{{ID: "1", Title: "A"}, {ID: "2", Title: "B"}}
	swap := 33
	acts = []setlist.Action{
		{E: &setlist.Slot{Name: "START", Beat: 1, Status: "new"}, G: &setlist.Slot{Name: "B", Beat: 97, Status: "new"},
			Exit: exit},
		{E: &setlist.Slot{Name: "A", Beat: 17, Status: "new"}, Swap: &swap},
	}
	return a, b, order, acts
}

func touch(t *testing.T, ts ...*tracks.Track) {
	t.Helper()
	for _, x := range ts {
		if err := os.WriteFile(x.Path, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func recsOf(a, b *tracks.Track) map[string]*tracks.Track {
	return map[string]*tracks.Track{"1": a, "2": b}
}

func TestMixTimelineFilter(t *testing.T) {
	a, b, order, acts := mixPair(t, &setlist.Exit{Name: "FILTER", A: 113, B: 33, Side: "out"})
	touch(t, a, b)
	segs := MixTimeline(order, acts, recsOf(a, b), 0, 0)
	sa, sb := segs[0], segs[1]
	const spb = 0.5              // 120 BPM
	if !near(sb.Start, 96*spb) { // B's E plays at A's G
		t.Errorf("B starts at %v", sb.Start)
	}
	if sa.Exit.Kind != "filter" {
		t.Fatalf("exit %v", sa.Exit)
	}
	nearAll(t, "exit", sa.Exit.Xs, []float64{112 * spb, 120 * spb, 124 * spb}) // 8-beat sweep, 4-beat fade
	if sa.End != sa.Exit.Xs[2] || sb.Clock.Split != sa.End {                   // B back to its own tempo after
		t.Errorf("end %v split %v", sa.End, sb.Clock.Split)
	}
	if sb.FadeIn == nil || !near(sb.FadeIn[0], 96*spb) || !near(sb.FadeIn[1], 104*spb) || sb.Sync {
		t.Errorf("fade in %v", sb.FadeIn)
	}
	if !near(sb.Clock.Rate, 120.0/125) {
		t.Errorf("rate %v", sb.Clock.Rate)
	}
	if !near(*sa.SwapT, (96+16)*spb) || !near(*sb.BassIn, *sa.SwapT) {
		t.Errorf("swap %v bass in %v", *sa.SwapT, *sb.BassIn)
	}
	if sa.BassOut == nil || !near(*sa.BassOut, *sa.SwapT) { // A loses its bass at the swap (here: as the sweep starts)
		t.Errorf("bass out %v", sa.BassOut)
	}
	if sb.Exit.Kind != "end" || sb.Exit.Xs[0] != sb.End {
		t.Errorf("B exit %v", sb.Exit)
	}
}

func TestMixTimelineFixedTempo(t *testing.T) {
	a, b, order, acts := mixPair(t, &setlist.Exit{Name: "FILTER", A: 113, B: 33, Side: "out"})
	touch(t, a, b)
	segs := MixTimeline(order, acts, recsOf(a, b), 0, 128)
	sa, sb := segs[0], segs[1]
	const spb = 60.0 / 128
	if !near(sa.Clock.Rate, 128.0/120) || !near(sa.Clock.Own, 128.0/120) {
		t.Errorf("A rate %v/%v", sa.Clock.Rate, sa.Clock.Own)
	}
	// B stays at the set's tempo after A has gone: no split
	if !near(sb.Clock.Rate, 128.0/125) || !near(sb.Clock.Own, 128.0/125) || sb.Clock.Split != sb.Start {
		t.Errorf("B rate %v/%v split %v", sb.Clock.Rate, sb.Clock.Own, sb.Clock.Split)
	}
	if !near(sb.Start, 96*spb) {
		t.Errorf("B starts at %v", sb.Start)
	}
	nearAll(t, "exit", sa.Exit.Xs, []float64{112 * spb, 120 * spb, 124 * spb})
	if !near(*sa.SwapT, (96+16)*spb) {
		t.Errorf("swap %v", *sa.SwapT)
	}
	if want := sb.Start + (80-16*60.0/125)*125/128; !near(sb.End, want) { // B's audio from E, at 128
		t.Errorf("B ends at %v, want %v", sb.End, want)
	}
	pa, pb := PairTimeline(order, acts, recsOf(a, b), 128)
	if !near(pb.Start, Lead*spb) || !near(pb.End, pa.End+Tail*spb) {
		t.Errorf("pair start %v end %v", pb.Start, pb.End)
	}
}

func TestMixTimelineCutAndMissingAudio(t *testing.T) {
	a, b, order, acts := mixPair(t, &setlist.Exit{Name: "CUT", A: 105, B: 25, Side: "out"})
	touch(t, a)
	segs := MixTimeline(order, acts, recsOf(a, b), 0, 0)
	// no B audio: A plays to its end
	if !segs[1].Missing || segs[0].Exit.Kind != "end" || segs[0].Exit.Xs[0] != segs[0].End {
		t.Errorf("missing B: %v %v", segs[1].Missing, segs[0].Exit)
	}
	touch(t, b)
	segs = MixTimeline(order, acts, recsOf(a, b), 0, 0)
	sa, sb := segs[0], segs[1]
	// cut before the swap at beat 113
	if sa.Exit.Kind != "cut" || sa.Exit.Xs[0] != 52 || sa.Exit.Xs[1] != 52 || sa.BassOut != nil {
		t.Errorf("exit %v bass out %v", sa.Exit, sa.BassOut)
	}
	if !near(*sb.BassIn, 52) { // B gets its bass when A is cut
		t.Errorf("bass in %v", *sb.BassIn)
	}
}

func TestMixTimelineSyncStartsAtFullVolume(t *testing.T) {
	a, b, order, acts := mixPair(t, nil)
	acts[1].Sync = true
	touch(t, a, b)
	segs := MixTimeline(order, acts, recsOf(a, b), 0, 0)
	sa, sb := segs[0], segs[1]
	if !sb.Sync || sb.FadeIn != nil || !near(sb.Start, 48) {
		t.Errorf("sync %v fade %v start %v", sb.Sync, sb.FadeIn, sb.Start)
	}
	if sa.Exit.Kind != "fade" { // no exit marker: fade from the swap
		t.Fatalf("exit %v", sa.Exit)
	}
	nearAll(t, "fade", sa.Exit.Xs, []float64{56, 60})
}

func pieces(r *Route) []Piece { return r.Pieces }

func TestJumpRoute(t *testing.T) {
	tr := testtrack.Synth(testtrack.Options{NB: 160, BPM: 120}) // beat n at (n - 1) / 2 s
	tr.Length = 80
	tr.Cues = []db.Cue{cue(tr, 33, "JUMP", 0), cue(tr, 97, "JUMP TO DROP", 7)}
	r := JumpRoute(tr, 0)
	if !slices.Equal(pieces(r), []Piece{{0, 16}, {48, 80}}) || !slices.Equal(r.Jumps(), []float64{16}) {
		t.Errorf("route %v jumps %v", r.Pieces, r.Jumps())
	}
	if _, ok := r.Play(20, 0); ok {
		t.Error("20 s is skipped")
	}
	if q, _ := r.Play(50, 0); !near(q, 18) {
		t.Errorf("Play(50) = %v", q)
	}
	if p := pieces(JumpRoute(tr, 20)); !slices.Equal(p, []Piece{{20, 80}}) { // starts after the JUMP
		t.Errorf("from 20: %v", p)
	}
	if p := pieces(JumpRoute(tr, 0, 30)); !slices.Equal(p, []Piece{{0, 80}}) { // jumping would skip G
		t.Errorf("keep 30: %v", p)
	}
	tr.Cues = []db.Cue{cue(tr, 33, "JUMP", 7), cue(tr, 33, "JUMP", 0), cue(tr, 97, "JUMP", 0)} // landing + jump back
	if p := pieces(JumpRoute(tr, 0)); !slices.Equal(p, []Piece{{0, 48}, {16, 80}}) {           // back once, then on
		t.Errorf("jump back: %v", p)
	}
	tr.Cues = []db.Cue{
		cue(tr, 17, "JUMP", 0), cue(tr, 65, "JUMP", 0), cue(tr, 41, "JUMP", 7), cue(tr, 81, "JUMP AGAIN", 6),
	}
	if p := pieces(JumpRoute(tr, 0)); !slices.Equal(p, []Piece{{0, 8}, {20, 32}, {40, 80}}) { // n-th jump, n-th hot cue
		t.Errorf("n-th: %v", p)
	}
	tr.Cues = []db.Cue{cue(tr, 33, "JUMP", 0)}
	if p := pieces(JumpRoute(tr, 0)); !slices.Equal(p, []Piece{{0, 80}}) { // no JUMP hot cue
		t.Errorf("no pad: %v", p)
	}
}

func TestMixTimelineFollowsJumps(t *testing.T) {
	a, b, order, acts := mixPair(t, &setlist.Exit{Name: "FILTER", A: 113, B: 33, Side: "out"})
	touch(t, a, b)
	a.Cues = []db.Cue{cue(a, 33, "JUMP", 0), cue(a, 49, "JUMP", 7)} // skips 16 beats (8 s) before G
	segs := MixTimeline(order, acts, recsOf(a, b), 0, 0)
	sa, sb := segs[0], segs[1]
	nearAll(t, "jumps", sa.Jumps, []float64{16})
	if !near(sb.Start, 40) || !near(sa.Exit.Xs[0], 48) { // all 8 s earlier
		t.Errorf("start %v exit %v", sb.Start, sa.Exit.Xs)
	}
	pa, pb := PairTimeline(order, acts, recsOf(a, b), 0) // from 8 beats before G: no jump
	if pa.Start != 0 || !near(pb.Start, 4) || len(pa.Jumps) != 0 {
		t.Errorf("pair start %v/%v jumps %v", pa.Start, pb.Start, pa.Jumps)
	}
	if !near(pb.End, pa.End+Tail*0.5) || pb.Exit.Kind != "end" {
		t.Errorf("pair end %v exit %v", pb.End, pb.Exit)
	}
	a.Cues = []db.Cue{cue(a, 93, "JUMP", 0), cue(a, 33, "JUMP", 7)} // 4 beats before G, back 60 beats
	pa, pb = PairTimeline(order, acts, recsOf(a, b), 0)
	if !near(pb.Start, 4) || len(pa.Jumps) != 0 { // the clip starts after the jump back
		t.Errorf("pair start %v jumps %v", pb.Start, pa.Jumps)
	}
	if !near(pa.Clock.Src0, 46+(48-16)-4) { // G (48 s) played at 78 s, from 4 s before
		t.Errorf("src0 %v", pa.Clock.Src0)
	}
}

func TestLowpassSweepClosesDown(t *testing.T) {
	rng := rand.New(rand.NewPCG(0, 0))
	y := make(Stereo, SR*4)
	for i := range y {
		y[i] = [2]float32{float32(rng.NormFloat64()), float32(rng.NormFloat64())}
	}
	z := lowpassSweep(y, 0)
	hf := func(s Stereo) float64 { // mean |FFT| above 4 kHz, left channel
		seq := make([]float64, len(s))
		for i, v := range s {
			seq[i] = float64(v[0])
		}
		c := fourier.NewFFT(len(s)).Coefficients(nil, seq)
		sum, n := 0.0, 0
		for k, v := range c {
			if float64(k)*SR/float64(len(s)) > 4000 {
				sum += cmplx.Abs(v)
				n++
			}
		}
		return sum / float64(n)
	}
	q := len(y) / 16
	if hf(z[:q]) <= 0.5*hf(y[:q]) { // still open at the start
		t.Errorf("start: %v vs %v", hf(z[:q]), hf(y[:q]))
	}
	if hf(z[len(z)-q:]) >= 0.05*hf(y[len(y)-q:]) { // closed (above 4 kHz) by the end
		t.Errorf("end: %v vs %v", hf(z[len(z)-q:]), hf(y[len(y)-q:]))
	}
}

func TestLowCutKeepsHighs(t *testing.T) {
	n := 10007 // prime: padded to a fast length
	y := make(Stereo, n)
	for i := range y {
		v := float32(math.Sin(2*math.Pi*50*float64(i)/SR) + math.Sin(2*math.Pi*1000*float64(i)/SR))
		y[i] = [2]float32{v, v}
	}
	z := lowCut(y)
	var e50, e1k float64
	for i := 2000; i < n-2000; i++ { // away from the edges: z should be the 1 kHz sine alone
		hi := math.Sin(2 * math.Pi * 1000 * float64(i) / SR)
		e1k += math.Abs(float64(z[i][0]) - hi)
		e50 += math.Abs(float64(y[i][0]) - hi)
	}
	if e1k > 0.05*e50 {
		t.Errorf("50 Hz not removed: residual %v of %v", e1k, e50)
	}
}

func TestRenderSet(t *testing.T) {
	for _, tool := range []string{"ffmpeg", "ffprobe"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skip("needs ffmpeg and ffprobe")
		}
	}
	a, b, order, acts := mixPair(t, &setlist.Exit{Name: "FILTER", A: 113, B: 33, Side: "out"})
	a.Cues = []db.Cue{cue(a, 33, "JUMP", 0), cue(a, 49, "JUMP", 7)} // rendered through the jump
	for _, x := range []struct {
		t  *tracks.Track
		hz int
	}{{a, 220}, {b, 330}} {
		out, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=f="+strconv.Itoa(x.hz)+":d=80",
			"-ac", "2", x.t.Path).CombinedOutput()
		if err != nil {
			t.Fatalf("ffmpeg: %v %s", err, out)
		}
	}
	for _, bpm := range []float64{0, 128} {
		segs := MixTimeline(order, acts, recsOf(a, b), 0, bpm)
		out, err := RenderSet(segs, filepath.Join(t.TempDir(), "set.mp3"))
		if err != nil {
			t.Fatal(err)
		}
		probe, err := exec.Command("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
			out).Output()
		if err != nil {
			t.Fatal(err)
		}
		dur, _ := strconv.ParseFloat(strings.TrimSpace(string(probe)), 64)
		if want, _ := MixInfo(segs); math.Abs(dur-want) > 0.2 {
			t.Errorf("bpm %v: set.mp3 is %v s, timeline says %v s", bpm, dur, want)
		}
	}
}
