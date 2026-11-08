// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package mixexport cuts a set recording into one tagged AAC (.m4a) file per track at the
// cuts mixalign planned, and writes a cue sheet and a tracklist for the whole recording
// (docs/decisions/0017-split-recordings-by-alignment.md).
//
// The recording is decoded once and split at exact samples, so the files join back up into
// the recording with nothing lost or doubled. Each file keeps the track's own tags (title,
// artist, composer, genre, label as grouping, comment); the album is the set, its album
// artist the DJ, and every file carries the set's cover instead of the track's own art.
package mixexport

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/mixalign"
	"github.com/bitwise-media-group/auto-dj/internal/text"
)

// Encoders. Every one writes an MP4 edit list that trims the encoder's priming and padding,
// which is what gapless players (Music.app) read; each file is checked to hold exactly its
// samples.
const (
	// Auto is Apple's encoder through afconvert when it works here, else FFmpeg.
	Auto = "auto"
	// AFConvert encodes with macOS afconvert (Apple's AAC encoder); ffmpeg adds the tags and
	// cover by stream copy, keeping the edit list.
	AFConvert = "afconvert"
	// FFmpeg encodes with ffmpeg: Apple's encoder through AudioToolbox (aac_at) when it
	// works, else ffmpeg's own aac.
	FFmpeg = "ffmpeg"
)

// Audio is a recording's format.
type Audio struct {
	SampleRate int
	Channels   int
	Samples    int64
}

// ProbeAudio reads the first audio stream's sample rate, channels and length in samples.
func ProbeAudio(path string) (Audio, error) {
	out, err := exec.Command("ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
		"stream=sample_rate,channels,duration_ts,duration,time_base", "-of", "json", path).Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return Audio{}, fmt.Errorf("ffprobe %s: %w: %s", path, err, strings.TrimSpace(string(ee.Stderr)))
		}
		return Audio{}, fmt.Errorf("ffprobe: %w", err)
	}
	var p struct {
		Streams []struct {
			SampleRate string `json:"sample_rate"`
			Channels   int    `json:"channels"`
			DurationTS int64  `json:"duration_ts"`
			Duration   string `json:"duration"`
			TimeBase   string `json:"time_base"`
		} `json:"streams"`
	}
	if err := json.Unmarshal(out, &p); err != nil || len(p.Streams) == 0 {
		return Audio{}, fmt.Errorf("%s: no audio stream", path)
	}
	s := p.Streams[0]
	sr, _ := strconv.Atoi(s.SampleRate)
	a := Audio{SampleRate: sr, Channels: s.Channels}
	if s.DurationTS > 0 && s.TimeBase == "1/"+s.SampleRate {
		a.Samples = s.DurationTS
	} else if d, err := strconv.ParseFloat(s.Duration, 64); err == nil {
		a.Samples = int64(math.Round(d * float64(sr)))
	}
	if a.SampleRate <= 0 || a.Channels <= 0 || a.Samples <= 0 {
		return Audio{}, fmt.Errorf("%s: can't read the audio format", path)
	}
	return a, nil
}

// Options are what the export needs beyond the alignment.
type Options struct {
	Recording string
	OutDir    string
	Album     string // the set's name
	DJ        string // album artist
	Date      string // yyyy-mm-dd (or yyyy)
	Art       string // cover (jpg or png), "" for none
	Encoder   string // Auto (default), AFConvert or FFmpeg
	Bitrate   int    // bits per second (default 256000)
}

// Track is one exported file.
type Track struct {
	mixalign.Segment
	N    int
	Tags db.Tags
	File string // path
}

// Artist is the track's artist, "Unknown Artist" when the library has none.
func (t Track) Artist() string { return orUnknown(t.Tags.Artist, "Unknown Artist") }

// Title is the track's title from the library, else the history's.
func (t Track) Title() string {
	return orUnknown(t.Tags.Title, orUnknown(t.Entry.Title, "Unknown Title"))
}

// orUnknown is s with its runs of white space collapsed ("Voicemail  (Tiësto Remix)" has two),
// or def when s is blank.
func orUnknown(s, def string) string {
	if s = strings.Join(strings.Fields(s), " "); s == "" {
		return def
	}
	return s
}

