// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package cli

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"slices"
	"strings"

	"github.com/spf13/cobra"

	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/plan"
)

func applyCmd(g *globals) *cobra.Command {
	planPath := ""
	var only []string
	write := false
	cmd := &cobra.Command{
		Use:   "apply",
		Short: "apply the plan: dry run, or --write with Rekordbox quit",
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := nargs(cmd, "only", &only, args); err != nil {
				return err
			}
			p := g.paths()
			pl, err := plan.Load(orDefault(planPath, filepath.Join(p.WorkDir, "plan.json")))
			if err != nil {
				return err
			}
			if len(only) > 0 {
				pl = slices.DeleteFunc(pl, func(x plan.Item) bool {
					return !slices.ContainsFunc(only, func(s string) bool {
						return strings.Contains(strings.ToLower(x.Title), strings.ToLower(s))
					})
				})
			}
			fmt.Printf("%d tracks in plan\n", len(pl))
			auto, err := db.LoadLedger(p.Ledger())
			if err != nil {
				return err
			}
			fn := func(tx *sql.Tx) (*db.Stats, error) { return db.ApplyPlan(tx, plan.ToDB(pl), auto) }
			if !write {
				stats, err := db.DryRun(p.MasterDB(), fn)
				if err != nil {
					return err
				}
				fmt.Println("DRY RUN (nothing written):", stats)
				fmt.Println("Re-run with --write once Rekordbox is quit.")
				return nil
			}
			stats, err := db.SafeWrite(p.MasterDB(), p.BackupDir(), fn)
			if err != nil {
				return err
			}
			skipped, _ := stats.Get("skipped").([]string)
			var ids []string
			for _, x := range pl {
				if !slices.Contains(skipped, x.Title) {
					ids = append(ids, x.ID)
				}
			}
			if err := db.AddToLedger(p.Ledger(), ids); err != nil {
				return err
			}
			fmt.Println(stats)
			return nil
		},
	}
	cmd.Flags().StringVar(&planPath, "plan", "", "plan file (default <work>/plan.json)")
	cmd.Flags().StringArrayVar(&only, "only", nil, "limit to titles containing any of these strings")
	cmd.Flags().BoolVar(&write, "write", false, "actually write (default is a dry run)")
	return cmd
}
