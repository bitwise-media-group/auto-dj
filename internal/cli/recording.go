// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package cli

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/bitwise-media-group/auto-dj/internal/config"
	"github.com/bitwise-media-group/auto-dj/internal/db"
	"github.com/bitwise-media-group/auto-dj/internal/features"
	"github.com/bitwise-media-group/auto-dj/internal/mixalign"
	"github.com/bitwise-media-group/auto-dj/internal/mixexport"
	"github.com/bitwise-media-group/auto-dj/internal/num"
	"github.com/bitwise-media-group/auto-dj/internal/pairs"
	"github.com/bitwise-media-group/auto-dj/internal/text"
	"github.com/bitwise-media-group/auto-dj/internal/tracks"
)

func historyCmd(g *globals) *cobra.Command {
	return &cobra.Command{
		Use:   "history [name]",
		Short: "list the play histories, or one history's tracks (omit it to list them)",
		Long: "Lists the play histories Rekordbox imported from the CDJs' USB, oldest first, or one history's\n" +
			"tracks in play order with the time Rekordbox wrote each row (the import, not the play: the\n" +
			"recording command times the tracks from the audio).",
		Args: cobra.MaximumNArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			rb, err := db.ReadCopy(g.paths().MasterDB())
			if err != nil {
				return err
			}
			defer func() { _ = rb.Close() }()
			if len(args) == 0 {
				hs, err := db.ListHistories(rb)
				if err != nil {
					return err
				}
				for _, h := range hs {
					fmt.Printf("%-28s %s  %3d tracks\n", h.Name, h.Created, h.Tracks)
				}
				return nil
			}
			h, rows, err := db.LoadHistory(rb, args[0])
			if errors.Is(err, db.ErrNoHistory) {
				return errExit{err.Error()}
			}
			if err != nil {
				return err
			}
			fmt.Printf("%s (created %s): %d tracks\n", h.Name, h.Created, len(rows))
			for _, r := range rows {
				fmt.Printf("  %2d. %s  %s  %s\n", r.No, r.Created, text.PadLeft(orQ(r.Key), 4), r.Title)
			}
			return nil
		},
	}
}

func orQ(s string) string {
	if s == "" {
		return "?"
	}
	return s
}

type recordingOpts struct {
	dj, art, album, date, out, playlist, folder, encoder string
	realign, write, noExport, noTrim                     bool
}

func recordingCmd(g *globals) *cobra.Command {
	var o recordingOpts
	cmd := &cobra.Command{
		Use:   "recording <history> <mix.wav>",
		Short: "split a set recording into tagged AAC tracks by its play history",
		Long: "Lines the history's tracks up against the recording by their sound (the history gives the order,\n" +
			"the audio the timing), cuts where each incoming track takes the bass over (snapped to its phrase\n" +
			"start) and writes, into --out: alignment.json (review and edit it, then re-run), one .m4a per track\n" +
			"(the track's tags, the set as album, the DJ as album artist, --art as cover), a cue sheet and a\n" +
			"tracklist. With --write (Rekordbox quit) it also saves the transitions played to the transition\n" +
			"cache and creates a playlist from the tracks, for `auto-dj set`.",
		Args: cobra.ExactArgs(2),
		RunE: func(_ *cobra.Command, args []string) error {
			return runRecording(g, args[0], expandUser(args[1]), o)
		},
	}
	f := cmd.Flags()
	f.StringVar(&o.dj, "dj", "", "the DJ: album artist of every file (required to export)")
	f.StringVar(&o.art, "art", "", "the set's cover, jpg or png (required to export)")
	f.StringVar(&o.album, "album", "", "album name (default: the history's name)")
	f.StringVar(&o.date, "date", "", "release date, YYYY-MM-DD (default: the history's date)")
	f.StringVar(&o.out, "out", "", "output folder (default <work>/recordings/<history>)")
	f.BoolVar(&o.realign, "realign", false, "align again instead of reusing alignment.json (hand-edited cuts are kept)")
	f.BoolVar(&o.noExport, "no-export", false, "only align and report (no audio files)")
	f.BoolVar(&o.noTrim, "no-trim", false, "keep the silence before the first track and after the last one")
	f.StringVar(&o.encoder, "encoder", mixexport.Auto, "AAC encoder: auto (Apple's through afconvert, else ffmpeg), "+
		"afconvert, or ffmpeg (Apple's through AudioToolbox when it works, else ffmpeg's own)")
	f.BoolVar(&o.write, "write", false, "also save the transitions to the cache and create the playlist (Rekordbox quit)")
	f.StringVar(&o.playlist, "playlist", "", "with --write: the playlist's name (default: the history's name)")
	f.StringVar(&o.folder, "folder", "", "with --write: put the playlist in this playlist folder")
	return cmd
}