// Plan names the files for the alignment's kept tracks (nothing is written).
func Plan(f *mixalign.File, tags map[string]db.Tags, outDir string) ([]Track, error) {
	segs, err := f.Segments()
	if err != nil {
		return nil, err
	}
	out := make([]Track, len(segs))
	for i, s := range segs {
		t := Track{Segment: s, N: i + 1, Tags: tags[s.ID]}
		t.File = filepath.Join(outDir, text.FileName(fmt.Sprintf("%02d - %s - %s", t.N, t.Artist(), t.Title()))+".m4a")
		out[i] = t
	}
	return out, nil
}

// Silence is the level below which the start and end of a recording count as silent.
const Silence = -60.0 // dBFS

// TrimSilence moves the first track's start to where the recording's sound begins and the
// last track's end to where it stops (the recorder usually runs a moment before the music
// starts and after it ends), keeping 10 ms before the sound so the first attack is whole.
// Only the stretches before the first track's end and after the last track's start are
// scanned.
func TrimSilence(f *mixalign.File, ts []Track, recording string) error {
	if len(ts) == 0 {
		return nil
	}
	thr := float32(math.Pow(10, Silence/20))
	first, last := &ts[0], &ts[len(ts)-1]
	lead, err := scanPCM(recording, f, first.Start, first.End, func(i int64, frame []float32) bool {
		return loud(frame, thr) // stop at the first loud frame
	})
	if err != nil {
		return err
	}
	if lead >= 0 {
		first.Start = max(first.Start, lead-int64(f.SampleRate)/100)
	}
	end := int64(-1)
	if _, err := scanPCM(recording, f, last.Start, last.End, func(i int64, frame []float32) bool {
		if loud(frame, thr) {
			end = i + 1
		}
		return false
	}); err != nil {
		return err
	}
	if end > last.Start {
		last.End = end
	}
	return nil
}

func loud(frame []float32, thr float32) bool {
	for _, v := range frame {
		if v > thr || v < -thr {
			return true
		}
	}
	return false
}

// scanPCM decodes the recording's samples [from, to) and calls fn on each frame until it
// returns true; it returns that frame's sample index, or -1.
func scanPCM(recording string, f *mixalign.File, from, to int64,
	fn func(i int64, frame []float32) bool) (int64, error) {
	if to <= from {
		return -1, nil
	}
	ss := strconv.FormatFloat(float64(from)/float64(f.SampleRate), 'f', 6, 64)
	cmd := exec.Command("ffmpeg", "-v", "error", "-ss", ss, "-i", recording, "-map", "0:a:0",
		"-af", fmt.Sprintf("atrim=end_sample=%d", to-from), "-f", "f32le", "-")
	out, err := cmd.StdoutPipe()
	if err != nil {
		return -1, err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return -1, err
	}
	r := bufio.NewReaderSize(out, 1<<20)
	buf := make([]byte, 4*f.Channels)
	frame := make([]float32, f.Channels)
	found := int64(-1)
	for i := from; ; i++ {
		if _, err := io.ReadFull(r, buf); err != nil {
			break
		}
		for c := range frame {
			frame[c] = math.Float32frombits(uint32(buf[4*c]) | uint32(buf[4*c+1])<<8 | uint32(buf[4*c+2])<<16 |
				uint32(buf[4*c+3])<<24)
		}
		if fn(i, frame) {
			found = i
			break
		}
	}
	_ = cmd.Process.Kill()
	_ = cmd.Wait()
	return found, nil
}

