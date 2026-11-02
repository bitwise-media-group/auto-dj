// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package db

import (
	"database/sql"
	"errors"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// librarySchema is the subset of Rekordbox's tables that playlists and intelligent playlists read.
const librarySchema = `
create table djmdContent (ID varchar(255) primary key, Title varchar(255), ArtistID varchar(255),
  AlbumID varchar(255), GenreID varchar(255), BPM integer, Length integer, Commnt text, Rating integer,
  ReleaseYear integer, RemixerID varchar(255), LabelID varchar(255), OrgArtistID varchar(255), KeyID varchar(255),
  StockDate varchar(255), ColorID varchar(255), DJPlayCount integer, FileNameL varchar(255),
  ComposerID varchar(255), Subtitle varchar(255), ReleaseDate varchar(255), DateCreated varchar(255),
  rb_local_deleted integer, created_at datetime);
create table djmdArtist (ID varchar(255) primary key, Name varchar(255));
create table djmdAlbum (ID varchar(255) primary key, Name varchar(255), AlbumArtistID varchar(255));
create table djmdGenre (ID varchar(255) primary key, Name varchar(255));
create table djmdLabel (ID varchar(255) primary key, Name varchar(255));
create table djmdKey (ID varchar(255) primary key, ScaleName varchar(255));
create table djmdSongMyTag (ID varchar(255) primary key, MyTagID varchar(255), ContentID varchar(255),
  rb_local_deleted integer);
create table djmdPlaylist (ID varchar(255) primary key, Seq integer, Name varchar(255), Attribute integer,
  SmartList text, rb_local_deleted integer);
create table djmdSongPlaylist (ID varchar(255) primary key, PlaylistID varchar(255), ContentID varchar(255),
  TrackNo integer, rb_local_deleted integer);

insert into djmdArtist values ('a1', 'Bicep'), ('a2', 'Fred again..'), ('a3', 'Ben_Böhmer');
insert into djmdAlbum values ('al1', 'Isles', 'a1');
insert into djmdGenre values ('g1', 'Deep House'), ('g2', 'Techno');
insert into djmdLabel values ('l1', 'Ninja Tune');
insert into djmdKey values ('k1', 'Am'), ('k2', 'Fm');
-- ID, Title, ArtistID, AlbumID, GenreID, BPM, Length, Commnt, Rating, ReleaseYear, RemixerID, LabelID,
-- OrgArtistID, KeyID, StockDate, ColorID, DJPlayCount, FileNameL, ComposerID, Subtitle, ReleaseDate, DateCreated,
-- rb_local_deleted, created_at
insert into djmdContent values
  ('1', 'Glue', 'a1', 'al1', 'g1', 12200, 269, '8A - Energy 6', 0, 2017, null, 'l1', null, 'k1',
   '2026-09-03', '0', 0, 'Glue.aiff', null, 'Original', '2017-08-01', '2026-08-31', 0, '2026-09-03 10:00:00'),
  ('2', 'Delilah', 'a2', null, 'g1', 12800, 251, null, 3, 2022, 'a3', null, null, 'k2',
   '2026-10-20', '5', 4, 'Delilah.aiff', null, 'Extended', '', '2026-10-19', 0, '2026-10-20 10:00:00'),
  ('3', 'Beyond Beliefs', 'a3', null, 'g2', 12450, 412, '4A', 5, 2023, null, null, 'a1', null,
   '2026-10-30', null, 12, 'Beyond.mp3', 'a2', null, null, null, 0, '2026-10-30 10:00:00'),
  ('4', 'Deleted', 'a1', null, 'g1', 12800, 300, null, 0, 2026, null, null, null, 'k1',
   '2026-10-31', '0', 0, 'Gone.aiff', null, null, null, null, 1, '2026-10-31 10:00:00');
insert into djmdSongMyTag values ('t1', '2589317697', '2', 0), ('t2', '1470147897', '3', 0),
  ('t3', '1470147897', '1', 1);
insert into djmdPlaylist values
  ('f1', 1, 'Sets', 1, null, 0),
  ('p1', 2, 'Melodic Dark', 0, null, 0),
  ('p5', 6, 'Old', 0, null, 1);
insert into djmdSongPlaylist values ('s1', 'p1', '3', 2, 0), ('s2', 'p1', '1', 1, 0), ('s3', 'p1', '2', 3, 1);
`

func library(t *testing.T) *sql.DB {
	t.Helper()
	d, err := openPlain(filepath.Join(t.TempDir(), "m.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	if _, err := d.Exec(librarySchema); err != nil {
		t.Fatal(err)
	}
	for _, p := range []struct{ id, name, src string }{
		{"p2", "Never Played", node("1", cond("counter", "1", "", "", ""))},
		{"p3", "Played", node("1", cond("counter", "2", "", "", ""))},
		{"p4", "Broken", node("1", cond("vibe", "1", "", "x", ""))},
	} {
		_, err := d.Exec("insert into djmdPlaylist values (?, ?, ?, 4, ?, 0)", p.id, p.id[1:], p.name, p.src)
		if err != nil {
			t.Fatal(err)
		}
	}
	return d
}

var today = time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)

func node(logic string, conds ...string) string {
	return `<NODE Id="1" LogicalOperator="` + logic + `" AutomaticUpdate="0">` + strings.Join(conds, "") + `</NODE>`
}

func cond(prop, op, unit, left, right string) string {
	return `<CONDITION PropertyName="` + prop + `" Operator="` + op + `" ValueUnit="` + unit + `" ValueLeft="` +
		left + `" ValueRight="` + right + `"/>`
}

// matches returns the IDs of the live tracks that src matches, in ID order.
func matches(t *testing.T, d *sql.DB, src string) []string {
	t.Helper()
	where, args, err := smartWhere(src, today)
	if err != nil {
		t.Fatalf("%s: %v", src, err)
	}
	rows, err := d.Query("select c.ID from djmdContent c where c.rb_local_deleted=0 and ("+where+") order by c.ID",
		args...)
	if err != nil {
		t.Fatalf("%s: %v", where, err)
	}
	defer func() { _ = rows.Close() }()
	out := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			t.Fatal(err)
		}
		out = append(out, id)
	}
	return out
}

