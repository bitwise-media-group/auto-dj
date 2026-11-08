// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package text

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestSlug(t *testing.T) {
	for in, want := range map[string]string{
		"Melodic Dark": "melodic-dark", "  Dark Mode (Live) 2026! ": "dark-mode-live-2026", "Café/Nuit": "café-nuit",
		"auto-dj demo": "auto-dj-demo", "../..": "set", "": "set",
	} {
		if got := Slug(in); got != want {
			t.Errorf("Slug(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestFileName(t *testing.T) {
	for in, want := range map[string]string{
		"Voicemail  (Tiësto Remix)": "Voicemail (Tiësto Remix)",
		"AC/DC: Back in Black?":     "AC_DC_ Back in Black_",
		"..hidden. ":                "hidden",
		"":                          "_",
		"Tiésto":                   "Tiésto",
		"tab\there\nnewline":        "tab here newline",
		`a"b<c>d|e*f\g`:             "a_b_c_d_e_f_g",
	} {
		if got := FileName(in); got != want {
			t.Errorf("FileName(%q) = %q, want %q", in, got, want)
		}
	}
	if got := FileName(strings.Repeat("é", 150)); len(got) > 200 || !utf8.ValidString(got) {
		t.Errorf("long name: %d bytes", len(got))
	}
}
