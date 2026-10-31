// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package text

import "testing"

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
