// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package version exposes build metadata stamped into the binary at link time.
// Keep these as vars (not consts) so -ldflags "-X ..." can rewrite them; an
// unbuilt or `go run` binary reports the defaults.
package version

var (
	// Version is the semver release tag, e.g. v1.2.3.
	Version = "dev"
	// Commit is the short git SHA the binary was built from.
	Commit = "none"
	// BuildDate is the RFC3339 UTC build timestamp.
	BuildDate = "unknown"
)

// String renders the stamped metadata as a single human-readable line.
func String() string {
	return Version + " (commit " + Commit + ", built " + BuildDate + ")"
}