func TestSmartWhere(t *testing.T) {
	d := library(t)
	for _, c := range []struct {
		name, src string
		want      []string
	}{
		{"never played", node("1", cond("counter", "1", "", "", "")), []string{"1"}},
		{"played", node("1", cond("counter", "2", "", "", "")), []string{"2", "3"}},
		{"unrated", node("1", cond("rating", "1", "", "", "")), []string{"1"}},
		{"rated 3+", node("1", cond("rating", "3", "", "2", "")), []string{"2", "3"}},
		{"after 2019", node("1", cond("year", "3", "", "2019", "")), []string{"2", "3"}},
		{"bpm range", node("1", cond("bpm", "5", "", "122", "125")), []string{"1", "3"}},
		{"bpm decimal", node("1", cond("bpm", "1", "", "124.5", "")), []string{"3"}},
		{"bpm under", node("1", cond("bpm", "4", "", "128", "")), []string{"1", "3"}},
		{"duration", node("1", cond("duration", "3", "", "300", "")), []string{"3"}},
		{"artist is, any case", node("1", cond("artist", "1", "", "BICEP", "")), []string{"1"}},
		{"artist is not", node("1", cond("artist", "2", "", "bicep", "")), []string{"2", "3"}},
		{"artist contains literal _", node("1", cond("artist", "8", "", "n_b", "")), []string{"3"}},
		{"artist contains no wildcard", node("1", cond("artist", "8", "", "e_", "")), []string{}},
		{"genre contains", node("1", cond("genre", "8", "", "house", "")), []string{"1", "2"}},
		{"genre does not contain", node("1", cond("genre", "9", "", "house", "")), []string{"3"}},
		{"name starts with", node("1", cond("name", "10", "", "de", "")), []string{"2"}},
		{"file ends with", node("1", cond("fileName", "11", "", ".AIFF", "")), []string{"1", "2"}},
		{"comments empty", node("1", cond("comments", "1", "", "", "")), []string{"2"}},
		{"key", node("1", cond("key", "1", "", "Am", "")), []string{"1"}},
		{"album artist", node("1", cond("albumArtist", "1", "", "Bicep", "")), []string{"1"}},
		{"album", node("1", cond("album", "8", "", "isl", "")), []string{"1"}},
		{"label", node("1", cond("label", "1", "", "ninja tune", "")), []string{"1"}},
		{"remixer", node("1", cond("remixedBy", "1", "", "Ben_Böhmer", "")), []string{"2"}},
		{"original artist", node("1", cond("originalArtist", "1", "", "Bicep", "")), []string{"3"}},
		{"producer", node("1", cond("producer", "8", "", "fred", "")), []string{"3"}},
		{"mix name", node("1", cond("mixName", "1", "", "extended", "")), []string{"2"}},
		{"colour", node("1", cond("grouping", "1", "", "5", "")), []string{"2"}},
		{"no colour", node("1", cond("grouping", "1", "", "", "")), []string{"1", "3"}},
		{"my tag", node("1", cond("myTag", "8", "", "1470147897", "")), []string{"3"}},
		{"my tag, signed", node("1", cond("myTag", "1", "", "-1705649599", "")), []string{"2"}},
		{"not my tag", node("1", cond("myTag", "9", "", "1470147897", "")), []string{"1", "2"}},
		{"added on", node("1", cond("stockDate", "1", "", "2026-10-20", "")), []string{"2"}},
		{"added after", node("1", cond("stockDate", "3", "", "2026-10-01", "")), []string{"2", "3"}},
		{"added in range", node("1", cond("stockDate", "5", "", "2026-09-01", "2026-10-20")), []string{"1", "2"}},
		{"added in last 14 days", node("1", cond("stockDate", "6", "1", "14", "")), []string{"2", "3"}},
		{"added in last month", node("1", cond("stockDate", "6", "2", "1", "")), []string{"2", "3"}},
		{"not added in last 5 days", node("1", cond("stockDate", "7", "day", "5", "")), []string{"1", "2"}},
		{"released before", node("1", cond("dateReleased", "4", "", "2020-01-01", "")), []string{"1"}},
		{"no release date", node("1", cond("dateReleased", "1", "", "", "")), []string{"2", "3"}},
		{"created", node("1", cond("dateCreated", "3", "", "2026-09-01", "")), []string{"2"}},
		{"all", node("1", cond("genre", "8", "", "house", ""), cond("rating", "3", "", "0", "")),
			[]string{"2"}},
		{"any", node("2", cond("genre", "1", "", "techno", ""), cond("rating", "1", "", "0", "")),
			[]string{"1", "3"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := matches(t, d, c.src); !slices.Equal(got, c.want) {
				t.Errorf("got %v, want %v", got, c.want)
			}
		})
	}
}

