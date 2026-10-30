// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package review renders a plan as a self-contained HTML review page (an energy strip and
// cue markers per track). It also embeds the set-list page template used by preview.
package review

import (
	"embed"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/bitwise-media-group/adj/internal/num"
	"github.com/bitwise-media-group/adj/internal/plan"
	"github.com/bitwise-media-group/adj/internal/tracks"
)

//go:embed templates/*.html
var templates embed.FS

// Template returns an embedded page template (review.html, setlist.html).
func Template(name string) string {
	b, err := templates.ReadFile("templates/" + name)
	if err != nil {
		panic(err) // embedded at build time
	}
	return string(b)
}

type row struct {
	T   string  `json:"t"`
	A   string  `json:"a"`
	BPM float64 `json:"bpm"`
	NB  int     `json:"nb"`
	Dur float64 `json:"dur"`
	H   [][]any `json:"h"`
	M   [][]any `json:"m"`
	Ph  [][]any `json:"ph"`
	Lo  *string `json:"lo,omitempty"`
	Md  *string `json:"md,omitempty"`
}

func makeRow(t *tracks.Track, x plan.Item) row {
	nb := len(t.Beats)
	r := row{T: x.Title, BPM: x.BPM, NB: nb, Dur: num.RoundTo(t.Beats[nb-1], 1),
		H: [][]any{}, M: [][]any{}, Ph: [][]any{}}
	if !strings.HasPrefix(t.Path, "/contents_") {
		r.A, _, _ = strings.Cut(filepath.Base(t.Path), " - ")
		if t.Path == "" {
			r.A = ""
		}
	}
	for _, c := range x.Hot {
		r.H = append(r.H, []any{c.Name, c.Beat, num.RoundTo(float64(c.MS)/1000, 2)})
	}
	for _, c := range x.Mem {
		r.M = append(r.M, []any{c.Name, c.Beat, num.RoundTo(float64(c.MS)/1000, 2)})
	}
	for _, p := range t.Phrases {
		first := ""
		for _, ch := range p.Label {
			first = string(ch)
			break
		}
		r.Ph = append(r.Ph, []any{p.Beat, first})
	}
	if t.HasFB() {
		const k = 4
		strip := func(lv []float64) *string {
			var b strings.Builder
			for i := range nb / k {
				b.WriteString(strconv.Itoa(min(9, int(num.Mean(lv[i*k:(i+1)*k])*9))))
			}
			s := b.String()
			return &s
		}
		r.Lo = strip(tracks.NormLevel(t.Col(0)))
		r.Md = strip(tracks.NormLevel(t.Col(2)))
	}
	return r
}

// Render writes the review page for the plan to out.
func Render(ts []*tracks.Track, p []plan.Item, out string) (string, error) {
	byID := map[string]*tracks.Track{}
	for _, t := range ts {
		byID[t.ID] = t
	}
	rows := []row{}
	for _, x := range p {
		if t, ok := byID[x.ID]; ok {
			rows = append(rows, makeRow(t, x))
		}
	}
	sort.SliceStable(rows, func(i, j int) bool {
		ai, aj := strings.ToLower(rows[i].A), strings.ToLower(rows[j].A)
		if ai != aj {
			return ai < aj
		}
		return strings.ToLower(rows[i].T) < strings.ToLower(rows[j].T)
	})
	data, err := json.Marshal(rows)
	if err != nil {
		return "", err
	}
	html := strings.ReplaceAll(Template("review.html"), "__DATA__", string(data))
	html = strings.ReplaceAll(html, "__COUNT__", strconv.Itoa(len(rows)))
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return "", err
	}
	return out, os.WriteFile(out, []byte(html), 0o644)
}
