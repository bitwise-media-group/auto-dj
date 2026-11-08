// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package features computes per-frame band energies from the track audio (ffmpeg + FFT).
//
// Columns: 0 sub/kick+bass 30-120 Hz | 1 low-mid 120-500 | 2 mid 500-2500 | 3 high 2500-5500
// | 4 low-band spectral flux | 5 high-band spectral flux. Decoded at 11025 Hz mono, FFT 1024,
// hop 256 (~43 frames/s), in float32 like the numpy original. One .f32.gz per track.
package features

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/md5"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"math/cmplx"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	"golang.org/x/text/unicode/norm"
	"gonum.org/v1/gonum/dsp/fourier"

	"github.com/bitwise-media-group/auto-dj/internal/num"
)

const (
	// SR is the decode sample rate.
	SR = 11025
	// NFFT is the FFT size.
	NFFT = 1024
	// Hop is the frame step in samples.
	Hop = 256
	// FPS is frames per second.
	FPS = float64(SR) / Hop
	// Cols is the number of feature columns.
	Cols = 6
)

// Bands are the band-power ranges (Hz) of columns 0..3.
var Bands = [4][2]float64{{30, 120}, {120, 500}, {500, 2500}, {2500, 5500}}

// Frame is one frame's (or beat's) features.
type Frame [Cols]float32

// key names a track's cache file by its NFC file name, so a cache survives the library
// moving between machines.
func key(path string) string {
	sum := md5.Sum([]byte(norm.NFC.String(filepath.Base(path))))
	return hex.EncodeToString(sum[:])
}

// CachePath is where audioPath's features are cached.
func CachePath(featureDir, audioPath string) string {
	return filepath.Join(featureDir, key(audioPath)+".f32.gz")
}