func TestSmartWhereRefuses(t *testing.T) {
	for _, src := range []string{
		"not xml",
		node("3", cond("rating", "1", "", "", "")),
		node("1"),
		node("1", cond("vibe", "1", "", "x", "")),
		node("1", cond("rating", "8", "", "3", "")),
		node("1", cond("artist", "3", "", "a", "")),
		node("1", cond("bpm", "1", "", "fast", "")),
		node("1", cond("bpm", "5", "", "120", "fast")),
		node("1", cond("stockDate", "1", "", "1/9/2026", "")),
		node("1", cond("stockDate", "5", "", "2026-09-01", "")),
		node("1", cond("stockDate", "6", "3", "2", "")),
		node("1", cond("myTag", "8", "", "Techno", "")),
		node("1", cond("grouping", "8", "", "5", "")),
	} {
		if _, _, err := smartWhere(src, today); err == nil {
			t.Errorf("%s: no error", src)
		}
	}
}

func TestLoadPlaylist(t *testing.T) {
	d := library(t)
	pl, err := loadPlaylist(d, "Melodic Dark", today)
	if err != nil {
		t.Fatal(err)
	}
	want := []PlaylistTrack{{1, "1", "Glue", 122, "Am"}, {2, "3", "Beyond Beliefs", 124.5, ""}}
	if pl.Intelligent || !slices.Equal(pl.Tracks, want) {
		t.Errorf("playlist: %+v", pl)
	}

	pl, err = loadPlaylist(d, "Played", today)
	if err != nil {
		t.Fatal(err)
	}
	want = []PlaylistTrack{{1, "2", "Delilah", 128, "Fm"}, {2, "3", "Beyond Beliefs", 124.5, ""}}
	if !pl.Intelligent || !slices.Equal(pl.Tracks, want) {
		t.Errorf("intelligent playlist: %+v", pl)
	}

	for name, msg := range map[string]string{
		"Sets":    "is a folder",
		"Old":     "no playlist called",
		"Missing": "no playlist called",
		"Broken":  "intelligent playlist 'Broken': condition vibe 1",
	} {
		_, err := loadPlaylist(d, name, today)
		if err == nil || !strings.Contains(err.Error(), msg) {
			t.Errorf("%s: %v", name, err)
		}
		if name != "Broken" && !errors.Is(err, ErrNoPlaylist) {
			t.Errorf("%s: %v is not ErrNoPlaylist", name, err)
		}
	}
}

func TestListPlaylists(t *testing.T) {
	got, err := ListPlaylists(library(t))
	if err != nil {
		t.Fatal(err)
	}
	want := []Playlist{{Name: "Melodic Dark"}, {Name: "Never Played", Intelligent: true},
		{Name: "Played", Intelligent: true}, {Name: "Broken", Intelligent: true}}
	same := func(a, b Playlist) bool { return a.Name == b.Name && a.Intelligent == b.Intelligent }
	if !slices.EqualFunc(got, want, same) {
		t.Errorf("got %+v", got)
	}
}
