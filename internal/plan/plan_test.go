// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package plan

import (
	"testing"

	"github.com/bitwise-media-group/auto-dj/internal/config"
	"github.com/bitwise-media-group/auto-dj/internal/testtrack"
)

func TestPlanEncoding(t *testing.T) {
	x := Track(testtrack.Synth(testtrack.Options{}), config.DefaultRules)
	var em *HotCue
	for i, c := range x.Hot {
		if c.Name == "EMERGENCY" {
			em = &x.Hot[i]
		}
		if c.Slot == "E" || c.Slot == "F" || c.Slot == "G" {
			t.Errorf("plan writes slot %s", c.Slot) // never E/F/G
		}
	}
	if em == nil || em.Kind != config.Kind["H"] || em.Kind != 9 {
		t.Fatalf("EMERGENCY = %+v", em)
	}
	if *em.OutMS <= em.MS || *em.Loop != 32 {
		t.Errorf("EMERGENCY loop = %d..%d (%d beats)", em.MS, *em.OutMS, *em.Loop)
	}
	if 32<<16+1 != 2097153 { // BeatLoopSize for 32 beats
		t.Error("BeatLoopSize encoding")
	}
}
