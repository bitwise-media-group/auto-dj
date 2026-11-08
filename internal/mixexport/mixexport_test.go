// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package mixexport

import (
	"encoding/json"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/mixalign"
)

func tools(t *testing.T) {
	t.Helper()
	for _, tool := range []string{"ffmpeg", "ffprobe"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skip("needs ffmpeg and ffprobe")
		}
	}
}

func ff(t *testing.T, args ...string) {
	t.Helper()
	if out, err := exec.Command("ffmpeg", append([]string{"-v", "error", "-y"}, args...)...).CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg %v: %v %s", args, err, out)
	}
}

type stream struct {
	CodecType   string            `json:"codec_type"`
	Disposition map[string]int    `json:"disposition"`
	Duration    string            `json:"duration"`
	Tags        map[string]string `json:"tags"`
}

type probed struct {
	Streams []stream `json:"streams"`
	Format  struct {
		Duration string            `json:"duration"`
		Tags     map[string]string `json:"tags"`
	} `json:"format"`
}

func probe(t *testing.T, path string) probed {
	t.Helper()
	out, err := exec.Command("ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path).Output()
	if err != nil {
		t.Fatal(err)
	}
	var p probed
	if err := json.Unmarshal(out, &p); err != nil {
		t.Fatal(err)
	}
	return p
}

// TestExport cuts 30 s of audio into three files: they add up to the recording (within an
// AAC frame each), carry the tags and the cover, and the cue sheet indexes the cuts.
func TestExport(t *testing.T) {
	tools(t)
	dir := t.TempDir()
	rec, art := filepath.Join(dir, "REC001.WAV"), filepath.Join(dir, "cover.png")
	ff(t, "-f", "lavfi", "-i", "sine=f=330:d=30:sample_rate=44100", "-ac", "2", rec)
	ff(t, "-f", "lavfi", "-i", "color=c=red:s=64x64", "-frames:v", "1", art)
	a, err := ProbeAudio(rec)
	if err != nil || a.SampleRate != 44100 || a.Channels != 2 || a.Samples != 30*44100 {
		t.Fatalf("probe %+v %v", a, err)
	}
	sr := a.SampleRate
	cut := func(s float64) (string, int64) {
		n := int64(s * float64(sr))
		return mixalign.FormatTime(float64(n) / float64(sr)), n
	}
	e1 := &mixalign.Entry{No: 1, ID: "10", Title: "One", Status: mixalign.OK}
	e1.Cut, e1.CutSample = cut(0)
	e2 := &mixalign.Entry{No: 2, ID: "11", Title: "Gone", Status: mixalign.NotFoundState}
	e3 := &mixalign.Entry{No: 3, ID: "12", Title: "Two", Status: mixalign.OK}
	e3.Cut, e3.CutSample = cut(10.5)
	e4 := &mixalign.Entry{No: 4, ID: "13", Title: "Three/Four", Status: mixalign.NoAudio, Cut: "0:00:21.250"}
	f := &mixalign.File{SampleRate: sr, Channels: a.Channels, Samples: a.Samples,
		Tracks: []*mixalign.Entry{e1, e2, e3, e4}}
	tags := map[string]db.Tags{
		"10": {Title: "One (Original Mix)", Artist: "Oxia", Composer: "Giorgio Moroder", Genre: "Techno", Label: "Kompakt",
			Comment: "8A"},
		"12": {Title: "Two", Artist: "Two  Artists"},
	}
	opt := Options{Recording: rec, OutDir: filepath.Join(dir, "out"), Album: "Live at Dene Lodge", DJ: "DJ Deavon",
		Date: "2026-11-07", Art: art}
	ts, err := Plan(f, tags, opt.OutDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(ts) != 3 || ts[2].Start != 21250*int64(sr)/1000 || ts[1].End != ts[2].Start {
		t.Fatalf("plan %+v", ts)
	}
	wantNames := []string{"01 - Oxia - One (Original Mix).m4a", "02 - Two Artists - Two.m4a",
		"03 - Unknown Artist - Three_Four.m4a"}
	for i, x := range ts {
		if filepath.Base(x.File) != wantNames[i] {
			t.Errorf("file %d: %s, want %s", i, filepath.Base(x.File), wantNames[i])
		}
	}
	if err := Export(f, ts, opt); err != nil {
		t.Fatal(err)
	}
	checkFiles(t, ts, sr)
	checkSheets(t, f, ts, opt)
}

// checkFiles checks each file's length (within an AAC frame), cover and tags, and that they
// add up to the 30 s recording.
func checkFiles(t *testing.T, ts []Track, sr int) {
	t.Helper()
	total := 0.0
	for i, x := range ts {
		p := probe(t, x.File)
		d, _ := strconv.ParseFloat(p.Format.Duration, 64)
		want := float64(x.End-x.Start) / float64(sr)
		if math.Abs(d-want) > 1024.0/float64(sr)+1e-3 {
			t.Errorf("%s: %.4f s, want %.4f", filepath.Base(x.File), d, want)
		}
		total += d
		if !slices.ContainsFunc(p.Streams, func(s stream) bool {
			return s.CodecType == "video" && s.Disposition["attached_pic"] == 1
		}) {
			t.Errorf("%s: no cover", filepath.Base(x.File))
		}
		tg := p.Format.Tags
		if tg["album_artist"] != "DJ Deavon" || tg["album"] != "Live at Dene Lodge" ||
			tg["track"] != strconv.Itoa(i+1)+"/3" {
			t.Errorf("%s: tags %v", filepath.Base(x.File), tg)
		}
		if i == 0 && (tg["composer"] != "Giorgio Moroder" || tg["artist"] != "Oxia" || tg["title"] != "One (Original Mix)" ||
			tg["genre"] != "Techno" || tg["grouping"] != "Kompakt" || tg["comment"] != "8A") {
			t.Errorf("first file: tags %v", tg)
		}
	}
	if math.Abs(total-30) > 3*1024.0/float64(sr) {
		t.Errorf("the files add up to %.4f s, the recording is 30 s", total)
	}
}

func checkSheets(t *testing.T, f *mixalign.File, ts []Track, opt Options) {
	t.Helper()
	paths, err := WriteSheets(f, ts, opt)
	if err != nil {
		t.Fatal(err)
	}
	cue, _ := os.ReadFile(paths[0])
	for _, want := range []string{`FILE "REC001.WAV" WAVE`, "INDEX 01 00:10:37", "INDEX 01 00:21:18",
		`PERFORMER "DJ Deavon"`, `SONGWRITER "Giorgio Moroder"`} {
		if !strings.Contains(string(cue), want) {
			t.Errorf("cue sheet lacks %q:\n%s", want, cue)
		}
	}
	tl, _ := os.ReadFile(paths[1])
	if !strings.HasPrefix(string(tl), "0:00:00  Oxia – One (Original Mix)\n0:00:10  Two Artists – Two\n") {
		t.Errorf("tracklist:\n%s", tl)
	}
}

func TestCueTime(t *testing.T) {
	if got := cueTime(int64(6000.5*44100), 44100); got != "100:00:37" {
		t.Error(got)
	}
}

// TestTrimSilence: 1.5 s of silence, 10 s of tone, 2 s of silence. The first track starts
// 10 ms before the tone and the last ends where it stops; the cut between them stays.
func TestTrimSilence(t *testing.T) {
	tools(t)
	dir := t.TempDir()
	rec := filepath.Join(dir, "rec.wav")
	ff(t, "-f", "lavfi", "-i", "sine=f=440:d=10:sample_rate=48000", "-af", "adelay=1500:all=1,apad=pad_dur=2",
		"-ac", "2", rec)
	a, err := ProbeAudio(rec)
	if err != nil {
		t.Fatal(err)
	}
	sr := int64(a.SampleRate)
	e1 := &mixalign.Entry{No: 1, ID: "1", Status: mixalign.OK, Cut: "0:00:00.000"}
	e2 := &mixalign.Entry{No: 2, ID: "2", Status: mixalign.OK, CutSample: 6 * sr}
	e2.Cut = mixalign.FormatTime(6)
	f := &mixalign.File{SampleRate: a.SampleRate, Channels: a.Channels, Samples: a.Samples,
		Tracks: []*mixalign.Entry{e1, e2}}
	ts, err := Plan(f, nil, dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := TrimSilence(f, ts, rec); err != nil {
		t.Fatal(err)
	}
	near := func(got int64, want float64) bool { return math.Abs(float64(got)/float64(sr)-want) < 0.005 }
	if !near(ts[0].Start, 1.49) || ts[0].End != 6*sr || ts[1].Start != 6*sr || !near(ts[1].End, 11.5) {
		t.Errorf("trimmed to %.4f-%.4f, %.4f-%.4f s; want 1.49-6, 6-11.5", float64(ts[0].Start)/float64(sr),
			float64(ts[0].End)/float64(sr), float64(ts[1].Start)/float64(sr), float64(ts[1].End)/float64(sr))
	}
}
