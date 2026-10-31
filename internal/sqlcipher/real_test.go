// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package sqlcipher

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// TestRealRoundTrip decrypts a real master.db (AUTO_DJ_TEST_MASTER_DB, never the live one) and
// re-encrypts it with the original IVs: the result must match byte for byte.
func TestRealRoundTrip(t *testing.T) {
	src := os.Getenv("AUTO_DJ_TEST_MASTER_DB")
	if src == "" {
		t.Skip("set AUTO_DJ_TEST_MASTER_DB to a copy of master.db")
	}
	key, err := RekordboxKey()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	plain, again := filepath.Join(dir, "plain.db"), filepath.Join(dir, "again.db")
	if err := Decrypt(src, plain, key); err != nil {
		t.Fatal(err)
	}
	salt, err := ReadSalt(src)
	if err != nil {
		t.Fatal(err)
	}
	ivs, err := PageIVs(src)
	if err != nil {
		t.Fatal(err)
	}
	if err := EncryptWithIVs(plain, again, key, salt, ivs); err != nil {
		t.Fatal(err)
	}
	a, _ := os.ReadFile(src)
	b, _ := os.ReadFile(again)
	if !bytes.Equal(a, b) {
		i := 0
		for i < min(len(a), len(b)) && a[i] == b[i] {
			i++
		}
		t.Fatalf("differs at byte %d (page %d)", i, i/PageSize+1)
	}
}
