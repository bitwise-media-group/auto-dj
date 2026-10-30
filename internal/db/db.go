// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package db reads and writes Rekordbox's master.db.
//
// Safety model:
//   - Reads always happen on a decrypted temporary copy of master.db, never the live file.
//   - Writes happen on a decrypted copy too; the original is backed up and only replaced once
//     the re-encrypted copy has been decrypted again and integrity-checked (SafeWrite).
//   - Writing is refused while Rekordbox is running (it keeps master.db open and would
//     overwrite our changes on quit) or while a -wal/-shm sidecar exists.
package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"

	_ "modernc.org/sqlite" // registers the "sqlite" driver

	"github.com/bitwise-media-group/adj/internal/config"
	"github.com/bitwise-media-group/adj/internal/sqlcipher"
)

// DB is a decrypted working copy of master.db.
type DB struct {
	*sql.DB
	dir string
}

// Close closes the database and removes the working copy.
func (d *DB) Close() error {
	err := d.DB.Close()
	if d.dir != "" {
		_ = os.RemoveAll(d.dir)
	}
	return err
}

func openPlain(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1) // one connection: every statement sees the same transaction state
	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return db, nil
}

// decryptTo decrypts master into dir/master.db.
func decryptTo(master, dir string) (string, error) {
	key, err := sqlcipher.RekordboxKey()
	if err != nil {
		return "", err
	}
	plain := filepath.Join(dir, "master.db")
	if err := sqlcipher.Decrypt(master, plain, key); err != nil {
		return "", fmt.Errorf("decrypting %s: %w", master, err)
	}
	return plain, nil
}

// ReadCopy opens a decrypted throwaway copy of masterDB. Close removes it.
func ReadCopy(masterDB string) (*DB, error) {
	dir, err := os.MkdirTemp("", "adj-read-")
	if err != nil {
		return nil, err
	}
	plain, err := decryptTo(masterDB, dir)
	if err != nil {
		_ = os.RemoveAll(dir)
		return nil, err
	}
	db, err := openPlain(plain)
	if err != nil {
		_ = os.RemoveAll(dir)
		return nil, err
	}
	return &DB{DB: db, dir: dir}, nil
}

// Querier is what the queries need: a *sql.DB, *sql.Tx or *DB.
type Querier interface {
	Query(query string, args ...any) (*sql.Rows, error)
	QueryRow(query string, args ...any) *sql.Row
	Exec(query string, args ...any) (sql.Result, error)
}

// ------------------------------------------------------------------ safety checks

// RekordboxRunning reports whether Rekordbox is running. pgrep exits 0 when found and 1 when
// not; anything else means it couldn't list processes (e.g. inside a sandbox), so assume it
// is running rather than allow a write. Off macOS it can't tell (e.g. a VM) and says no.
func RekordboxRunning() bool {
	if runtime.GOOS != "darwin" {
		return false
	}
	err := exec.Command("pgrep", "-if", "rekordbox.app/Contents/MacOS").Run()
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode() != 1
	}
	return true // found (nil) or pgrep couldn't run
}

// AssertSafeToWrite refuses while Rekordbox runs or master.db has a -wal / -shm sidecar.
func AssertSafeToWrite(masterDB string) error {
	if RekordboxRunning() {
		return errors.New("rekordbox is running. Quit it fully before writing cues")
	}
	for _, side := range []string{"master.db-wal", "master.db-shm"} {
		if _, err := os.Stat(filepath.Join(filepath.Dir(masterDB), side)); err == nil {
			return fmt.Errorf("%s exists, so Rekordbox may still have the database open", side)
		}
	}
	return nil
}

// ------------------------------------------------------------------ track selection

// Cue is one djmdCue row.
type Cue struct {
	Kind int     // 0 memory cue, 1.. hot cue slots (see config.Kind)
	T    float64 // InMsec / 1000
	Out  float64 // OutMsec / 1000, 0 when the cue has no end
	Name string  // Comment ("" when NULL)
	AL   sql.NullInt64
	BL   sql.NullInt64
}

// TrackRow is one djmdContent row.
type TrackRow struct {
	ID               string
	Title            string
	Rating           int
	FolderPath       string
	BPM              float64 // BPM / 100
	Length           float64 // seconds, 0 when unknown
	AnalysisDataPath string
	UUID             string
}

