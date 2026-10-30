// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package config

import (
	"maps"
	"os"
	"path/filepath"
	"testing"
)

func TestRenameTo(t *testing.T) {
	for _, tc := range []struct {
		name string
		hot  bool
		want string
	}{
		{"Cut-Out RES", false, "CUT OUT"}, {"CUT-IN DRACUL", false, "CUT IN"},
		{"cut-out", false, "CUT OUT"}, {"LONG CUT-OUT RES", false, "CUT OUT"},
		{"JUMP TO DROP", false, "JUMP"}, {"JUMP TO DROP", true, "JUMP"},
		{"JUMP", false, ""}, {"jump", true, ""},
		{"JUMPER", true, ""}, {"OUT", true, ""}, // D stays OUT
		{"CUT OUT", false, ""}, {"Low Pass", false, "FILTER"},
		{"CUT-OUTRO", false, ""}, {"CUT-OUT", true, ""}, // memory only
		{"Filter Out Out", false, "FILTER OUT"}, {"FILTER OUT IN", false, "FILTER IN"},
	} {
		if got := RenameTo(tc.name, tc.hot); got != tc.want {
			t.Errorf("RenameTo(%q, hot=%v) = %q, want %q", tc.name, tc.hot, got, tc.want)
		}
	}
}

func TestMemoryColors(t *testing.T) {
	// 0-based: 1 red, 3 yellow, 4 green
	want := map[string]int{"START": 1, "IN": 1, "LATE": 1, "DROP": 4, "VOCAL": 3, "JUMP": 0}
	for base, c := range map[string]int{"BASS SWAP": 2, "FILTER": 7, "CUT": 6} { // orange, purple, blue
		want[base], want[base+" IN"], want[base+" OUT"] = c, c, c
	}
	want["SYNC"], want["SYNC IN"], want["SYNC OUT"] = 1, 5, 5 // plain red, markers aqua
	if !maps.Equal(MemoryColor, want) {
		t.Fatalf("MemoryColor = %v", MemoryColor)
	}
	if len(MemoryColorOrder) != len(MemoryColor) {
		t.Fatal("MemoryColorOrder must list every MemoryColor name")
	}
	for _, n := range MemoryColorOrder {
		if _, ok := MemoryColor[n]; !ok {
			t.Errorf("%s has no colour", n)
		}
	}
}

func TestMapPathResolvesCloudLibrarySync(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "contents_123", "artist", "album", "track.aiff")
	if err := os.MkdirAll(filepath.Dir(f), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(f, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	oldCloud, oldMap := CloudDirs, PathMap
	t.Cleanup(func() { CloudDirs, PathMap = oldCloud, oldMap })
	CloudDirs, PathMap = []string{filepath.Join(dir, "missing"), dir}, nil
	if got := MapPath("/contents_123/artist/album/track.aiff"); got != f {
		t.Errorf("MapPath = %s, want %s", got, f)
	}
	if got := MapPath("/contents_123/artist/album/gone.aiff"); got != "/contents_123/artist/album/gone.aiff" {
		t.Errorf("missing file remapped to %s", got)
	}
	PathMap = parsePathMap("/Users/me/Music=/mnt/Music;bad;/Volumes/USB=/mnt/usb")
	if got := MapPath("/Volumes/USB/a.mp3"); got != "/mnt/usb/a.mp3" {
		t.Errorf("PathMap: %s", got)
	}
}
