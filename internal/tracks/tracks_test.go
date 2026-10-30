// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package tracks

import "testing"

// Expected values are the Python version's title_stem output. The accented cases are the
// ones where an ASCII-only \b would split differently ('Éfeat', 'Ftäler', 'Søft').
func TestTitleStem(t *testing.T) {
	for in, want := range map[string]string{
		"Don't Wake Up (Original Mix)": "dont wake up",
		"The Lost Hawk (Original Mix)": "lost hawk",
		"Café Feat. Zoë (Remix)":       "caf",
		"Rêverie ft. Ödön":             "r verie",
		"Señorita (Extended) [Label]":  "se orita",
		"Éfeat Song":                   "feat song",
		"Leftfield":                    "leftfield",
		"Lift Off feat Someone":        "lift off",
		"Daft Funk":                    "daft funk",
		"Über ft":                      "ber",
		"Naïveft x":                    "na veft x",
		"Ftäler":                       "ft ler",
		"Søft Touch":                   "s ft touch",
		"Mädchen feat.Ünder":           "m dchen",
		"  The   Thing  ":              "thing",
		"Theory of X":                  "theory of x",
		"":                             "",
		"2ft Under":                    "2ft under",
		"Árbol_ft":                     "rbol ft",
	} {
		if got := TitleStem(in); got != want {
			t.Errorf("TitleStem(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestNormLevel(t *testing.T) {
	band := make([]float64, 100)
	for i := range band {
		band[i] = float64(i + 1)
	}
	lv := NormLevel(band)
	// log10(100) - percentile 95 of log10(1..100) (1.97795...) + 1, clipped to 1.5
	if lv[99] < 1.022 || lv[99] > 1.023 || lv[0] != 0 {
		t.Fatalf("NormLevel = %v ... %v", lv[0], lv[99])
	}
}
