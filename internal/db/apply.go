// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package db

import (
	"database/sql"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/bitwise-media-group/auto-dj/internal/config"
	"github.com/bitwise-media-group/auto-dj/internal/num"
)

// Ours are the cue names this tool writes (replaced when it re-cues a track).
var Ours = map[string]bool{"IN": true, "BRIDGE": true, "DROP": true, "OUT": true, "EMERGENCY": true,
	"START": true, "BASS SWAP": true}

// PlanHot is a hot cue to write (plan.HotCue's fields).
type PlanHot struct {
	Kind  int
	Name  string
	MS    int
	Loop  int // EMERGENCY loop length in beats (0: config.EmergencyLoopBeats)
	OutMS int
}

// PlanMem is a memory cue to write.
type PlanMem struct {
	Name string
	MS   int
}

// PlanTrack is one track of a cue plan to write.
type PlanTrack struct {
	ID, Title string
	Hot       []PlanHot
	Mem       []PlanMem
}

type cueInfo struct {
	id      string
	kind    int
	comment string
	inMS    int
	active  bool // ActiveLoop 1
}

func trackCues(tx *sql.Tx, contentID, extra string) ([]cueInfo, error) {
	rows, err := tx.Query("select ID, Kind, Comment, InMsec, coalesce(ActiveLoop,0) from djmdCue where ContentID=? "+
		"and rb_local_deleted=0"+extra, contentID)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []cueInfo
	for rows.Next() {
		var id, comment sql.NullString
		var kind, in sql.NullInt64
		var al int
		if err := rows.Scan(&id, &kind, &comment, &in, &al); err != nil {
			return nil, err
		}
		out = append(out, cueInfo{id.String, int(kind.Int64), comment.String, int(in.Int64), al == 1})
	}
	return out, rows.Err()
}

func contentUUID(tx *sql.Tx, id string) (uuid any, rating int, found bool, err error) {
	var u sql.NullString
	err = tx.QueryRow("select UUID, coalesce(Rating,0) from djmdContent where ID=?", id).Scan(&u, &rating)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, 0, false, nil
	}
	if err != nil {
		return nil, 0, false, err
	}
	if u.Valid {
		uuid = u.String
	}
	return uuid, rating, true, nil
}

func ptr(v int) *int { return &v }

// ApplyPlan writes a cue plan (see the plan package) in tx.
//
// Target tracks: every hot cue must be replaceable (Energy N / CUE(Auto) / START hot cue)
// or the track is skipped. Generated cues are deleted; memory cues the user named are kept
// and never duplicated. Tracks this tool cued before (autoIDs, still unrated): only cues
// with our names are replaced, so any E/F/G notes the user added survive a re-run.
// EMERGENCY is written as an active loop unless a cue that stays already is one.
func ApplyPlan(tx *sql.Tx, plan []PlanTrack, autoIDs map[string]bool) (*Stats, error) {
	used, err := newIDSource(tx)
	if err != nil {
		return nil, err
	}
	w := &writer{tx: tx, used: used, ts: now(),
		stats: NewStats("updated", 0, "skipped", []string{}, "removed", 0, "added", 0)}
	for _, x := range plan {
		if err := w.planTrack(x, autoIDs); err != nil {
			return nil, err
		}
	}
	return w.stats, nil
}

// writer holds what one write's steps share.
type writer struct {
	tx    *sql.Tx
	used  idSource
	ts    string
	stats *Stats
}

