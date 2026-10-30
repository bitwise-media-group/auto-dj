// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package anlz reads Rekordbox analysis files (ANLZ0000.DAT / .EXT): the beat grid (PQTZ)
// and the phrases (PSSI).
//
// Phrase analysis must be enabled in Rekordbox (Preferences > Analysis > Phrase) for PSSI
// to exist. The tag walker is lenient: it reads the two tags it needs and skips every
// other one unparsed, so header changes in tags we never use (Rekordbox has changed PQT2's,
// for one) can't break a load.
package anlz

import (
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Mood maps PSSI's mood (1 = high, 2 = mid, 3 = low) and phrase kind to a label.
var Mood = map[int]map[int]string{
	1: {1: "Intro", 2: "Up", 3: "Down", 5: "Chorus", 6: "Outro"},
	2: {
		1: "Intro", 2: "Verse1", 3: "Verse2", 4: "Verse3", 5: "Verse4", 6: "Verse5", 7: "Verse6",
		8: "Bridge", 9: "Chorus", 10: "Outro",
	},
	3: {
		1: "Intro", 2: "Verse1", 3: "Verse1", 4: "Verse1", 5: "Verse2", 6: "Verse2", 7: "Verse2",
		8: "Bridge", 9: "Chorus", 10: "Outro",
	},
}

// Normalise collapses mid/low-mood labels onto the high-mood vocabulary the rules use.
var Normalise = map[string]string{
	"Verse1": "Up", "Verse2": "Up", "Verse3": "Up", "Verse4": "Up", "Verse5": "Up", "Verse6": "Up",
	"Bridge": "Down",
}

// xorMask garbles PSSI in the files Rekordbox 6+ writes: every byte from offset 18 of the
// tag is XORed with mask[i % 19] + len_entries.
var xorMask = []byte{
	0xCB, 0xE1, 0xEE, 0xFA, 0xE5, 0xEE, 0xAD, 0xEE, 0xE9, 0xD2,
	0xE9, 0xEB, 0xE1, 0xE9, 0xF3, 0xE8, 0xE9, 0xF4, 0xE1,
}

// Phrase is a Rekordbox phrase start: 1-based beat and normalised label
// (Intro / Up / Down / Chorus / Outro).
type Phrase struct {
	Beat  int
	Label string
}

// Analysis is what the rules need from a track's ANLZ files.
type Analysis struct {
	Beats   []float64 // beat times (s); index i is beat i+1
	BNum    []int     // beat-in-bar number (1..4)
	Phrases []Phrase
	Mood    int // 0 without phrase analysis
}

// ErrFormat means an analysis file is not laid out as expected.
var ErrFormat = errors.New("anlz: malformed analysis file")

// Load reads the beat grid from the .DAT and the phrases from the .EXT (if present) of
// djmdContent.AnalysisDataPath under shareDir. A missing .DAT gives an error satisfying
// errors.Is(err, os.ErrNotExist).
func Load(shareDir, analysisDataPath string) (*Analysis, error) {
	p := shareDir + analysisDataPath
	base := strings.TrimSuffix(p, filepath.Ext(p))
	dat, err := os.ReadFile(base + ".DAT")
	if err != nil {
		return nil, err
	}
	a := &Analysis{}
	pq, err := findTag(dat, "PQTZ")
	if err != nil {
		return nil, fmt.Errorf("%s.DAT: %w", base, err)
	}
	if pq == nil {
		return nil, fmt.Errorf("%s.DAT: no beat grid (PQTZ): %w", base, ErrFormat)
	}
	if err := parsePQTZ(pq, a); err != nil {
		return nil, fmt.Errorf("%s.DAT: %w", base, err)
	}
	ext, err := os.ReadFile(base + ".EXT")
	if errors.Is(err, os.ErrNotExist) {
		return a, nil
	}
	if err != nil {
		return nil, err
	}
	ps, err := findTag(ext, "PSSI")
	if err != nil {
		return nil, fmt.Errorf("%s.EXT: %w", base, err)
	}
	if ps != nil {
		if err := parsePSSI(ps, a); err != nil {
			return nil, fmt.Errorf("%s.EXT: %w", base, err)
		}
	}
	return a, nil
}

// findTag returns the first tag of the given type (header included), or nil.
func findTag(data []byte, typ string) ([]byte, error) {
	if len(data) < 12 || string(data[:4]) != "PMAI" {
		return nil, ErrFormat
	}
	lenHeader := int(binary.BigEndian.Uint32(data[4:]))
	lenFile := min(int(binary.BigEndian.Uint32(data[8:])), len(data))
	for i := lenHeader; i < lenFile; {
		if i+12 > len(data) {
			return nil, ErrFormat
		}
		lenTag := int(binary.BigEndian.Uint32(data[i+8:]))
		if lenTag < 12 || i+lenTag > len(data) {
			return nil, ErrFormat
		}
		if string(data[i:i+4]) == typ {
			return data[i : i+lenTag], nil
		}
		i += lenTag
	}
	return nil, nil
}

// parsePQTZ: 12-byte tag header, 4 unknown bytes, 0x80000, entry count, then 8-byte
// entries (beat-in-bar u16, tempo u16, time in ms u32).
func parsePQTZ(tag []byte, a *Analysis) error {
	if len(tag) < 24 {
		return ErrFormat
	}
	n := int(binary.BigEndian.Uint32(tag[20:]))
	if 24+8*n > len(tag) {
		return ErrFormat
	}
	a.Beats = make([]float64, n)
	a.BNum = make([]int, n)
	for i := range n {
		e := tag[24+8*i:]
		a.BNum[i] = int(binary.BigEndian.Uint16(e))
		a.Beats[i] = float64(binary.BigEndian.Uint32(e[4:])) / 1000
	}
	return nil
}

// parsePSSI: 12-byte tag header, entry size (24), entry count u16 at 16, mood u16 at 18,
// ..., then 24-byte entries from offset 32 (index u16, beat u16, kind u16, ...).
func parsePSSI(tag []byte, a *Analysis) error {
	if len(tag) < 32 {
		return ErrFormat
	}
	nEntries := int(binary.BigEndian.Uint16(tag[16:]))
	if mood := binary.BigEndian.Uint16(tag[18:]); mood < 1 || mood > 3 { // garbled
		tag = append([]byte(nil), tag...)
		for x := range len(tag) - 18 {
			tag[18+x] ^= xorMask[x%len(xorMask)] + byte(nEntries)
		}
	}
	if 32+24*nEntries > len(tag) {
		return ErrFormat
	}
	a.Mood = int(binary.BigEndian.Uint16(tag[18:]))
	a.Phrases = make([]Phrase, nEntries)
	for i := range nEntries {
		e := tag[32+24*i:]
		kind := int(binary.BigEndian.Uint16(e[4:]))
		lab, ok := Mood[a.Mood][kind]
		if !ok {
			lab = strconv.Itoa(kind)
		}
		if n, ok := Normalise[lab]; ok {
			lab = n
		}
		a.Phrases[i] = Phrase{Beat: int(binary.BigEndian.Uint16(e[2:])), Label: lab}
	}
	return nil
}
