// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/bitwise-media-group/adj/internal/config"
	"github.com/bitwise-media-group/adj/internal/db"
	"github.com/bitwise-media-group/adj/internal/evaluate"
	"github.com/bitwise-media-group/adj/internal/features"
	"github.com/bitwise-media-group/adj/internal/plan"
	"github.com/bitwise-media-group/adj/internal/review"
	"github.com/bitwise-media-group/adj/internal/tracks"
)

var allCategories = []string{"mik", "nohot", "manual", "auto", "other"}

func statusCmd(g *globals) *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "tracks per state; is Rekordbox running?",
		Args:  cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			p := g.paths()
			rb, err := db.ReadCopy(p.MasterDB())
			if err != nil {
				return err
			}
			tr, cues, err := db.LoadTracksAndCues(rb)
			_ = rb.Close()
			if err != nil {
				return err
			}
			auto, err := db.LoadLedger(p.Ledger())
			if err != nil {
				return err
			}
			var c counter
			for _, r := range tr {
				c.add(db.Classify(r.Rating, cues[r.ID], auto[r.ID]))
			}
			var parts []string
			for _, k := range c.mostCommon() {
				parts = append(parts, fmt.Sprintf("%s=%d", k, c.n[k]))
			}
			n := 0
			if m, err := filepath.Glob(filepath.Join(p.FeatureDir(), "*.f32.gz")); err == nil {
				n = len(m)
			}
			fmt.Printf("master.db: %s\n", p.MasterDB())
			fmt.Printf("tracks: %d  %s\n", len(tr), strings.Join(parts, "  "))
			fmt.Printf("Rekordbox running: %s\n", pyBool(db.RekordboxRunning()))
			fmt.Printf("feature cache: %s (%d files)\n", p.FeatureDir(), n)
			return nil
		},
	}
}

func featuresCmd(g *globals) *cobra.Command {
	cats := []string{"manual", "mik", "nohot", "auto", "other"}
	workers := 4
	cmd := &cobra.Command{
		Use:   "features",
		Short: "decode audio once (cached in the work dir)",
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := nargs(cmd, "categories", &cats, args); err != nil {
				return err
			}
			p := g.paths()
			rb, err := db.ReadCopy(p.MasterDB())
			if err != nil {
				return err
			}
			tr, cues, err := db.LoadTracksAndCues(rb)
			_ = rb.Close()
			if err != nil {
				return err
			}
			want := map[string]bool{}
			for _, c := range aliases(cats) {
				want[c] = true
			}
			auto, err := db.LoadLedger(p.Ledger())
			if err != nil {
				return err
			}
			var files []string
			for _, r := range tr {
				if r.FolderPath == "" {
					continue
				}
				fp := config.MapPath(r.FolderPath)
				if _, err := os.Stat(fp); err != nil {
					continue
				}
				if want[db.Classify(r.Rating, cues[r.ID], auto[r.ID])] {
					files = append(files, fp)
				}
			}
			res, err := features.ExtractMany(files, p.FeatureDir(), workers)
			if err != nil {
				return err
			}
			var n counter
			for _, r := range res {
				k, _, _ := strings.Cut(r.Status, ":")
				n.add(k)
				if strings.HasPrefix(r.Status, "error") {
					fmt.Fprintf(os.Stderr, "  %s: %s\n", filepath.Base(r.Path), r.Status)
				}
			}
			parts := make([]string, 0, len(n.keys))
			for _, k := range n.keys {
				parts = append(parts, fmt.Sprintf("%s %d", k, n.n[k]))
			}
			fmt.Printf("%d files: %s\n", len(files), strings.Join(parts, ", "))
			return nil
		},
	}
	cmd.Flags().StringSliceVar(&cats, "categories", cats, "track categories to decode")
	cmd.Flags().IntVar(&workers, "workers", workers, "parallel decodes")
	return cmd
}

func evaluateCmd(g *globals) *cobra.Command {
	verbose := false
	cmd := &cobra.Command{
		Use:   "evaluate",
		Short: "score the rules against your rated tracks",
		Args:  cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			ts, err := tracks.Build(g.paths(), "manual")
			if err != nil {
				return err
			}
			fmt.Println(evaluate.Format(evaluate.Score(ts, config.DefaultRules, verbose)))
			return nil
		},
	}
	cmd.Flags().BoolVarP(&verbose, "verbose", "v", false, "show each track's cues (yours / the rules')")
	return cmd
}

func planCmd(g *globals) *cobra.Command {
	cats := []string{"mik", "nohot"}
	out := ""
	cmd := &cobra.Command{
		Use:   "plan",
		Short: "plan cues for MIK / CUE(Auto) / no-hot-cue tracks",
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := nargs(cmd, "categories", &cats, args); err != nil {
				return err
			}
			p := g.paths()
			cs := aliases(cats)
			ts, err := tracks.Build(p, cs...)
			if err != nil {
				return err
			}
			pl := plan.Make(ts, cs, config.DefaultRules)
			dest := orDefault(out, filepath.Join(p.WorkDir, "plan.json"))
			if err := plan.Save(pl, dest); err != nil {
				return err
			}
			fmt.Println(plan.Summary(pl))
			fmt.Printf("plan written to %s\n", dest)
			return nil
		},
	}
	cmd.Flags().StringSliceVar(&cats, "categories", cats,
		"mik (Energy N / CUE(Auto) cues) | nohot (no hot cues) | auto (re-cue tracks this tool cued before)")
	cmd.Flags().StringVar(&out, "out", "", "plan file (default <work>/plan.json)")
	return cmd
}

func reviewCmd(g *globals) *cobra.Command {
	planPath, out := "", ""
	cmd := &cobra.Command{
		Use:   "review",
		Short: "render the HTML review page for the current plan",
		Args:  cobra.NoArgs,
		RunE: func(*cobra.Command, []string) error {
			p := g.paths()
			pl, err := plan.Load(orDefault(planPath, filepath.Join(p.WorkDir, "plan.json")))
			if err != nil {
				return err
			}
			ts, err := tracks.Build(p, allCategories...)
			if err != nil {
				return err
			}
			page, err := review.Render(ts, pl, orDefault(out, filepath.Join(p.WorkDir, "review.html")))
			if err != nil {
				return err
			}
			fmt.Printf("review page: %s\n", page)
			return nil
		},
	}
	cmd.Flags().StringVar(&planPath, "plan", "", "plan file (default <work>/plan.json)")
	cmd.Flags().StringVar(&out, "out", "", "page (default <work>/review.html)")
	return cmd
}