func (w *writer) planTrack(x PlanTrack, autoIDs map[string]bool) error {
	cuuid, rating, found, err := contentUUID(w.tx, x.ID)
	if err != nil {
		return err
	}
	cur, err := trackCues(w.tx, x.ID, "")
	if err != nil {
		return err
	}
	rerun := found && autoIDs[x.ID] && rating == 0
	doomed, ok := planDoomed(x, cur, found, rerun)
	if !ok {
		w.stats.Append("skipped", x.Title)
		return nil
	}
	var kept []cueInfo  // memory cues the user named themselves stay
	activeLoop := false // a cue that stays is already the track's active loop
	for _, c := range cur {
		if !doomed[c.id] && c.kind == 0 {
			kept = append(kept, c)
		}
		activeLoop = activeLoop || (!doomed[c.id] && c.active)
		if doomed[c.id] {
			if _, err := w.tx.Exec("delete from djmdCue where ID=?", c.id); err != nil {
				return err
			}
		}
	}
	w.stats.Add("removed", len(doomed))
	ins := func(r cueRow) error {
		r.content, r.contentUUID = x.ID, cuuid
		if err := w.used.insert(w.tx, r, w.ts); err != nil {
			return err
		}
		w.stats.Add("added", 1)
		return nil
	}
	for _, c := range x.Hot {
		if err := ins(hotRow(c, !activeLoop)); err != nil {
			return err
		}
	}
	for _, c := range x.Mem {
		if slices.ContainsFunc(kept, func(k cueInfo) bool { return k.comment == c.Name && abs(k.inMS-c.MS) <= 500 }) {
			continue // the user already has this memory cue
		}
		r := cueRow{inMS: c.MS, outMS: -1, kind: config.Kind["MEM"], color: config.MemoryColor[c.Name], comment: c.Name}
		if err := ins(r); err != nil {
			return err
		}
	}
	w.stats.Add("updated", 1)
	return nil
}

// planDoomed lists the cues a plan replaces on a track; ok is false when the track must be
// skipped: gone, hand-edited since planning, or (on a re-run) with the user's own cue in one
// of our hot cue slots.
func planDoomed(x PlanTrack, cur []cueInfo, found, rerun bool) (doomed map[string]bool, ok bool) {
	foreign := slices.ContainsFunc(cur, func(c cueInfo) bool { return c.kind > 0 && !Replaceable(c.comment, c.kind) })
	if !found || (!rerun && foreign) {
		return nil, false
	}
	doomed = map[string]bool{}
	for _, c := range cur {
		if (rerun && Ours[c.comment]) || (!rerun && Replaceable(c.comment, c.kind)) {
			doomed[c.id] = true
		}
	}
	if rerun {
		ourKinds := map[int]bool{}
		for _, h := range x.Hot {
			ourKinds[h.Kind] = true
		}
		if slices.ContainsFunc(cur, func(c cueInfo) bool { return c.kind > 0 && !Ours[c.comment] && ourKinds[c.kind] }) {
			return nil, false
		}
	}
	return doomed, true
}

