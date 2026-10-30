// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package cli is the adj command line: status, features, evaluate, plan, review, apply, set.
package cli

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/spf13/cobra"

	"github.com/bitwise-media-group/adj/internal/config"
	"github.com/bitwise-media-group/adj/internal/db"
	"github.com/bitwise-media-group/adj/internal/version"
)

const long = `adj (auto dj) places hot cues and memory cues on Rekordbox tracks and prepares sets.

Typical run (Rekordbox may stay open until apply):
    adj status
    adj features            # decode audio once, cached
    adj evaluate            # how well the rules match your hand-cued tracks
    adj plan                # -> <work>/plan.json
    adj review              # -> <work>/review.html
    adj apply --write       # quit Rekordbox first; backs up master.db
    adj set "Melodic Dark"  # key check + set cues (E/G + BASS SWAP) for a playlist`

type globals struct {
	rbDir, workDir string
}

func (g *globals) paths() config.Paths {
	return config.Paths{RBDir: expandUser(g.rbDir), WorkDir: expandUser(g.workDir)}
}

func expandUser(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		if h, err := os.UserHomeDir(); err == nil {
			return filepath.Join(h, p[1:])
		}
	}
	return p
}

// NewRoot builds the adj command tree.
func NewRoot() *cobra.Command {
	g := &globals{}
	root := &cobra.Command{
		Use:           "adj",
		Short:         "Place hot cues and memory cues on Rekordbox tracks and prepare sets",
		Long:          long,
		Version:       version.String(),
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.PersistentFlags().StringVar(&g.rbDir, "rb-dir", config.DefaultRBDir(), "folder holding master.db and share/")
	root.PersistentFlags().StringVar(&g.workDir, "work-dir", config.DefaultWorkDir(), "cache + plan output folder")
	root.AddCommand(statusCmd(g), featuresCmd(g), evaluateCmd(g), planCmd(g), reviewCmd(g), applyCmd(g), setCmd(g))
	return root
}

// nargs lets a list flag take space-separated values like argparse's nargs="+"
// (--categories mik nohot): positional arguments after it join the flag's values.
func nargs(cmd *cobra.Command, flag string, vals *[]string, args []string) error {
	if len(args) == 0 {
		return nil
	}
	if !cmd.Flags().Changed(flag) {
		return fmt.Errorf("unexpected argument %q", args[0])
	}
	*vals = append(*vals, args...)
	return nil
}

func aliases(cats []string) []string {
	out := make([]string, 0, len(cats))
	for _, c := range cats {
		out = append(out, db.Alias(c))
	}
	return out
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

// pyBool prints a bool like Python (the status output is unchanged from the Python tool).
func pyBool(b bool) string {
	if b {
		return "True"
	}
	return "False"
}

// counter counts strings and lists them most common first, ties in first-seen order
// (Python's Counter.most_common).
type counter struct {
	keys []string
	n    map[string]int
}

func (c *counter) add(k string) {
	if c.n == nil {
		c.n = map[string]int{}
	}
	if _, ok := c.n[k]; !ok {
		c.keys = append(c.keys, k)
	}
	c.n[k]++
}

func (c *counter) mostCommon() []string {
	out := slices.Clone(c.keys)
	slices.SortStableFunc(out, func(a, b string) int { return c.n[b] - c.n[a] })
	return out
}

// errExit is an error whose message is printed as is (no "adj:" prefix), like sys.exit(msg).
type errExit struct{ msg string }

func (e errExit) Error() string { return e.msg }

// Main runs adj and returns the process exit code.
func Main() int {
	err := NewRoot().Execute()
	if err == nil {
		return 0
	}
	var ex errExit
	if errors.As(err, &ex) {
		fmt.Fprintln(os.Stderr, ex.msg)
	} else {
		fmt.Fprintln(os.Stderr, "adj:", err)
	}
	return 1
}