func runRecording(g *globals, history, wav string, o recordingOpts) error {
	if !o.noExport && (o.dj == "" || o.art == "") {
		return errExit{"--dj and --art are required to export (or pass --no-export)"}
	}
	p := g.paths()
	wav, err := filepath.Abs(wav)
	if err != nil {
		return err
	}
	rb, err := db.ReadCopy(p.MasterDB())
	if err != nil {
		return err
	}
	h, rows, err := db.LoadHistory(rb, history)
	var tags map[string]db.Tags
	if err == nil {
		ids := make([]string, len(rows))
		for i, r := range rows {
			ids[i] = r.ID
		}
		tags, err = db.LoadTags(rb, ids)
	}
	_ = rb.Close()
	if errors.Is(err, db.ErrNoHistory) {
		return errExit{err.Error()}
	}
	if err != nil {
		return err
	}
	out := orDefault(expandUser(o.out), filepath.Join(p.WorkDir, "recordings", text.Slug(h.Name)))
	alignPath := filepath.Join(out, "alignment.json")
	recs, err := tracks.Build(p, allCategories...)
	if err != nil {
		return err
	}
	byID := map[string]*tracks.Track{}
	for _, t := range recs {
		byID[t.ID] = t
	}
	f, err := alignment(p, alignPath, h, rows, tags, byID, wav, o.realign)
	if err != nil {
		return err
	}
	fmt.Print(report(f))
	fmt.Printf("\nalignment: %s\n", alignPath)
	ts, err := exportRecording(f, tags, h, wav, out, o)
	if err != nil {
		return err
	}
	if !o.write {
		fmt.Println("Review alignment.json, then re-run with --write (Rekordbox quit) to save the transitions " +
			"and create the playlist.")
		return nil
	}
	return writeRecording(p, h, ts, byID, orDefault(o.playlist, h.Name), o.folder)
}

// exportRecording plans the files (trimming the silence unless --no-trim) and, unless
// --no-export, encodes them and writes the cue sheet and tracklist.
func exportRecording(f *mixalign.File, tags map[string]db.Tags, h db.History, wav, out string,
	o recordingOpts) ([]mixexport.Track, error) {
	opt := mixexport.Options{Recording: wav, OutDir: out, Album: orDefault(o.album, h.Name), DJ: o.dj,
		Date: orDefault(o.date, h.Date()), Art: expandUser(o.art), Encoder: o.encoder}
	ts, err := mixexport.Plan(f, tags, out)
	if err != nil {
		return nil, errExit{"alignment.json: " + err.Error()}
	}
	if o.noExport {
		return ts, nil
	}
	if !o.noTrim {
		if err := mixexport.TrimSilence(f, ts, wav); err != nil {
			return nil, err
		}
	}
	if _, err := os.Stat(opt.Art); err != nil {
		return nil, errExit{"--art: " + err.Error()}
	}
	enc, err := mixexport.Resolve(o.encoder)
	if err != nil {
		return nil, errExit{"--encoder: " + err.Error()}
	}
	fmt.Printf("encoding %d tracks (%s, 256 kb/s) into %s\n", len(ts), enc, out)
	if err := mixexport.Export(f, ts, opt); err != nil {
		return nil, err
	}
	sheets, err := mixexport.WriteSheets(f, ts, opt)
	if err != nil {
		return nil, err
	}
	fmt.Printf("cue sheet and tracklist: %s\n", strings.Join(sheets, ", "))
	return ts, nil
}