// hotRow is a planned hot cue's djmdCue row. EMERGENCY is a loop, active (ActiveLoop 1: it
// starts looping when playback reaches it) when active is set: BeatLoopSize packs the loop
// length in beats into bits 16+ (32 beats -> 2097153).
func hotRow(c PlanHot, active bool) cueRow {
	if c.Name != "EMERGENCY" {
		return cueRow{inMS: c.MS, outMS: -1, kind: c.Kind, color: config.HotColor, comment: c.Name}
	}
	loop := c.Loop
	if loop == 0 {
		loop = config.EmergencyLoopBeats
	}
	al := 0
	if active {
		al = 1
	}
	return cueRow{inMS: c.MS, outMS: c.OutMS, kind: c.Kind, color: 255, comment: "EMERGENCY",
		cti: ptr(0), al: ptr(al), bls: ptr(loop<<16 + 1), cms: ptr(0)}
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// SetSlot is an E or G hot cue `set` writes: status new | replace | clear | existing.
type SetSlot struct {
	Name   string
	Beat   int
	Status string
}

// SetMarker is a memory cue `set` writes (Status new | rename | existing) or removes.
type SetMarker struct {
	Name   string
	Beat   int
	Status string
}

// SetCues is what `set --write` changes on one track.
type SetCues struct {
	ID, Title string
	E, G      *SetSlot
	Markers   []SetMarker
	Remove    []SetMarker
}

// ApplySet writes E/G hot cues and the transition markers (BASS SWAP / FILTER / CUT ... IN /
// OUT memory cues) planned by setlist.PlanSet, renames the tracks' cues config.RenameTo
// lists, recolours the memory cues named in config.MemoryColor and deletes the stale ones in
// Remove. beats: track id -> beat-time array (s). E/G marked replace/clear are overwritten /
// removed (callers cache them first, see the pairs package); nothing else is touched.
func ApplySet(tx *sql.Tx, actions []SetCues, beats map[string][]float64) (*Stats, error) {
	used, err := newIDSource(tx)
	if err != nil {
		return nil, err
	}
	w := &writer{tx: tx, used: used, ts: now(), stats: NewStats("hot_cues", 0, "markers", 0, "removed", 0,
		"renamed", 0, "recoloured", 0, "skipped", []string{})}
	for _, a := range actions {
		if err := w.setTrack(a, beats[a.ID]); err != nil {
			return nil, err
		}
	}
	return w.stats, nil
}

// setTrack is one track of a set write. B is its beat grid (nil without Rekordbox analysis:
// recolour only, PlanSet placed nothing); mem its memory cues (names normalised).
type setTrack struct {
	*writer
	a     SetCues
	cuuid any
	B     []float64
	mem   []cueInfo
}

func (s *setTrack) ms(b int) int { return num.Round(s.B[min(max(b, 1), len(s.B))-1] * 1000) }

func (s *setTrack) ins(kind, m int, name string, color int) error {
	return s.used.insert(s.tx, cueRow{content: s.a.ID, contentUUID: s.cuuid, inMS: m, outMS: -1, kind: kind,
		color: color, comment: name}, s.ts)
}

func (w *writer) setTrack(a SetCues, B []float64) error {
	cuuid, _, found, err := contentUUID(w.tx, a.ID)
	if err != nil || !found {
		return err
	}
	if err := renameAndRecolour(w.tx, a.ID, w.ts, w.stats); err != nil {
		return err
	}
	s := &setTrack{writer: w, a: a, cuuid: cuuid, B: B}
	hot, err := trackCues(w.tx, a.ID, " and Kind>0")
	if err != nil {
		return err
	}
	if s.mem, err = trackCues(w.tx, a.ID, " and Kind=0"); err != nil { // after the renames above
		return err
	}
	for i := range s.mem {
		s.mem[i].comment = config.Norm(s.mem[i].comment)
	}
	if B != nil {
		if err := s.removeStale(); err != nil {
			return err
		}
	}
	taken := map[int]bool{}
	for _, c := range hot {
		taken[c.kind] = true
	}
	if err := s.slot("E", a.E, taken); err != nil {
		return err
	}
	if err := s.slot("G", a.G, taken); err != nil {
		return err
	}
	for _, m := range a.Markers {
		if m.Status == "existing" || B == nil {
			continue
		}
		base := m.Name
		if i := strings.LastIndex(m.Name, " "); i >= 0 {
			base = m.Name[:i]
		}
		added, err := s.putMarker(m.Name, m.Beat, base)
		if err != nil {
			return err
		}
		if added {
			w.stats.Add("markers", 1)
		}
	}
	return nil
}

// removeStale deletes the stale memory cues (CUT OUT, duplicate JUMP): the nearest one with
// the name within 500 ms of the beat.
func (s *setTrack) removeStale() error {
	for _, r := range s.a.Remove {
		at := s.ms(r.Beat)
		best := -1
		for i, c := range s.mem {
			if c.comment == r.Name && abs(c.inMS-at) <= 500 && (best < 0 || abs(c.inMS-at) < abs(s.mem[best].inMS-at)) {
				best = i
			}
		}
		if best < 0 {
			continue
		}
		if _, err := s.tx.Exec("delete from djmdCue where ID=?", s.mem[best].id); err != nil {
			return err
		}
		s.mem = slices.Delete(s.mem, best, best+1)
		s.stats.Add("removed", 1)
	}
	return nil
}

// slot writes the E or G hot cue.
func (s *setTrack) slot(name string, v *SetSlot, taken map[int]bool) error {
	kind := config.Kind[name]
	if v == nil || v.Status == "existing" {
		return nil
	}
	if v.Status == "new" && taken[kind] {
		s.stats.Append("skipped", fmt.Sprintf("%s: %s is no longer empty", s.a.Title, name))
		return nil
	}
	if v.Status == "replace" || v.Status == "clear" { // the old cue is already in the transition cache
		res, err := s.tx.Exec("delete from djmdCue where ContentID=? and Kind=? and rb_local_deleted=0", s.a.ID, kind)
		if err != nil {
			return err
		}
		n, _ := res.RowsAffected()
		s.stats.Add("removed", int(n))
	}
	if v.Status == "clear" || s.B == nil {
		return nil
	}
	if err := s.ins(kind, s.ms(v.Beat), v.Name, config.HotColor); err != nil {
		return err
	}
	s.stats.Add("hot_cues", 1)
	return nil
}

// putMarker places '<base> IN/OUT' at beat b: there already, else a plain '<base>' there
// renamed, else added (true when added).
func (s *setTrack) putMarker(name string, b int, base string) (bool, error) {
	at := s.ms(b)
	near := func(n string) int {
		return slices.IndexFunc(s.mem, func(c cueInfo) bool { return c.comment == n && abs(c.inMS-at) <= 500 })
	}
	if near(name) >= 0 {
		return false, nil
	}
	if i := near(base); i >= 0 {
		old := s.mem[i]
		var id any
		if old.id != "" {
			id = old.id
		}
		if _, err := s.tx.Exec("update djmdCue set Comment=?, Color=?, updated_at=? where ID=?",
			name, config.MemoryColor[name], s.ts, id); err != nil {
			return false, err
		}
		s.mem = append(slices.Delete(s.mem, i, i+1), cueInfo{id: old.id, comment: name, inMS: old.inMS})
		s.stats.Add("renamed", 1)
		return false, nil
	}
	if err := s.ins(config.Kind["MEM"], at, name, config.MemoryColor[name]); err != nil {
		return false, err
	}
	s.mem = append(s.mem, cueInfo{comment: name, inMS: at})
	return true, nil
}

// renameAndRecolour applies config.RenameTo to the track's cues and config.MemoryColor to
// its memory cues.
func renameAndRecolour(tx *sql.Tx, id, ts string, stats *Stats) error {
	rows, err := tx.Query("select ID, Comment, Color from djmdCue where ContentID=? and rb_local_deleted=0 and Kind=0", id)
	if err != nil {
		return err
	}
	type memRow struct {
		id, name string
		color    sql.NullInt64
	}
	var mem []memRow
	for rows.Next() {
		var r memRow
		var cid, name sql.NullString
		if err := rows.Scan(&cid, &name, &r.color); err != nil {
			_ = rows.Close()
			return err
		}
		r.id, r.name = cid.String, name.String
		mem = append(mem, r)
	}
	_ = rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, r := range mem {
		key := config.Norm(r.name)
		if to := config.RenameTo(key, false); to != "" {
			key = to
			if _, err := tx.Exec("update djmdCue set Comment=?, updated_at=? where ID=?", to, ts, r.id); err != nil {
				return err
			}
			stats.Add("renamed", 1)
		}
		if want, ok := config.MemoryColor[key]; ok && (!r.color.Valid || int(r.color.Int64) != want) {
			if _, err := tx.Exec("update djmdCue set Color=?, updated_at=? where ID=?", want, ts, r.id); err != nil {
				return err
			}
			stats.Add("recoloured", 1)
		}
	}
	hot, err := trackCues(tx, id, " and Kind>0")
	if err != nil {
		return err
	}
	for _, c := range hot {
		if to := config.RenameTo(c.comment, true); to != "" { // 'JUMP TO DROP' -> 'JUMP'
			if _, err := tx.Exec("update djmdCue set Comment=?, updated_at=? where ID=?", to, ts, c.id); err != nil {
				return err
			}
			stats.Add("renamed", 1)
		}
	}
	return nil
}

// ReorderPlaylist sets the playlist's track order (djmdSongPlaylist.TrackNo) to contentIDs.
func ReorderPlaylist(tx *sql.Tx, name string, contentIDs []string) (*Stats, error) {
	var pid sql.NullString
	err := tx.QueryRow("select ID from djmdPlaylist where rb_local_deleted=0 and Name=?", name).Scan(&pid)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	rows, err := tx.Query("select ID, ContentID from djmdSongPlaylist where PlaylistID=? and rb_local_deleted=0", pid)
	if err != nil {
		return nil, err
	}
	byContent := map[string]string{}
	for rows.Next() {
		var id, cid sql.NullString
		if err := rows.Scan(&id, &cid); err != nil {
			_ = rows.Close()
			return nil, err
		}
		byContent[cid.String] = id.String
	}
	_ = rows.Close()
	want := map[string]bool{}
	for _, c := range contentIDs {
		want[c] = true
	}
	same := len(want) == len(byContent)
	for c := range byContent {
		same = same && want[c]
	}
	if !same {
		return nil, errors.New("the playlist changed since the order was planned")
	}
	ts := now()
	for n, cid := range contentIDs {
		_, err := tx.Exec("update djmdSongPlaylist set TrackNo=?, updated_at=? where ID=?", n+1, ts, byContent[cid])
		if err != nil {
			return nil, err
		}
	}
	return NewStats("reordered", len(contentIDs)), nil
}
