// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package cli

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"runtime"

	"github.com/spf13/cobra"

	"github.com/bitwise-media-group/auto-dj/internal/demo"
)

func demoCmd(g *globals) *cobra.Command {
	var tracksDir string
	var bpm float64
	noOpen := false
	cmd := &cobra.Command{
		Use:   "demo [DIR]",
		Short: "render the demo set, cue it, plan the set and open its preview",
		Long: "Renders ten original house tracks (24-bit AIFF, free to use) and runs the whole pipeline on them\n" +
			"without Rekordbox: features, cue plan, key check, suggested order, set cues and the set-list\n" +
			"preview, which it then opens. The generator supplies the beat grid and phrases Rekordbox would.\n" +
			"DIR defaults to <work>/demo; the tracks go in DIR/tracks unless --tracks says otherwise.",
		Args: cobra.MaximumNArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			dir := filepath.Join(g.paths().WorkDir, "demo")
			if len(args) == 1 {
				dir = expandUser(args[0])
			}
			td := orDefault(expandUser(tracksDir), filepath.Join(dir, "tracks"))
			fmt.Printf("rendering %d tracks into %s (about a minute)\n", len(demo.Tracks), td)
			res, err := demo.Walkthrough(td, dir, bpm)
			if err != nil {
				return err
			}
			fmt.Printf("\n$ auto-dj features\n%s\n\n$ auto-dj plan\n%s\n\n", res.Features, res.Plan)
			fmt.Printf("$ auto-dj set %q\n%s\n\n", demo.Playlist, res.SetCheck)
			fmt.Printf("$ auto-dj set %q --order suggested\n%s\n\n", demo.Playlist, res.SetSuggested)
			fmt.Printf("set-list page with transition previews: %s\n", res.Page)
			if !noOpen {
				openPage(res.Page)
			}
			return nil
		},
	}
	f := cmd.Flags()
	f.StringVar(&tracksDir, "tracks", "", "where to write the AIFF files (default DIR/tracks)")
	f.Float64Var(&bpm, "bpm", 128, "play the preview at this fixed tempo, key kept (0: each track at its own tempo)")
	f.BoolVar(&noOpen, "no-open", false, "don't open the preview page")
	return cmd
}

// openPage opens path in the default browser; failing that, the path printed above is enough.
func openPage(path string) {
	name := "xdg-open"
	if runtime.GOOS == "darwin" {
		name = "open"
	}
	_ = exec.Command(name, path).Start()
}
