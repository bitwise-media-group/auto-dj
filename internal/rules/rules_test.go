// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package rules_test

import (
	"slices"
	"testing"

	"github.com/bitwise-media-group/auto-dj/internal/anlz"
	"github.com/bitwise-media-group/auto-dj/internal/config"
	"github.com/bitwise-media-group/auto-dj/internal/rules"
	"github.com/bitwise-media-group/auto-dj/internal/testtrack"
)

func TestHotCuesFollowTemplate(t *testing.T) {
	h := rules.HotCues(testtrack.Synth(testtrack.Options{}), config.DefaultRules)
	if h["IN"] != 65 || h["BRIDGE"] != 257 || h["DROP"] != 321 {
		t.Fatalf("IN/BRIDGE/DROP = %d/%d/%d", h["IN"], h["BRIDGE"], h["DROP"])
	}
	if h["IN"] >= h["BRIDGE"] || h["BRIDGE"] >= h["DROP"] || h["DROP"] >= h["OUT"] || h["OUT"] >= h["EMERGENCY"] {
		t.Fatalf("cue order: %v", h)
	}
	if h["EMERGENCY"]+32 > 625 {
		t.Errorf("loop must end before the bass does: %d", h["EMERGENCY"])
	}
	if d := h["EMERGENCY"] - h["OUT"]; d < 32 || d > 128 {
		t.Errorf("EMERGENCY - OUT = %d", d)
	}
}

func TestShortBreakdownMeansNoBridge(t *testing.T) {
	tr := testtrack.Synth(testtrack.Options{Breakdown: [2]int{257, 265}}) // only 8 beats without bass
	tr.Phrases = slices.DeleteFunc(tr.Phrases, func(p anlz.Phrase) bool { return p.Label == "Down" })
	h := rules.HotCues(tr, config.DefaultRules)
	if _, ok := h["BRIDGE"]; ok {
		t.Error("BRIDGE placed on an 8-beat breakdown")
	}
	if _, ok := h["DROP"]; !ok {
		t.Error("no DROP")
	}
}

func TestMemoryCues(t *testing.T) {
	tr := testtrack.Synth(testtrack.Options{})
	h := rules.HotCues(tr, config.DefaultRules)
	m := rules.MemoryCues(tr, h, config.DefaultRules)
	if m.Start != 1 {
		t.Errorf("START = %d", m.Start)
	}
	if !slices.Contains(m.Drops, h["DROP"]) {
		t.Errorf("DROPS %v miss the DROP hot cue %d", m.Drops, h["DROP"])
	}
	if m.BassSwap != 0 && m.BassSwap < h["IN"]+16 {
		t.Errorf("BASS SWAP %d too early", m.BassSwap)
	}
}

func TestPhraseOnlyFallback(t *testing.T) {
	tr := testtrack.Synth(testtrack.Options{})
	tr.FB = nil
	h := rules.HotCues(tr, config.DefaultRules)
	m := rules.MemoryCues(tr, h, config.DefaultRules)
	if h["IN"] != 65 || h["BRIDGE"] != 257 || !slices.Contains(m.Drops, h["DROP"]) {
		t.Fatalf("phrase-only: %v %v", h, m)
	}
}
