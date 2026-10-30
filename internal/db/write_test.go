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
	"strconv"
	"testing"

	"github.com/bitwise-media-group/adj/internal/sqlcipher"
)

// fixture is a SQLCipher database (key 'test') with table t(id, name) holding 300 rows.
const fixture = "../sqlcipher/testdata/fixture.db"

func copyFixture(t *testing.T) (master, backups string) {
	t.Helper()
	dir := t.TempDir()
	master = filepath.Join(dir, "rekordbox", "master.db")
	if err := os.MkdirAll(filepath.Dir(master), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := copyFile(fixture, master); err != nil {
		t.Fatal(err)
	}
	return master, filepath.Join(dir, "_cue_work")
}

func countT(t *testing.T, master string) int {
	t.Helper()
	plain := filepath.Join(t.TempDir(), "p.db")
	if err := sqlcipher.Decrypt(master, plain, "test"); err != nil {
		t.Fatal(err)
	}
	d, err := openPlain(plain)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = d.Close() }()
	var n int
	if err := d.QueryRow("select count(*) from t").Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func noGuard(string) error { return nil }

func TestSafeWrite(t *testing.T) {
	master, backups := copyFixture(t)
	orig, _ := os.ReadFile(master)
	st, err := safeWrite(master, backups, "test", noGuard, func(tx *sql.Tx) (*Stats, error) {
		_, err := tx.Exec("insert into t (name) values ('new')")
		return NewStats("added", 1), err
	})
	if err != nil {
		t.Fatal(err)
	}
	if n := countT(t, master); n != 301 {
		t.Fatalf("got %d rows after the write", n)
	}
	now, _ := os.ReadFile(master)
	if !bytes.Equal(now[:sqlcipher.SaltSize], orig[:sqlcipher.SaltSize]) {
		t.Error("the salt changed")
	}
	bak, _ := os.ReadFile(st.Get("backup").(string))
	if !bytes.Equal(bak, orig) {
		t.Error("the backup is not the original database")
	}
	if got := st.String(); got != "{\n \"added\": 1,\n \"backup\": \""+st.Get("backup").(string)+"\"\n}" {
		t.Errorf("stats JSON = %s", got)
	}
}

func TestSafeWriteLeavesMasterOnFailure(t *testing.T) {
	master, backups := copyFixture(t)
	orig, _ := os.ReadFile(master)
	refuse := errors.New("rekordbox is running")
	if _, err := safeWrite(master, backups, "test", func(string) error { return refuse }, nil); !errors.Is(err, refuse) {
		t.Fatalf("guard: %v", err)
	}
	boom := errors.New("boom")
	_, err := safeWrite(master, backups, "test", noGuard, func(tx *sql.Tx) (*Stats, error) {
		if _, err := tx.Exec("delete from t"); err != nil {
			return nil, err
		}
		return nil, boom
	})
	if !errors.Is(err, boom) {
		t.Fatalf("fn error: %v", err)
	}
	if _, err := safeWrite(master, backups, "wrong", noGuard, nil); !errors.Is(err, sqlcipher.ErrHMAC) {
		t.Fatalf("wrong key: %v", err)
	}
	if now, _ := os.ReadFile(master); !bytes.Equal(now, orig) {
		t.Fatal("master.db changed although the write failed")
	}
}

// schema is the subset of Rekordbox's tables the writers touch.
const schema = `
create table djmdContent (ID varchar(255) primary key, UUID varchar(255), Rating integer, rb_local_deleted integer);
create table djmdCue (ID varchar(255) primary key, ContentID varchar(255), InMsec integer, InFrame integer,
  InMpegFrame integer, InMpegAbs integer, OutMsec integer, OutFrame integer, OutMpegFrame integer, OutMpegAbs integer,
  Kind integer, Color integer, ColorTableIndex integer, ActiveLoop integer, Comment varchar(255), BeatLoopSize integer,
  CueMicrosec integer, InPointSeekInfo varchar(255), OutPointSeekInfo varchar(255), ContentUUID varchar(255),
  UUID varchar(255), rb_data_status integer, rb_local_data_status integer, rb_local_deleted integer,
  rb_local_synced integer, usn bigint, rb_local_usn bigint, created_at datetime, updated_at datetime);
create table djmdPlaylist (ID varchar(255) primary key, Name varchar(255), rb_local_deleted integer);
create table djmdSongPlaylist (ID varchar(255) primary key, PlaylistID varchar(255), ContentID varchar(255),
  TrackNo integer, rb_local_deleted integer, updated_at datetime);
insert into djmdContent values ('10', 'uuid-10', 0, 0), ('11', 'uuid-11', 0, 0), ('12', 'uuid-12', 3, 0);
insert into djmdPlaylist values ('p1', 'Set', 0);
insert into djmdSongPlaylist values ('s1', 'p1', '10', 1, 0, null), ('s2', 'p1', '11', 2, 0, null);
`

func cueSQL(id, content string, kind, ms int, name string, color int) string {
	return "insert into djmdCue (ID, ContentID, Kind, InMsec, Comment, Color, rb_local_deleted) values ('" + id +
		"', '" + content + "', " + strconv.Itoa(kind) + ", " + strconv.Itoa(ms) + ", '" + name + "', " +
		strconv.Itoa(color) + ", 0);"
}

// withTx runs fn in a transaction on a fresh plain database holding schema and extra.
func withTx(t *testing.T, extra string, fn func(tx *sql.Tx)) *sql.DB {
	t.Helper()
	d, err := openPlain(filepath.Join(t.TempDir(), "m.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	if _, err := d.Exec(schema + extra); err != nil {
		t.Fatal(err)
	}
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	fn(tx)
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	return d
}

type cueRowOut struct {
	Kind, InMsec, InFrame, OutMsec, OutFrame, Color int
	Comment                                         string
	CTI, AL, BLS                                    sql.NullInt64
	ContentUUID                                     sql.NullString
}

func cuesOf(t *testing.T, d *sql.DB, content string) []cueRowOut {
	t.Helper()
	rows, err := d.Query(`select Kind, InMsec, coalesce(InFrame,0), coalesce(OutMsec,0), coalesce(OutFrame,0), Color,
		Comment, ColorTableIndex, ActiveLoop, BeatLoopSize, ContentUUID from djmdCue where ContentID=?
		order by InMsec, Kind`, content)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = rows.Close() }()
	var out []cueRowOut
	for rows.Next() {
		var c cueRowOut
		if err := rows.Scan(&c.Kind, &c.InMsec, &c.InFrame, &c.OutMsec, &c.OutFrame, &c.Color, &c.Comment, &c.CTI, &c.AL,
			&c.BLS, &c.ContentUUID); err != nil {
			t.Fatal(err)
		}
		out = append(out, c)
	}
	return out
}

func TestApplyPlan(t *testing.T) {
	extra := cueSQL("1", "10", 1, 1000, "Energy 5", -1) + cueSQL("2", "10", 0, 64000, "DROP", 4) +
		cueSQL("3", "10", 0, 2000, "CUE(Auto)", 0) +
		cueSQL("4", "11", 1, 1000, "Energy 5", -1) + cueSQL("5", "11", 6, 9000, "ARIA", -1) // 11: a hand-made E
	plan := []PlanTrack{
		{ID: "10", Title: "Ten", Hot: []PlanHot{
			{Kind: 1, Name: "IN", MS: 15000},
			{Kind: 9, Name: "EMERGENCY", MS: 200000, Loop: 32, OutMS: 215000},
		},
			Mem: []PlanMem{{Name: "START", MS: 0}, {Name: "DROP", MS: 64200}}},
		{ID: "11", Title: "Eleven", Hot: []PlanHot{{Kind: 1, Name: "IN", MS: 15000}}},
		{ID: "99", Title: "Gone"},
	}
	var st *Stats
	d := withTx(t, extra, func(tx *sql.Tx) {
		var err error
		if st, err = ApplyPlan(tx, plan, nil); err != nil {
			t.Fatal(err)
		}
	})
	if st.Get("updated") != 1 || st.Get("removed") != 2 || st.Get("added") != 3 ||
		!slices.Equal(st.Get("skipped").([]string), []string{"Eleven", "Gone"}) {
		t.Fatalf("stats %s", st)
	}
	uuid := sql.NullString{String: "uuid-10", Valid: true}
	want := []cueRowOut{
		{Kind: 0, InMsec: 0, OutMsec: -1, Color: 1, Comment: "START", ContentUUID: uuid},
		{Kind: 1, InMsec: 15000, InFrame: 2250, OutMsec: -1, Color: -1, Comment: "IN", ContentUUID: uuid},
		{Kind: 0, InMsec: 64000, Color: 4, Comment: "DROP"}, // the user's own DROP: kept, not duplicated
		{Kind: 9, InMsec: 200000, InFrame: 30000, OutMsec: 215000, OutFrame: 32250, Color: 255, Comment: "EMERGENCY",
			CTI: sql.NullInt64{Valid: true}, AL: sql.NullInt64{Int64: 1, Valid: true},
			BLS: sql.NullInt64{Int64: 2097153, Valid: true}, ContentUUID: uuid},
	}
	if got := cuesOf(t, d, "10"); !slices.Equal(got, want) {
		t.Errorf("cues of 10:\n got %+v\nwant %+v", got, want)
	}
	if got := cuesOf(t, d, "11"); len(got) != 2 {
		t.Errorf("skipped track changed: %+v", got)
	}
}

func TestApplyPlanRerun(t *testing.T) {
	extra := cueSQL("1", "10", 1, 1000, "IN", -1) + cueSQL("2", "10", 6, 5000, "ARIA", -1) +
		cueSQL("3", "10", 0, 0, "START", 1)
	plan := []PlanTrack{{ID: "10", Title: "Ten", Hot: []PlanHot{{Kind: 1, Name: "IN", MS: 33000}},
		Mem: []PlanMem{{Name: "START", MS: 0}}}}
	d := withTx(t, extra, func(tx *sql.Tx) {
		st, err := ApplyPlan(tx, plan, map[string]bool{"10": true})
		if err != nil || st.Get("updated") != 1 || st.Get("removed") != 2 {
			t.Fatalf("%v %s", err, st)
		}
	})
	got := cuesOf(t, d, "10") // ARIA (the user's E) survives; IN moved; START re-added once
	if len(got) != 3 || got[2].Comment != "IN" || got[2].InMsec != 33000 || got[1].Comment != "ARIA" {
		t.Errorf("%+v", got)
	}
}

func TestApplySetAndReorder(t *testing.T) {
	extra := cueSQL("1", "10", 0, 1000, "Low Pass", 7) + cueSQL("2", "10", 7, 2000, "JUMP TO DROP", -1) +
		cueSQL("3", "10", 0, 3000, "BASS SWAP", 1) + cueSQL("4", "10", 0, 9000, "CUT OUT", 6) +
		cueSQL("5", "10", 8, 4000, "OLD", -1)
	beats := map[string][]float64{"10": {0, 1, 2, 3, 4, 5, 6, 7, 8, 9}}
	acts := []SetCues{{
		ID: "10", Title: "Ten",
		E:       &SetSlot{Name: "START", Beat: 1, Status: "new"},
		G:       &SetSlot{Name: "ELEVEN", Beat: 6, Status: "replace"},
		Markers: []SetMarker{{"BASS SWAP OUT", 4, "rename"}, {"FILTER OUT", 8, "new"}},
		Remove:  []SetMarker{{"CUT OUT", 10, "no CUT IN on the next track there"}},
	}}
	d := withTx(t, extra, func(tx *sql.Tx) {
		st, err := ApplySet(tx, acts, beats)
		if err != nil {
			t.Fatal(err)
		}
		want := "{\n \"hot_cues\": 2,\n \"markers\": 1,\n \"removed\": 2,\n \"renamed\": 3,\n" +
			" \"recoloured\": 1,\n \"skipped\": []\n}"
		if st.String() != want {
			t.Errorf("stats %s", st)
		}
		if _, err := ReorderPlaylist(tx, "Set", []string{"11", "10"}); err != nil {
			t.Fatal(err)
		}
		if _, err := ReorderPlaylist(tx, "Set", []string{"10"}); err == nil {
			t.Error("a changed playlist must be refused")
		}
	})
	cues := cuesOf(t, d, "10")
	names := make([]string, 0, len(cues))
	for _, c := range cues {
		names = append(names, c.Comment)
	}
	want := []string{"START", "FILTER", "JUMP", "BASS SWAP OUT", "ELEVEN", "FILTER OUT"}
	if !slices.Equal(names, want) {
		t.Errorf("cues %v, want %v", names, want)
	}
	var first string
	err := d.QueryRow("select ContentID from djmdSongPlaylist order by TrackNo limit 1").Scan(&first)
	if err != nil || first != "11" {
		t.Errorf("reorder: %q %v", first, err)
	}
}