// LoadTracksAndCues returns every track and its cues (by content ID, in InMsec order).
func LoadTracksAndCues(q Querier) ([]TrackRow, map[string][]Cue, error) {
	rows, err := q.Query(`select ID, Title, coalesce(Rating,0), FolderPath, BPM, Length,
                      AnalysisDataPath, UUID from djmdContent where rb_local_deleted=0`)
	if err != nil {
		return nil, nil, err
	}
	var tracks []TrackRow
	for rows.Next() {
		var id, title, fp, ap, uid sql.NullString
		var rating int
		var bpm, length sql.NullFloat64
		if err := rows.Scan(&id, &title, &rating, &fp, &bpm, &length, &ap, &uid); err != nil {
			_ = rows.Close()
			return nil, nil, err
		}
		tracks = append(tracks, TrackRow{
			ID: id.String, Title: title.String, Rating: rating, FolderPath: fp.String,
			BPM: bpm.Float64 / 100, Length: length.Float64, AnalysisDataPath: ap.String, UUID: uid.String,
		})
	}
	_ = rows.Close()
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	rows, err = q.Query(`select ContentID, Kind, InMsec, OutMsec, Comment, ActiveLoop, BeatLoopSize
                    from djmdCue where rb_local_deleted=0 order by InMsec`)
	if err != nil {
		return nil, nil, err
	}
	defer func() { _ = rows.Close() }()
	by := map[string][]Cue{}
	for rows.Next() {
		var cid, comment sql.NullString
		var kind, in, out sql.NullInt64
		var c Cue
		if err := rows.Scan(&cid, &kind, &in, &out, &comment, &c.AL, &c.BL); err != nil {
			return nil, nil, err
		}
		c.Kind, c.T, c.Name = int(kind.Int64), float64(in.Int64)/1000, comment.String
		if out.Valid && out.Int64 > 0 {
			c.Out = float64(out.Int64) / 1000
		}
		by[cid.String] = append(by[cid.String], c)
	}
	return tracks, by, rows.Err()
}

// IsAutoCue reports cues generated by software that we replace: Mixed In Key 'Energy N',
// Rekordbox 'CUE(Auto)'.
func IsAutoCue(name string) bool {
	n := config.Norm(name)
	return strings.HasPrefix(n, "ENERGY") || n == "CUE(AUTO)"
}

// Replaceable reports cues we are allowed to delete on a target track.
func Replaceable(name string, kind int) bool {
	return IsAutoCue(name) || (name == "START" && kind == 1)
}

// CategoryAliases maps old category names to current ones.
var CategoryAliases = map[string]string{"uncued": "nohot"}

// Alias resolves a category alias.
func Alias(c string) string {
	if a, ok := CategoryAliases[c]; ok {
		return a
	}
	return c
}

// Classify sorts a track:
//
//	manual - rated, or has the user's own IN/DROP/OUT hot cues (training data)
//	auto   - unrated and cued by this tool (listed in the ledger); not training data
//	mik    - only generated cues (Mixed In Key 'Energy N', Rekordbox 'CUE(Auto)'),
//	         plus an optional START hot cue
//	nohot  - no hot cues at all (no cues, or memory cues only); any memory cues the
//	         user named themselves are kept when the track is cued
//	other  - anything else (left alone)
//
// Rating an 'auto' track (after checking/fixing it) promotes it to 'manual'.
func Classify(rating int, cues []Cue, auto bool) string {
	if rating > 0 {
		return "manual"
	}
	if auto {
		return "auto"
	}
	hot := map[string]bool{}
	anyHot, anyAutoHot, allReplaceable := false, false, true
	for _, c := range cues {
		if c.Kind > 0 {
			hot[c.Name] = true
			anyHot = true
			if IsAutoCue(c.Name) {
				anyAutoHot = true
			}
		}
		if !Replaceable(c.Name, c.Kind) {
			allReplaceable = false
		}
	}
	if hot["IN"] && hot["DROP"] && hot["OUT"] {
		return "manual"
	}
	if anyAutoHot && allReplaceable {
		return "mik"
	}
	if !anyHot {
		return "nohot"
	}
	return "other"
}