// alignment reuses alignment.json, or aligns the history against the recording and writes it.
func alignment(p config.Paths, path string, h db.History, rows []db.HistoryTrack, tags map[string]db.Tags,
	recs map[string]*tracks.Track, wav string, realign bool) (*mixalign.File, error) {
	old, err := mixalign.Load(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if old != nil && !realign {
		if old.Recording != wav {
			return nil, errExit{fmt.Sprintf("%s aligns %s, not %s: pass --realign or another --out", path,
				old.Recording, wav)}
		}
		fmt.Printf("reusing %s (--realign to align again)\n", path)
		return old, nil
	}
	audio, err := mixexport.ProbeAudio(wav)
	if err != nil {
		return nil, err
	}
	fmt.Printf("decoding the recording (%s)\n", mixalign.FormatTime(float64(audio.Samples)/float64(audio.SampleRate)))
	recF, err := features.RecordingFrames(p.FeatureDir(), wav)
	if err != nil {
		return nil, err
	}
	in := make([]mixalign.Input, len(rows))
	var paths []string
	for i, r := range rows {
		in[i] = mixalign.Input{No: r.No, ID: r.ID, Title: r.Title, Rec: recs[r.ID]}
		if fp := config.MapPath(tags[r.ID].FolderPath); fp != "" {
			if _, err := os.Stat(fp); err == nil {
				paths = append(paths, fp)
			}
		}
	}
	fmt.Printf("decoding %d tracks (cached in %s)\n", len(paths), p.FeatureDir())
	if _, err := features.ExtractMany(paths, p.FeatureDir(), 4); err != nil {
		return nil, err
	}
	for i, r := range rows {
		fp := config.MapPath(tags[r.ID].FolderPath)
		if fp == "" {
			continue
		}
		if _, err := os.Stat(fp); err != nil {
			continue
		}
		F, err := features.Frames(p.FeatureDir(), fp)
		if err != nil {
			fmt.Fprintf(os.Stderr, "  %s: %v\n", r.Title, err)
			continue
		}
		in[i].F = F
	}
	fmt.Printf("aligning %d tracks\n", len(in))
	f := &mixalign.File{History: h.Name, Date: h.Date(), Recording: wav, SampleRate: audio.SampleRate,
		Channels: audio.Channels, Samples: audio.Samples,
		Duration: mixalign.FormatTime(float64(audio.Samples) / float64(audio.SampleRate)),
		Tracks:   mixalign.Align(recF, in, audio.SampleRate, audio.Samples)}
	if old != nil {
		if n := mixalign.KeepEdits(old, f); n > 0 {
			fmt.Printf("kept %d hand-edited cut(s) from the earlier alignment\n", n)
		}
	}
	return f, mixalign.Save(path, f)
}

// report is the per-track table: cut, status, confidence, title, notes.
func report(f *mixalign.File) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s: %d tracks, recording %s\n\n", f.History, len(f.Tracks), f.Duration)
	fmt.Fprintf(&b, "  %3s  %-12s  %-14s  %5s  %s\n", "no", "cut", "status", "conf", "title")
	for _, e := range f.Tracks {
		cut := e.Cut
		if cut == "" {
			cut = "-"
		} else if e.Edited(f.SampleRate) {
			cut += "*"
		}
		fmt.Fprintf(&b, "  %3d  %-12s  %-14s  %5.2f  %s\n", e.No, cut, e.Status, e.Confidence, e.Title)
		for _, n := range e.Notes {
			fmt.Fprintf(&b, "  %3s  %-12s  ! %s\n", "", "", n)
		}
	}
	b.WriteString("\n(* = cut edited by hand)\n")
	return b.String()
}

// writeRecording saves the transitions played to the transition cache and creates the
// playlist (master.db through SafeWrite, with masterPlaylists6.xml).
func writeRecording(p config.Paths, h db.History, ts []mixexport.Track, recs map[string]*tracks.Track,
	playlist, folder string) error {
	ids := make([]string, len(ts))
	for i, t := range ts {
		ids[i] = t.ID
	}
	stats, err := db.WritePlaylist(p.MasterDB(), p.BackupDir(), playlist, folder, ids)
	if errors.Is(err, db.ErrPlaylistExists) {
		return errExit{err.Error() + ": pass --playlist with another name"}
	}
	if err != nil {
		return err
	}
	cache, err := pairs.Load(p.Transitions())
	if err != nil {
		return err
	}
	n := 0
	for i := 1; i < len(ts); i++ {
		a, b := ts[i-1], ts[i]
		tr := b.Transition
		ra, rb := recs[a.ID], recs[b.ID]
		if tr == nil || tr.FromID != a.ID || a.Status != mixalign.OK || b.Status != mixalign.OK || ra == nil || rb == nil {
			continue
		}
		ms := func(t *tracks.Track, beat int) *int {
			v := num.Round(t.Beats[min(max(beat, 1), len(t.Beats))-1] * 1000)
			return &v
		}
		cache.Record(a.ID, a.Tags.Title, b.ID, b.Tags.Title, "recording:"+h.Name,
			pairs.Vals{GMS: ms(ra, tr.G), EMS: ms(rb, tr.E), BassSwapMS: ms(rb, tr.BassSwap)})
		n++
	}
	if err := pairs.Save(cache, p.Transitions()); err != nil {
		return err
	}
	stats.Set("transitions_recorded", n)
	stats.Set("transition_cache", p.Transitions())
	fmt.Println(stats)
	return nil
}
