// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

//go:build race

package mixalign

// raceDetector is set under the race detector, which makes rendering the test mix far too slow.
const raceDetector = true