// ------------------------------------------------------------------ ledger

type ledger struct {
	TrackIDs []string `json:"track_ids"`
}

// LoadLedger returns the IDs of tracks this tool has cued (so they are not mistaken for
// hand-cued tracks).
func LoadLedger(path string) (map[string]bool, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]bool{}, nil
	}
	if err != nil {
		return nil, err
	}
	var l ledger
	if err := json.Unmarshal(raw, &l); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	ids := make(map[string]bool, len(l.TrackIDs))
	for _, id := range l.TrackIDs {
		ids[id] = true
	}
	return ids, nil
}

// AddToLedger records ids as cued by this tool.
func AddToLedger(path string, ids []string) error {
	have, err := LoadLedger(path)
	if err != nil {
		return err
	}
	for _, id := range ids {
		have[id] = true
	}
	all := make([]string, 0, len(have))
	for id := range have {
		all = append(all, id)
	}
	slices.Sort(all)
	return WriteJSON(path, ledger{TrackIDs: all})
}

// WriteJSON writes v as indented JSON (one space, like the Python version's indent=1),
// creating the parent folder.
func WriteJSON(path string, v any) error {
	b, err := MarshalJSON(v)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}

// MarshalJSON is json.MarshalIndent with a one-space indent and no HTML escaping.
func MarshalJSON(v any) ([]byte, error) {
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", " ")
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return []byte(strings.TrimSuffix(b.String(), "\n")), nil
}

// ------------------------------------------------------------------ playlists

// ListPlaylists returns playlist names (folders and smart playlists excluded).
func ListPlaylists(q Querier) ([]string, error) {
	rows, err := q.Query("select Name from djmdPlaylist where rb_local_deleted=0 " +
		"and coalesce(Attribute,0) not in (1, 4) order by Seq")
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []string
	for rows.Next() {
		var n sql.NullString
		if err := rows.Scan(&n); err != nil {
			return nil, err
		}
		out = append(out, n.String)
	}
	return out, rows.Err()
}

// PlaylistTrack is one track of a playlist.
type PlaylistTrack struct {
	No    int     `json:"no"`
	ID    string  `json:"id"`
	Title string  `json:"title"`
	BPM   float64 `json:"bpm"`
	Key   string  `json:"key"` // "" when unknown
}

// ErrNoPlaylist means no playlist has the requested name.
var ErrNoPlaylist = errors.New("no such playlist")

// LoadPlaylist returns the playlist's tracks in TrackNo order.
func LoadPlaylist(q Querier, name string) ([]PlaylistTrack, error) {
	var pid string
	err := q.QueryRow("select ID from djmdPlaylist where rb_local_deleted=0 and Name=?", name).Scan(&pid)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("%w: no playlist called '%s'", ErrNoPlaylist, name)
	}
	if err != nil {
		return nil, err
	}
	rows, err := q.Query(`select sp.TrackNo, c.ID, c.Title, c.BPM, k.ScaleName
                from djmdSongPlaylist sp join djmdContent c on c.ID = sp.ContentID
                left join djmdKey k on k.ID = c.KeyID
                where sp.PlaylistID=? and sp.rb_local_deleted=0 order by sp.TrackNo`, pid)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []PlaylistTrack
	for rows.Next() {
		var no sql.NullInt64
		var id, title, key sql.NullString
		var bpm sql.NullFloat64
		if err := rows.Scan(&no, &id, &title, &bpm, &key); err != nil {
			return nil, err
		}
		out = append(out, PlaylistTrack{No: int(no.Int64), ID: id.String, Title: title.String,
			BPM: bpm.Float64 / 100, Key: key.String})
	}
	return out, rows.Err()
}

// IDTitle is a track ID and its title.
type IDTitle struct{ ID, Title string }

// Titles lists every track's ID and title in table order.
func Titles(q Querier) ([]IDTitle, error) {
	rows, err := q.Query("select ID, Title from djmdContent where rb_local_deleted=0")
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []IDTitle
	for rows.Next() {
		var id, title sql.NullString
		if err := rows.Scan(&id, &title); err != nil {
			return nil, err
		}
		out = append(out, IDTitle{id.String, title.String})
	}
	return out, rows.Err()
}