// Export writes the planned files: the recording is decoded once, and each track's samples
// are fed to its own encoder.
func Export(f *mixalign.File, ts []Track, opt Options) error {
	if err := os.MkdirAll(opt.OutDir, 0o755); err != nil {
		return err
	}
	if opt.Bitrate == 0 {
		opt.Bitrate = 256000
	}
	enc, err := Resolve(opt.Encoder)
	if err != nil {
		return err
	}
	dec := exec.Command("ffmpeg", "-v", "error", "-i", opt.Recording, "-map", "0:a:0", "-f", "f32le", "-")
	var decErr bytes.Buffer
	dec.Stderr = &decErr
	pipe, err := dec.StdoutPipe()
	if err != nil {
		return err
	}
	if err := dec.Start(); err != nil {
		return fmt.Errorf("ffmpeg: %w", err)
	}
	r := bufio.NewReaderSize(pipe, 1<<20)
	frame := int64(4 * f.Channels)
	pos := int64(0)
	fail := func(err error) error {
		_ = dec.Process.Kill()
		_ = dec.Wait()
		return err
	}
	for _, t := range ts {
		if _, err := io.CopyN(io.Discard, r, (t.Start-pos)*frame); err != nil {
			return fail(fmt.Errorf("reading %s: %w", opt.Recording, err))
		}
		want := (t.End - t.Start) * frame
		pcm := &counter{r: io.LimitReader(r, want)}
		if enc == AFConvert {
			err = encodeAFConvert(f, t, len(ts), pcm, opt)
		} else {
			err = encodeFFmpeg(f, t, len(ts), pcm, opt, enc)
		}
		if err == nil {
			err = checkSamples(t.File, t.End-t.Start, f.SampleRate)
		}
		if err == nil && pcm.n != want {
			err = fmt.Errorf("%s: the recording ended %d samples early: %s", filepath.Base(t.File), (want-pcm.n)/frame,
				strings.TrimSpace(decErr.String()))
		}
		if err != nil {
			return fail(err)
		}
		pos = t.End
	}
	_ = dec.Process.Kill() // the rest of the recording isn't needed
	_ = dec.Wait()
	return nil
}

// counter counts the bytes read through it.
type counter struct {
	r io.Reader
	n int64
}

func (c *counter) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += int64(n)
	return n, err
}

// ffmpegEncoder is aac_at when this ffmpeg has AudioToolbox and it opens (it doesn't inside a
// sandbox that hides the system's audio codecs), else ffmpeg's own aac.
var ffmpegEncoder = sync.OnceValue(func() string {
	err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "0.1",
		"-c:a", "aac_at", "-b:a", "256k", "-f", "null", "-").Run()
	if err == nil {
		return "aac_at"
	}
	return "aac"
})

// afconvertWorks reports whether afconvert can encode AAC here (a tiny test file).
var afconvertWorks = sync.OnceValue(func() bool {
	if _, err := exec.LookPath("afconvert"); err != nil {
		return false
	}
	dir, err := os.MkdirTemp("", "auto-dj-afconvert-")
	if err != nil {
		return false
	}
	defer func() { _ = os.RemoveAll(dir) }()
	wav := filepath.Join(dir, "t.wav")
	if exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "0.1",
		wav).Run() != nil {
		return false
	}
	return exec.Command("afconvert", "-f", "m4af", "-d", "aac", wav, filepath.Join(dir, "t.m4a")).Run() == nil
})

// Resolve turns an encoder choice into what will run: afconvert, aac_at or aac.
func Resolve(choice string) (string, error) {
	switch choice {
	case "", Auto:
		if afconvertWorks() {
			return AFConvert, nil
		}
		return ffmpegEncoder(), nil
	case AFConvert:
		if !afconvertWorks() {
			return "", errors.New("afconvert can't encode AAC here")
		}
		return AFConvert, nil
	case FFmpeg:
		return ffmpegEncoder(), nil
	}
	return "", fmt.Errorf("unknown encoder %q (want %s, %s or %s)", choice, Auto, AFConvert, FFmpeg)
}

