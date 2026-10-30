// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package db

import "testing"

func c(kind int, name string) Cue { return Cue{Kind: kind, Name: name} }

func TestClassify(t *testing.T) {
	for _, tc := range []struct {
		rating int
		cues   []Cue
		auto   bool
		want   string
	}{
		{3, nil, false, "manual"},
		{0, []Cue{c(1, "Energy 5")}, false, "mik"},
		{0, []Cue{c(1, "START"), c(2, "Energy 6")}, false, "mik"},
		{0, nil, false, "nohot"},
		{0, []Cue{c(0, "CUE(Auto)"), c(0, "DROP")}, false, "nohot"},
		{0, []Cue{c(1, "Energy 5"), c(0, "CUE(Auto)")}, false, "mik"},
		{0, []Cue{c(1, "IN"), c(3, "DROP"), c(5, "OUT")}, true, "auto"},
		{0, []Cue{c(1, "IN"), c(3, "DROP"), c(5, "OUT")}, false, "manual"},
		{0, []Cue{c(1, "Energy 5"), c(6, "ARIA")}, false, "other"},
	} {
		if got := Classify(tc.rating, tc.cues, tc.auto); got != tc.want {
			t.Errorf("Classify(%d, %v, %v) = %s, want %s", tc.rating, tc.cues, tc.auto, got, tc.want)
		}
	}
	if !Replaceable("CUE(Auto)", 0) || Replaceable("DROP", 0) {
		t.Error("Replaceable")
	}
}
