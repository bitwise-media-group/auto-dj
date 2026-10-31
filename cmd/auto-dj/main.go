// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Command auto-dj places hot cues and memory cues on Rekordbox tracks and prepares
// sets: transition cues, key checks and audio previews.
package main

import (
	"os"

	"github.com/bitwise-media-group/auto-dj/internal/cli"
)

func main() {
	os.Exit(cli.Main())
}