// checkSamples checks the file plays exactly n samples (its edit list trims the priming and
// padding): what gapless playback needs.
func checkSamples(path string, n int64, sampleRate int) error {
	out, err := exec.Command("ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
		"stream=duration_ts,time_base", "-of", "csv=p=0", path).Output()
	if err != nil {
		return fmt.Errorf("ffprobe %s: %w", filepath.Base(path), err)
	}
	var tb string
	var d int64
	for _, field := range strings.Split(strings.TrimSpace(string(out)), ",") {
		if strings.Contains(field, "/") {
			tb = field
		} else if v, err := strconv.ParseInt(field, 10, 64); err == nil {
			d = v
		}
	}
	if tb != "1/"+strconv.Itoa(sampleRate) {
		return nil // a time base other than the sample rate: can't compare exactly
	}
	if d != n {
		return fmt.Errorf("%s plays %d samples, want %d: it won't be gapless", filepath.Base(path), d, n)
	}
	return nil
}

// tagArgs are the ffmpeg arguments for the cover and the tags of track t of n.
func tagArgs(t Track, n int, opt Options) []string {
	var args []string
	if opt.Art != "" {
		args = append(args, "-map", "1:v", "-c:v", "copy", "-disposition:v:0", "attached_pic")
	}
	tg := t.Tags
	md := [][2]string{
		{"title", t.Title()}, {"artist", t.Artist()}, {"composer", tg.Composer}, {"album", opt.Album},
		{"album_artist", opt.DJ}, {"genre", tg.Genre}, {"date", opt.Date}, {"track", fmt.Sprintf("%d/%d", t.N, n)},
		{"disc", "1/1"}, {"comment", tg.Comment}, {"grouping", tg.Label}, {"compilation", "0"},
		{"gapless_playback", "1"},
	}
	args = append(args, "-map_metadata", "-1")
	for _, kv := range md {
		if kv[1] != "" {
			args = append(args, "-metadata", kv[0]+"="+kv[1])
		}
	}
	return append(args, "-movflags", "+faststart")
}

func artInput(opt Options) []string {
	if opt.Art == "" {
		return nil
	}
	return []string{"-i", opt.Art}
}

func run(cmd *exec.Cmd, what string) error {
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s: %w: %s", what, err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func rawInput(f *mixalign.File) []string {
	return []string{"-f", "f32le", "-ar", strconv.Itoa(f.SampleRate), "-ac", strconv.Itoa(f.Channels), "-i", "-"}
}

func encodeFFmpeg(f *mixalign.File, t Track, n int, pcm io.Reader, opt Options, enc string) error {
	// ffmpeg's mp4 muxer writes the edit list from the encoder's priming and the last
	// packet's duration, so the file plays exactly its samples
	args := append([]string{"-v", "error", "-y"}, rawInput(f)...)
	args = append(args, artInput(opt)...)
	args = append(args, "-map", "0:a", "-c:a", enc, "-b:a", strconv.Itoa(opt.Bitrate))
	args = append(args, tagArgs(t, n, opt)...)
	tmp := t.File + ".part.m4a"
	cmd := exec.Command("ffmpeg", append(args, tmp)...)
	cmd.Stdin = pcm
	if err := run(cmd, "encoding "+filepath.Base(t.File)); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, t.File)
}

// encodeAFConvert writes the track's samples to a temporary WAV, encodes it with afconvert
// and remuxes it with ffmpeg to add the tags and cover (stream copy: the audio and its
// gapless info are kept).
func encodeAFConvert(f *mixalign.File, t Track, n int, pcm io.Reader, opt Options) error {
	dir, err := os.MkdirTemp("", "auto-dj-afconvert-")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(dir) }()
	wav, aac := filepath.Join(dir, "in.wav"), filepath.Join(dir, "out.m4a")
	cmd := exec.Command("ffmpeg", append(append([]string{"-v", "error", "-y"}, rawInput(f)...), "-c:a", "pcm_f32le",
		wav)...)
	cmd.Stdin = pcm
	if err := run(cmd, "writing "+wav); err != nil {
		return err
	}
	if err := run(exec.Command("afconvert", "-f", "m4af", "-d", "aac", "-b", strconv.Itoa(opt.Bitrate), "-q", "127",
		wav, aac), "afconvert"); err != nil {
		return err
	}
	args := append([]string{"-v", "error", "-y", "-i", aac}, artInput(opt)...)
	args = append(args, "-map", "0:a", "-c:a", "copy")
	args = append(args, tagArgs(t, n, opt)...)
	tmp := t.File + ".part.m4a"
	if err := run(exec.Command("ffmpeg", append(args, tmp)...), "tagging "+filepath.Base(t.File)); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, t.File)
}

