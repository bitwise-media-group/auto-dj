// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package sqlcipher

import (
	"bytes"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

// testdata/fixture.db was written by sqlcipher3 (SQLCipher 4.12, defaults) with key 'test':
// table t(id, name) holding 300 rows 'row 0000 xxx…'.
const fixture = "testdata/fixture.db"

func TestRekordboxKey(t *testing.T) {
	t.Setenv("REKORDBOX_DB_KEY", "")
	k, err := RekordboxKey()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(k, keyPrefix) {
		t.Fatalf("key %q does not start with %s", k[:5], keyPrefix)
	}
	t.Setenv("REKORDBOX_DB_KEY", "nope")
	if _, err := RekordboxKey(); err == nil {
		t.Fatal("bad REKORDBOX_DB_KEY accepted")
	}
}

func TestB85(t *testing.T) {
	// base64.b85encode(b'hello world!') and b85encode(b'abc') (padded group)
	for in, want := range map[string]string{"Xk~0{Zy<MXa%^NF": "hello world!", "VPaz": "abc"} {
		got, err := b85decode(in)
		if err != nil || string(got) != want {
			t.Errorf("b85decode(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
}

func countRows(t *testing.T, path string) (n int, first string) {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = db.Close() }()
	var ok string
	if err := db.QueryRow("pragma integrity_check").Scan(&ok); err != nil || ok != "ok" {
		t.Fatalf("integrity_check: %q %v", ok, err)
	}
	if err := db.QueryRow("select count(*), (select name from t where id=1) from t").Scan(&n, &first); err != nil {
		t.Fatal(err)
	}
	return n, first
}

func TestDecryptFixture(t *testing.T) {
	plain := filepath.Join(t.TempDir(), "plain.db")
	if err := Decrypt(fixture, plain, "test"); err != nil {
		t.Fatal(err)
	}
	n, first := countRows(t, plain)
	if n != 300 || first != "row 0000 "+strings.Repeat("x", 40) {
		t.Fatalf("got %d rows, first %q", n, first)
	}
}

func TestWrongKey(t *testing.T) {
	err := Decrypt(fixture, filepath.Join(t.TempDir(), "x.db"), "wrong")
	if !errors.Is(err, ErrHMAC) {
		t.Fatalf("want ErrHMAC, got %v", err)
	}
}

func TestRoundTripSameIVs(t *testing.T) {
	dir := t.TempDir()
	plain, again := filepath.Join(dir, "plain.db"), filepath.Join(dir, "again.db")
	if err := Decrypt(fixture, plain, "test"); err != nil {
		t.Fatal(err)
	}
	salt, err := ReadSalt(fixture)
	if err != nil {
		t.Fatal(err)
	}
	ivs, err := PageIVs(fixture)
	if err != nil {
		t.Fatal(err)
	}
	if err := EncryptWithIVs(plain, again, "test", salt, ivs); err != nil {
		t.Fatal(err)
	}
	a, _ := os.ReadFile(fixture)
	b, _ := os.ReadFile(again)
	if !bytes.Equal(a, b) {
		t.Fatal("re-encrypting with the original IVs did not reproduce the file")
	}
}

func TestRoundTripFreshIVs(t *testing.T) {
	dir := t.TempDir()
	plain, enc, back := filepath.Join(dir, "plain.db"), filepath.Join(dir, "enc.db"), filepath.Join(dir, "back.db")
	if err := Decrypt(fixture, plain, "test"); err != nil {
		t.Fatal(err)
	}
	salt, _ := ReadSalt(fixture)
	if err := Encrypt(plain, enc, "test", salt); err != nil {
		t.Fatal(err)
	}
	a, _ := os.ReadFile(fixture)
	b, _ := os.ReadFile(enc)
	if bytes.Equal(a, b) || !bytes.Equal(a[:SaltSize], b[:SaltSize]) {
		t.Fatal("fresh IVs should change the ciphertext but keep the salt")
	}
	if err := Decrypt(enc, back, "test"); err != nil {
		t.Fatal(err)
	}
	if n, _ := countRows(t, back); n != 300 {
		t.Fatalf("got %d rows", n)
	}
}

func TestEncryptRejectsWrongLayout(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "plain.db")
	db, err := sql.Open("sqlite", p)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("create table x(a)"); err != nil {
		t.Fatal(err)
	}
	_ = db.Close()
	if err := Encrypt(p, filepath.Join(dir, "e.db"), "k", make([]byte, SaltSize)); err == nil {
		t.Fatal("a database without 80 reserve bytes must be refused")
	}
}
