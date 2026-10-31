// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package cli

import (
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/pairs"
	"github.com/bitwise-media-group/auto-dj/internal/preview"
	"github.com/bitwise-media-group/auto-dj/internal/setlist"
	"github.com/bitwise-media-group/auto-dj/internal/text"
)

type setPlan struct {
	Playlist string           `json:"playlist"`
	Order    []string         `json:"order"`
	Actions  []setlist.Action `json:"actions"`
}

func setCmd(g *globals) *cobra.Command {
	var order, previewDir, out string
	var bpm float64
	var freeStart, reorder, noPreview, noMix, write bool
	cmd := &cobra.Command{
		Use:   "set [playlist]",
		Short: "set-specific E/G cues + BASS SWAP for a playlist (omit it to list playlists)",
		Long: "Key check, suggested order, then set-specific E / G hot cues and BASS SWAP / FILTER / CUT / SYNC\n" +
			"transition markers for a playlist. Without a playlist, lists the playlists.",
		Args: cobra.MaximumNArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			p := g.paths()
			if len(args) == 0 {
				rb, err := db.ReadCopy(p.MasterDB())
				if err != nil {
					return err
				}
				defer func() { _ = rb.Close() }()
				names, err := db.ListPlaylists(rb)
				if err != nil {
					return err
				}
				fmt.Println("playlists:", strings.Join(names, ", "))
				return nil
			}
			playlist := args[0]
			res, err := setlist.Run(p, playlist, order, freeStart)
			if errors.Is(err, setlist.ErrOrder) {
				return errExit{err.Error()}
			}
			if err != nil {
				return err
			}
			fmt.Println(res.Report)
			ids := make([]string, len(res.Order))
			for i, x := range res.Order {
				ids[i] = x.ID
			}
			dest := orDefault(out, filepath.Join(p.WorkDir, "set-plan.json"))
			if err := db.WriteJSON(dest, setPlan{playlist, ids, res.Actions}); err != nil {
				return err
			}
			fmt.Printf("\nset plan written to %s\n", dest)
			if !noPreview {
				dir := filepath.Join(expandUser(orDefault(previewDir, p.WorkDir)), text.Slug(playlist))
				page, err := preview.Build(playlist, res.Order, res.Actions, res.Recs, dir, !noMix, bpm)
				if err != nil {
					return err
				}
				fmt.Printf("set-list page with transition previews: %s\n", page)
			}
			if !write {
				fmt.Println("Dry run. Re-run with --write (Rekordbox quit) to add the new cues.")
				return nil
			}
			beats := map[string][]float64{}
			for id, t := range res.Recs {
				beats[id] = t.Beats
			}
			stats, err := db.SafeWrite(p.MasterDB(), p.BackupDir(), func(tx *sql.Tx) (*db.Stats, error) {
				st, err := db.ApplySet(tx, setlist.ToDB(res.Actions), beats)
				if err != nil || !reorder {
					return st, err
				}
				ro, err := db.ReorderPlaylist(tx, playlist, ids)
				if err != nil {
					return nil, err
				}
				st.Update(ro)
				return st, nil
			})
			if err != nil {
				return err
			}
			setlist.RecordWritten(res.Cache, playlist, res.Order, res.Actions, res.Recs)
			if err := pairs.Save(res.Cache, p.Transitions()); err != nil {
				return err
			}
			stats.Set("transition_cache", p.Transitions())
			fmt.Println(stats)
			return nil
		},
	}
	f := cmd.Flags()
	f.StringVar(&order, "order", "", "'suggested' or a comma-separated track-number order, e.g. 1,3,2,4")
	f.BoolVar(&freeStart, "free-start", false, "let the suggested order change the first track")
	f.BoolVar(&reorder, "reorder", false, "with --write: also save the order to the playlist")
	f.StringVar(&previewDir, "preview-dir", "", "render transition previews, the full-set mix and a set-list page "+
		"into `DIR`/<set name> (default <work>)")
	f.BoolVar(&noPreview, "no-preview", false, "skip the previews")
	f.BoolVar(&noMix, "no-mix", false, "skip the full-set mix (set.mp3)")
	f.Float64Var(&bpm, "bpm", 128, "play the previews at this fixed tempo, key kept "+
		"(0: each track at its own tempo)")
	f.StringVar(&out, "out", "", "set plan file (default <work>/set-plan.json)")
	f.BoolVar(&write, "write", false, "write the cues (Rekordbox quit)")
	return cmd
}
