// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package anlz

import (
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"testing"
)

// testdata/PIONEER/USBANLZ/fix is a real track's ANLZ0000.DAT / .EXT trimmed to the PQTZ,
// PCOB, PCO2 and PSSI tags; want.json is what the Python version (pyrekordbox) read from it.
const fixture = "/PIONEER/USBANLZ/fix/ANLZ0000.DAT"

// want.json holds phrases as [beat, "label"] pairs.
type want struct {
	Beats   []float64 `json:"beats"`
	BNum    []int     `json:"bnum"`
	Phrases [][]any   `json:"phrases"`
	Mood    int       `json:"mood"`
}

func TestLoadMatchesPyrekordbox(t *testing.T) {
	raw, err := os.ReadFile("testdata/want.json")
	if err != nil {
		t.Fatal(err)
	}
	var w want
	if err := json.Unmarshal(raw, &w); err != nil {
		t.Fatal(err)
	}
	a, err := Load("testdata", fixture)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(a.Beats, w.Beats) || !reflect.DeepEqual(a.BNum, w.BNum) || a.Mood != w.Mood {
		t.Fatalf("beat grid or mood differs: %d beats, mood %d", len(a.Beats), a.Mood)
	}
	if len(a.Phrases) != len(w.Phrases) {
		t.Fatalf("got %d phrases, want %d", len(a.Phrases), len(w.Phrases))
	}
	for i, p := range w.Phrases {
		if a.Phrases[i].Beat != int(p[0].(float64)) || a.Phrases[i].Label != p[1].(string) {
			t.Errorf("phrase %d = %v, want %v", i, a.Phrases[i], p)
		}
	}
}

func TestPSSIMaskedAndPlain(t *testing.T) {
	ext, err := os.ReadFile("testdata/PIONEER/USBANLZ/fix/ANLZ0000.EXT")
	if err != nil {
		t.Fatal(err)
	}
	tag, err := findTag(ext, "PSSI")
	if err != nil || tag == nil {
		t.Fatalf("no PSSI: %v", err)
	}
	toggled := append([]byte(nil), tag...) // XOR is its own inverse: flips masked <-> plain
	n := toggled[17]
	for x := range len(toggled) - 18 {
		toggled[18+x] ^= xorMask[x%len(xorMask)] + n
	}
	var a, b Analysis
	if err := parsePSSI(tag, &a); err != nil {
		t.Fatal(err)
	}
	if err := parsePSSI(toggled, &b); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(a, b) || a.Mood < 1 || a.Mood > 3 || len(a.Phrases) == 0 {
		t.Fatalf("masked and plain PSSI disagree: %+v vs %+v", a, b)
	}
}

func TestMissingDAT(t *testing.T) {
	if _, err := Load("testdata", "/nope/ANLZ0000.DAT"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("want ErrNotExist, got %v", err)
	}
}