// Decode returns the audio as mono float32 at SR.
func Decode(path string) ([]float32, error) {
	cmd := exec.Command("ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", fmt.Sprint(SR), "-f", "f32le", "-")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("ffmpeg: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	y := make([]float32, len(out)/4)
	for i := range y {
		y[i] = math.Float32frombits(binary.LittleEndian.Uint32(out[4*i:]))
	}
	return y, nil
}

// DecodeFrames is FrameFeatures(Decode(path)) without holding the decoded audio: ffmpeg's
// output is processed a chunk at a time, so a recording of several hours fits in memory.
func DecodeFrames(path string) ([]Frame, error) {
	cmd := exec.Command("ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", fmt.Sprint(SR), "-f", "f32le", "-")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("ffmpeg: %w", err)
	}
	F, ferr := framesOf(out, 1<<20)
	if ferr != nil {
		_ = cmd.Process.Kill()
	}
	if err := cmd.Wait(); err != nil && ferr == nil {
		return nil, fmt.Errorf("ffmpeg: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return F, ferr
}

// framesOf computes FrameFeatures over f32le mono audio read from r, chunk samples (a
// multiple of Hop) at a time. Each chunk after the first starts on the previous chunk's
// last frame, which is dropped, so the flux columns match FrameFeatures exactly.
func framesOf(r io.Reader, chunk int) ([]Frame, error) {
	br := bufio.NewReaderSize(r, 1<<16)
	var out []Frame
	buf := make([]float32, 0, chunk+NFFT)
	first := true
	var raw [4]byte
	flush := func(y []float32) error {
		F, err := FrameFeatures(y)
		if err != nil {
			return err
		}
		if !first {
			F = F[1:]
		}
		first = false
		out = append(out, F...)
		return nil
	}
	for {
		_, err := io.ReadFull(br, raw[:])
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		buf = append(buf, math.Float32frombits(binary.LittleEndian.Uint32(raw[:])))
		if len(buf) == chunk+NFFT {
			if err := flush(buf); err != nil {
				return nil, err
			}
			buf = append(buf[:0], buf[chunk:]...)
		}
	}
	if len(buf) >= NFFT && (first || len(buf) > NFFT) {
		if err := flush(buf); err != nil {
			return nil, err
		}
	}
	if first {
		return nil, fmt.Errorf("audio too short (%d samples)", len(buf))
	}
	return out, nil
}

// bandMasks returns, per band, the rfft bins with a <= f < b (np.fft.rfftfreq(NFFT, 1/SR)).
func bandMasks() [4][]int {
	val := 1.0 / (float64(NFFT) * (1.0 / SR))
	var idx [4][]int
	for k := 0; k <= NFFT/2; k++ {
		f := float64(k) * val
		for j, b := range Bands {
			if f >= b[0] && f < b[1] {
				idx[j] = append(idx[j], k)
			}
		}
	}
	return idx
}

// FrameFeatures computes the per-frame features of mono audio y.
func FrameFeatures(y []float32) ([]Frame, error) {
	n := 1 + floorDiv(len(y)-NFFT, Hop)
	if n < 0 {
		return nil, fmt.Errorf("audio too short (%d samples)", len(y))
	}
	hann := num.Hann(NFFT)
	win := make([]float32, NFFT)
	for i, w := range hann {
		win[i] = float32(w)
	}
	idx := bandMasks()
	fft := fourier.NewFFT(NFFT)
	seq := make([]float64, NFFT)
	coef := make([]complex128, NFFT/2+1)
	nb := NFFT/2 + 1
	S := make([]float32, nb)
	L, prev := make([]float32, nb), make([]float32, nb)
	buf := make([]float32, nb)
	out := make([]Frame, n)
	for f := range n {
		fr := y[f*Hop : f*Hop+NFFT]
		for k, v := range fr {
			seq[k] = float64(v * win[k])
		}
		coef = fft.Coefficients(coef, seq)
		for k, c := range coef {
			S[k] = float32(cmplx.Abs(c))
		}
		for j, m := range idx {
			buf = buf[:0]
			for _, k := range m {
				buf = append(buf, S[k]*S[k])
			}
			out[f][j] = num.Sum(buf)
		}
		for k, s := range S {
			L[k] = float32(math.Log1p(float64(100 * s)))
		}
		if f == 0 {
			copy(prev, L)
		}
		for c, m := range [2][]int{idx[0], idx[3]} {
			buf = buf[:0]
			for _, k := range m {
				buf = append(buf, max(L[k]-prev[k], 0))
			}
			out[f][4+c] = num.Sum(buf)
		}
		prev, L = L, prev
	}
	return out, nil
}

func floorDiv(a, b int) int {
	q := a / b
	if (a%b != 0) && ((a < 0) != (b < 0)) {
		q--
	}
	return q
}

// ------------------------------------------------------------------ cache file

// The cache file is gzip over: magic "ADJF", version, frame count, column count (uint32 LE
// each), then the frames as float32 little-endian, row by row.
const (
	magic   = "ADJF"
	version = 1
)

type header struct {
	Magic             [4]byte
	Version, N, NCols uint32
}

// Save writes frames to path (atomically).
func Save(path string, F []Frame) error {
	var b bytes.Buffer
	zw := gzip.NewWriter(&b)
	hdr := header{Version: version, N: uint32(len(F)), NCols: Cols}
	copy(hdr.Magic[:], magic)
	if err := binary.Write(zw, binary.LittleEndian, hdr); err != nil {
		return err
	}
	if err := binary.Write(zw, binary.LittleEndian, F); err != nil {
		return err
	}
	if err := zw.Close(); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b.Bytes(), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Load reads a cache file written by Save.
func Load(path string) ([]Frame, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	zr, err := gzip.NewReader(f)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	r := bufio.NewReader(zr)
	var hdr header
	if err := binary.Read(r, binary.LittleEndian, &hdr); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if string(hdr.Magic[:]) != magic || hdr.Version != version || hdr.NCols != Cols {
		return nil, fmt.Errorf("%s: not a version %d feature cache", path, version)
	}
	F := make([]Frame, hdr.N)
	if err := binary.Read(r, binary.LittleEndian, F); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return F, nil
}

// ------------------------------------------------------------------ extraction

// Result is one file's extraction outcome: "cached", "ok" or "error: ...".
type Result struct {
	Path, Status string
}

func extractOne(audioPath, featureDir string) string {
	out := CachePath(featureDir, audioPath)
	if _, err := os.Stat(out); err == nil {
		return "cached"
	}
	y, err := Decode(audioPath)
	if err != nil {
		return "error: " + err.Error()
	}
	F, err := FrameFeatures(y)
	if err != nil {
		return "error: " + err.Error()
	}
	if err := Save(out, F); err != nil {
		return "error: " + err.Error()
	}
	return "ok"
}

// ExtractMany caches features for every path with `workers` decodes in parallel. Results
// are in input order.
func ExtractMany(paths []string, featureDir string, workers int) ([]Result, error) {
	if err := os.MkdirAll(featureDir, 0o755); err != nil {
		return nil, err
	}
	res := make([]Result, len(paths))
	jobs := make(chan int)
	var wg sync.WaitGroup
	for range max(workers, 1) {
		wg.Go(func() {
			for i := range jobs {
				res[i] = Result{paths[i], extractOne(paths[i], featureDir)}
			}
		})
	}
	for i := range paths {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
	return res, nil
}

// PerBeat averages the cached frame features over each beat of the Rekordbox grid ->
// (n_beats, 6). It returns nil (no error) when audioPath has no cache file.
func PerBeat(featureDir, audioPath string, beats []float64, bpm float64) ([][Cols]float64, error) {
	F, err := Load(CachePath(featureDir, audioPath))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return perBeat(F, beats, bpm), nil
}

func perBeat(F []Frame, beats []float64, bpm float64) [][Cols]float64 {
	nb := len(beats)
	if nb == 0 {
		return nil
	}
	edges := append(append([]float64(nil), beats...), beats[nb-1]+60/math.Max(bpm, 1))
	fb := make([][Cols]float64, nb)
	for i := range nb {
		a := int(edges[i] * FPS)
		b := max(a+1, int(edges[i+1]*FPS))
		if a >= len(F) || a < 0 {
			continue
		}
		b = min(b, len(F))
		// numpy's mean over axis 0: a running float32 sum per column, then / count
		var s Frame
		for _, fr := range F[a:b] {
			for j := range s {
				s[j] += fr[j]
			}
		}
		for j := range s {
			fb[i][j] = float64(s[j] / float32(b-a))
		}
	}
	return fb
}

// Frames returns audioPath's frame features from the cache, decoding (and caching) them
// when they aren't there yet.
func Frames(featureDir, audioPath string) ([]Frame, error) {
	if F, err := Load(CachePath(featureDir, audioPath)); err == nil {
		return F, nil
	}
	if r := extractOne(audioPath, featureDir); strings.HasPrefix(r, "error") {
		return nil, errors.New(strings.TrimPrefix(r, "error: "))
	}
	return Load(CachePath(featureDir, audioPath))
}

// RecordingFrames returns a long recording's frame features, cached by its path, size and
// modification time (recordings are often all called REC001.WAV).
func RecordingFrames(featureDir, path string) ([]Frame, error) {
	st, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	abs, _ := filepath.Abs(path)
	sum := md5.Sum(fmt.Appendf(nil, "%s|%d|%d", norm.NFC.String(abs), st.Size(), st.ModTime().UnixNano()))
	cache := filepath.Join(featureDir, "recordings", hex.EncodeToString(sum[:])+".f32.gz")
	if F, err := Load(cache); err == nil {
		return F, nil
	}
	F, err := DecodeFrames(path)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(cache), 0o755); err != nil {
		return nil, err
	}
	return F, Save(cache, F)
}
