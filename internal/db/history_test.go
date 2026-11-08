// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package db

import (
	"bytes"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// libSchema is the subset of Rekordbox's tables the history, tag and playlist code reads
// and writes, with Rekordbox's own column lists.
const libSchema = `
create table djmdContent (ID varchar(255) primary key, Title varchar(255), ArtistID varchar(255),
  AlbumID varchar(255), GenreID varchar(255), BPM integer, Commnt varchar(255), ReleaseYear integer,
  RemixerID varchar(255), LabelID varchar(255), OrgArtistID varchar(255), KeyID varchar(255),
  ComposerID varchar(255), FolderPath varchar(255), rb_local_deleted integer default 0);
create table djmdArtist (ID varchar(255) primary key, Name varchar(255));
create table djmdAlbum (ID varchar(255) primary key, Name varchar(255), AlbumArtistID varchar(255));
create table djmdGenre (ID varchar(255) primary key, Name varchar(255));
create table djmdLabel (ID varchar(255) primary key, Name varchar(255));
create table djmdKey (ID varchar(255) primary key, ScaleName varchar(255));
create table djmdHistory (ID varchar(255) primary key, Seq integer, Name varchar(255), Attribute integer,
  ParentID varchar(255), DateCreated varchar(255), rb_local_deleted integer default 0);
create table djmdSongHistory (ID varchar(255) primary key, HistoryID varchar(255), ContentID varchar(255),
  TrackNo integer, rb_local_deleted integer default 0, created_at datetime);
create table djmdPlaylist (ID varchar(255) primary key, Seq integer, Name varchar(255), ImagePath varchar(255),
  Attribute integer, ParentID varchar(255), SmartList text, UUID varchar(255), rb_data_status integer default 0,
  rb_local_data_status integer default 0, rb_local_deleted tinyint(1) default 0, rb_local_synced tinyint(1) default 0,
  usn bigint, rb_local_usn bigint, created_at datetime not null, updated_at datetime not null);
create table djmdSongPlaylist (ID varchar(255) primary key, PlaylistID varchar(255), ContentID varchar(255),
  TrackNo integer, UUID varchar(255), rb_data_status integer default 0, rb_local_data_status integer default 0,
  rb_local_deleted tinyint(1) default 0, rb_local_synced tinyint(1) default 0, usn bigint, rb_local_usn bigint,
  created_at datetime not null, updated_at datetime not null);
insert into djmdArtist values ('a1', 'Oxia'), ('a2', 'Giorgio Moroder'), ('a3', 'DJ Deavon');
insert into djmdAlbum values ('al1', 'Domino', 'a3');
insert into djmdGenre values ('g1', 'Techno');
insert into djmdLabel values ('l1', 'Kompakt');
insert into djmdKey values ('k1', 'Am');
insert into djmdContent (ID, Title, ArtistID, AlbumID, GenreID, BPM, Commnt, ReleaseYear, LabelID, KeyID, ComposerID,
  FolderPath) values
  ('10', 'Domino (Original Mix)', 'a1', 'al1', 'g1', 12800, '8A', 2003, 'l1', 'k1', 'a2', '/m/domino.aiff'),
  ('11', 'Second', 'a1', null, null, 12600, null, null, null, null, null, '/m/second.aiff'),
  ('12', 'Third', null, null, null, 12400, null, null, null, null, null, '/m/third.aiff');
insert into djmdHistory values ('2026', 1, '2026', 1, 'root', '2026-11-01 22:21:19', 0),
  ('h1', 1, 'HISTORY 2026-11-07', 0, '2026', '2026-11-07 19:58:27', 0),
  ('h0', 2, 'HISTORY 2026-11-01', 0, '2026', '2026-11-01 22:21:19', 0);
insert into djmdSongHistory values ('s1', 'h1', '12', 2, 0, '2026-11-07 19:58:27.406 +00:00'),
  ('s2', 'h1', '10', 1, 0, '2026-11-07 19:58:27.406 +00:00'),
  ('s3', 'h1', '12', 3, 0, '2026-11-07 19:58:27.407 +00:00'),
  ('s4', 'h1', '11', 4, 1, '2026-11-07 19:58:27.407 +00:00');
insert into djmdPlaylist (ID, Seq, Name, Attribute, ParentID, created_at, updated_at) values
  ('200000', 1, 'Dark Mode', 0, 'root', 'x', 'x'), ('300', 2, 'Gigs', 1, 'root', 'x', 'x'),
  ('301', 1, 'Old Gig', 0, '300', 'x', 'x');
`

func libDB(t *testing.T) *sql.DB {
	t.Helper()
	d, err := openPlain(filepath.Join(t.TempDir(), "lib.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	if _, err := d.Exec(libSchema); err != nil {
		t.Fatal(err)
	}
	return d
}

func TestHistories(t *testing.T) {
	d := libDB(t)
	hs, err := ListHistories(d)
	if err != nil {
		t.Fatal(err)
	}
	if len(hs) != 2 || hs[0].Name != "HISTORY 2026-11-01" || hs[1].Tracks != 3 {
		t.Fatalf("histories %+v", hs)
	}
	h, rows, err := LoadHistory(d, "HISTORY 2026-11-07")
	if err != nil {
		t.Fatal(err)
	}
	ids := make([]string, 0, len(rows))
	for _, r := range rows {
		ids = append(ids, r.ID)
	}
	if !slices.Equal(ids, []string{"10", "12", "12"}) || rows[0].BPM != 128 || rows[0].Key != "Am" ||
		rows[0].Created == "" || h.Date() != "2026-11-07" {
		t.Errorf("history %+v rows %+v", h, rows)
	}
	if _, _, err := LoadHistory(d, "2026"); !errors.Is(err, ErrNoHistory) {
		t.Errorf("a history folder must not load: %v", err)
	}
}

func TestLoadTags(t *testing.T) {
	tags, err := LoadTags(libDB(t), []string{"10", "11", "99"})
	if err != nil {
		t.Fatal(err)
	}
	want := Tags{ID: "10", Title: "Domino (Original Mix)", Artist: "Oxia", Composer: "Giorgio Moroder",
		Album: "Domino", AlbumArtist: "DJ Deavon", Genre: "Techno", Label: "Kompakt", Key: "Am", Year: 2003, BPM: 128,
		Comment: "8A", FolderPath: "/m/domino.aiff"}
	if len(tags) != 2 || tags["10"] != want || tags["11"].Artist != "Oxia" || tags["11"].Genre != "" {
		t.Errorf("tags %+v", tags)
	}
}

func TestCreatePlaylist(t *testing.T) {
	d := libDB(t)
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	p, err := CreatePlaylist(tx, "HISTORY 2026-11-07", "", []string{"10", "12", "12"})
	if err != nil {
		t.Fatal(err)
	}
	sub, err := CreatePlaylist(tx, "In Gigs", "Gigs", []string{"11"})
	if err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	var seq, attr int
	var parent, uid, created string
	if err := d.QueryRow("select Seq, Attribute, ParentID, UUID, created_at from djmdPlaylist where ID=?", p.ID).
		Scan(&seq, &attr, &parent, &uid, &created); err != nil {
		t.Fatal(err)
	}
	if seq != 3 || attr != 0 || parent != "root" || len(uid) != 36 || !strings.HasSuffix(created, " +00:00") {
		t.Errorf("playlist row: seq %d attr %d parent %s uuid %s created %s", seq, attr, parent, uid, created)
	}
	var subSeq int
	if err := d.QueryRow("select Seq from djmdPlaylist where ID=?", sub.ID).Scan(&subSeq); err != nil || subSeq != 2 ||
		sub.ParentID != "300" {
		t.Errorf("folder playlist: seq %d parent %s %v", subSeq, sub.ParentID, err)
	}
	checkPlaylistTracks(t, d, p.ID)
}

func checkPlaylistTracks(t *testing.T, d *sql.DB, id string) {
	t.Helper()
	pl, err := LoadPlaylist(d, "HISTORY 2026-11-07")
	if err != nil {
		t.Fatal(err)
	}
	ids := make([]string, 0, len(pl.Tracks))
	for _, x := range pl.Tracks {
		ids = append(ids, x.ID)
	}
	if !slices.Equal(ids, []string{"10", "12", "12"}) {
		t.Errorf("playlist tracks %v", ids)
	}
	var songID string
	if err := d.QueryRow("select ID from djmdSongPlaylist where PlaylistID=? and TrackNo=1", id).
		Scan(&songID); err != nil || len(songID) != 36 {
		t.Errorf("djmdSongPlaylist IDs are UUIDs like Rekordbox's: %q %v", songID, err)
	}
}

func TestCreatePlaylistRefuses(t *testing.T) {
	tx, err := libDB(t).Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := CreatePlaylist(tx, "Dark Mode", "", []string{"10"}); !errors.Is(err, ErrPlaylistExists) {
		t.Errorf("an existing name must be refused: %v", err)
	}
	if _, err := CreatePlaylist(tx, "Gigs", "", []string{"10"}); !errors.Is(err, ErrPlaylistExists) {
		t.Errorf("a folder's name must be refused: %v", err)
	}
	if _, err := CreatePlaylist(tx, "New", "", []string{"99"}); err == nil {
		t.Error("an unknown track must be refused")
	}
	if _, err := CreatePlaylist(tx, "New", "Nope", []string{"10"}); err == nil {
		t.Error("an unknown folder must be refused")
	}
}

const xmlDoc = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n\r\n<MASTER_PLAYLIST Version=\"3.0.0\" " +
	"AutomaticSync=\"0\">\r\n  <PRODUCT Name=\"rekordbox\" Version=\"7.2.19\" Company=\"Pioneer DJ\"/>\r\n" +
	"  <PLAYLISTS>\r\n" +
	"    <NODE Id=\"30D40\" ParentId=\"0\" Attribute=\"0\" Timestamp=\"0\" Lib_Type=\"0\" CheckType=\"0\"/>\r\n" +
	"  </PLAYLISTS>\r\n</MASTER_PLAYLIST>\r\n"

func TestAddPlaylistNode(t *testing.T) {
	p := NewPlaylist{ID: "3885415173", ParentID: "root", Created: time.UnixMilli(1793572897663)}
	got, err := AddPlaylistNode([]byte(xmlDoc), p)
	if err != nil {
		t.Fatal(err)
	}
	node := "    <NODE Id=\"E796BB05\" ParentId=\"0\" Attribute=\"0\" Timestamp=\"1793572897663\" " +
		"Lib_Type=\"0\" CheckType=\"0\"/>\r\n  </PLAYLISTS>"
	if !strings.Contains(string(got), node) || len(got) != len(xmlDoc)+len(node)-len("  </PLAYLISTS>") {
		t.Errorf("node not appended as expected:\n%s", got)
	}
	if _, err := AddPlaylistNode(got, p); err == nil {
		t.Error("a duplicate Id must be refused")
	}
	sub, _ := AddPlaylistNode([]byte(xmlDoc), NewPlaylist{ID: "2", ParentID: "300"})
	if !strings.Contains(string(sub), `<NODE Id="2" ParentId="12C"`) {
		t.Errorf("folder parent not in hex:\n%s", sub)
	}
	if _, err := AddPlaylistNode([]byte("<MASTER_PLAYLIST/>"), p); err == nil {
		t.Error("a file without PLAYLISTS must be refused")
	}
}

// TestSafeWriteSidecar checks master.db and the XML change together, and that neither
// changes when the sidecar can't be updated.
func TestSafeWriteSidecar(t *testing.T) {
	master, backups := copyFixture(t)
	xml := filepath.Join(filepath.Dir(master), PlaylistXML)
	if err := os.WriteFile(xml, []byte(xmlDoc), 0o644); err != nil {
		t.Fatal(err)
	}
	insert := func(tx *sql.Tx) (*Stats, error) {
		_, err := tx.Exec("insert into t (name) values ('new')")
		return NewStats("added", 1), err
	}
	orig, _ := os.ReadFile(master)
	boom := errors.New("bad xml")
	_, err := safeWrite(master, backups, "test", noGuard, insert,
		Sidecar{xml, func([]byte) ([]byte, error) { return nil, boom }})
	if !errors.Is(err, boom) {
		t.Fatalf("sidecar error: %v", err)
	}
	if now, _ := os.ReadFile(master); !bytes.Equal(now, orig) {
		t.Fatal("master.db changed although the sidecar failed")
	}
	st, err := safeWrite(master, backups, "test", noGuard, insert,
		Sidecar{xml, func(old []byte) ([]byte, error) { return append(old, "<!-- x -->"...), nil }})
	if err != nil {
		t.Fatal(err)
	}
	if n := countT(t, master); n != 301 {
		t.Errorf("got %d rows after the write", n)
	}
	if now, _ := os.ReadFile(xml); !strings.HasSuffix(string(now), "<!-- x -->") {
		t.Error("the sidecar was not written")
	}
	baks, _ := st.Get("sidecar_backups").([]string)
	if b, err := os.ReadFile(baks[0]); err != nil || string(b) != xmlDoc {
		t.Errorf("sidecar backup: %v", err)
	}
}

// TestWritePlaylistXML runs WritePlaylist's two steps on a plain library: the playlist row
// and its XML node carry the same ID.
func TestWritePlaylistXML(t *testing.T) {
	dir := t.TempDir()
	master := filepath.Join(dir, "master.db")
	d, err := openPlain(master)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(libSchema); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, PlaylistXML), []byte(xmlDoc), 0o644); err != nil {
		t.Fatal(err)
	}
	write := func(fn ApplyFunc, sides ...Sidecar) (*Stats, error) {
		tx, err := d.Begin()
		if err != nil {
			return nil, err
		}
		st, err := fn(tx)
		if err != nil {
			_ = tx.Rollback()
			return nil, err
		}
		staged, err := stageSidecars(sides, filepath.Join(dir, "bak"))
		if err != nil {
			_ = tx.Rollback()
			return nil, err
		}
		for _, s := range staged {
			if err := writeAtomic(s.path, s.new); err != nil {
				return nil, err
			}
		}
		return st, tx.Commit()
	}
	st, err := writePlaylist(master, "Gig", "", []string{"10", "11"}, write)
	if err != nil {
		t.Fatal(err)
	}
	id := st.Get("playlist_id").(string)
	hex, _ := xmlID(id)
	if doc, _ := os.ReadFile(filepath.Join(dir, PlaylistXML)); !strings.Contains(string(doc), `<NODE Id="`+hex+`"`) {
		t.Errorf("no XML node for playlist %s (%s):\n%s", id, hex, doc)
	}
	_ = d.Close()
}