// ------------------------------------------------------------------ cue sheet, tracklist

// cueTime is samples as a cue sheet's mm:ss:ff (75 frames a second; minutes may pass 99).
func cueTime(samples int64, sampleRate int) string {
	fr := samples * 75 / int64(sampleRate)
	return fmt.Sprintf("%02d:%02d:%02d", fr/75/60, fr/75%60, fr%75)
}

func cueQuote(s string) string { return `"` + strings.ReplaceAll(s, `"`, "'") + `"` }

// CueSheet is the cue sheet for the whole recording: one track per file, indexed at its cut.
func CueSheet(f *mixalign.File, ts []Track, opt Options) string {
	var b strings.Builder
	if opt.Date != "" {
		fmt.Fprintf(&b, "REM DATE %s\n", opt.Date)
	}
	fmt.Fprintf(&b, "PERFORMER %s\nTITLE %s\nFILE %s WAVE\n", cueQuote(opt.DJ), cueQuote(opt.Album),
		cueQuote(filepath.Base(opt.Recording)))
	for _, t := range ts {
		fmt.Fprintf(&b, "  TRACK %02d AUDIO\n    TITLE %s\n    PERFORMER %s\n", t.N, cueQuote(t.Title()),
			cueQuote(t.Artist()))
		if t.Tags.Composer != "" {
			fmt.Fprintf(&b, "    SONGWRITER %s\n", cueQuote(t.Tags.Composer))
		}
		fmt.Fprintf(&b, "    INDEX 01 %s\n", cueTime(t.Start, f.SampleRate))
	}
	return b.String()
}

// hms is samples as h:mm:ss (whole seconds, rounded down).
func hms(samples int64, sampleRate int) string {
	s := samples / int64(sampleRate)
	return fmt.Sprintf("%d:%02d:%02d", s/3600, s/60%60, s%60)
}

// TracklistEntry is one line of tracklist.json.
type TracklistEntry struct {
	N        int    `json:"n"`
	Start    string `json:"start"`
	Artist   string `json:"artist"`
	Title    string `json:"title"`
	ID       string `json:"id"`
	File     string `json:"file"`
	Status   string `json:"status"`
	Duration string `json:"duration"`
}

// Tracklist is the timestamped tracklist (text) and its JSON form.
func Tracklist(f *mixalign.File, ts []Track) (string, []TracklistEntry) {
	var b strings.Builder
	out := make([]TracklistEntry, 0, len(ts))
	for _, t := range ts {
		fmt.Fprintf(&b, "%s  %s – %s\n", hms(t.Start, f.SampleRate), t.Artist(), t.Title())
		out = append(out, TracklistEntry{N: t.N, Start: hms(t.Start, f.SampleRate), Artist: t.Artist(),
			Title: t.Title(), ID: t.ID, File: filepath.Base(t.File), Status: t.Status,
			Duration: mixalign.FormatTime(float64(t.End-t.Start) / float64(f.SampleRate))})
	}
	return b.String(), out
}

// WriteSheets writes <album>.cue, tracklist.txt and tracklist.json into the output folder and
// returns their paths.
func WriteSheets(f *mixalign.File, ts []Track, opt Options) ([]string, error) {
	if err := os.MkdirAll(opt.OutDir, 0o755); err != nil {
		return nil, err
	}
	cue := filepath.Join(opt.OutDir, text.FileName(opt.Album)+".cue")
	txt, js := Tracklist(f, ts)
	if err := os.WriteFile(cue, []byte(CueSheet(f, ts, opt)), 0o644); err != nil {
		return nil, err
	}
	tl := filepath.Join(opt.OutDir, "tracklist.txt")
	if err := os.WriteFile(tl, []byte(txt), 0o644); err != nil {
		return nil, err
	}
	tj := filepath.Join(opt.OutDir, "tracklist.json")
	return []string{cue, tl, tj}, db.WriteJSON(tj, js)
}
