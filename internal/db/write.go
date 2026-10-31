// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package db

import (
	"bytes"
	"crypto/rand"
	"database/sql"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/google/uuid"

	"github.com/bitwise-media-group/auto-dj/internal/sqlcipher"
)

// Stats is a write's outcome: an ordered set of counters and lists, printed as JSON.
type Stats struct {
	keys []string
	vals map[string]any
}

// NewStats starts a Stats with the given keys in order, each set to its initial value.
func NewStats(kv ...any) *Stats {
	s := &Stats{vals: map[string]any{}}
	for i := 0; i+1 < len(kv); i += 2 {
		s.Set(kv[i].(string), kv[i+1])
	}
	return s
}

// Set sets key k (appending it if new).
func (s *Stats) Set(k string, v any) {
	if _, ok := s.vals[k]; !ok {
		s.keys = append(s.keys, k)
	}
	s.vals[k] = v
}

// Add increments the integer counter k by n.
func (s *Stats) Add(k string, n int) {
	v, _ := s.vals[k].(int)
	s.Set(k, v+n)
}

// Append adds v to the string list k.
func (s *Stats) Append(k, v string) {
	l, _ := s.vals[k].([]string)
	s.Set(k, append(l, v))
}

// Get returns key k's value.
func (s *Stats) Get(k string) any { return s.vals[k] }

// Update copies o's keys into s.
func (s *Stats) Update(o *Stats) {
	for _, k := range o.keys {
		s.Set(k, o.vals[k])
	}
}

// MarshalJSON keeps the keys in insertion order.
func (s *Stats) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, k := range s.keys {
		if i > 0 {
			b.WriteByte(',')
		}
		kb, _ := json.Marshal(k)
		v := s.vals[k]
		if l, ok := v.([]string); ok && l == nil {
			v = []string{}
		}
		vb, err := json.Marshal(v)
		if err != nil {
			return nil, err
		}
		b.Write(kb)
		b.WriteByte(':')
		b.Write(vb)
	}
	b.WriteByte('}')
	return b.Bytes(), nil
}

// String renders the stats as indented JSON.
func (s *Stats) String() string {
	b, err := MarshalJSON(s)
	if err != nil {
		return err.Error()
	}
	return string(b)
}

// ApplyFunc writes into the open working copy inside one transaction.
type ApplyFunc func(tx *sql.Tx) (*Stats, error)

// now is djmdCue/djmdSongPlaylist's timestamp format: UTC with milliseconds.
func now() string {
	return time.Now().UTC().Format("2006-01-02 15:04:05.000") + " +00:00"
}

// idSource hands out unused random djmdCue IDs (1 .. 2^32-1, deleted rows included).
type idSource map[string]bool

func newIDSource(tx *sql.Tx) (idSource, error) {
	rows, err := tx.Query("select ID from djmdCue")
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	used := idSource{}
	for rows.Next() {
		var id sql.NullString
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		used[id.String] = true
	}
	return used, rows.Err()
}

func (u idSource) next() (string, error) {
	for {
		var b [4]byte
		if _, err := rand.Read(b[:]); err != nil {
			return "", err
		}
		n := binary.LittleEndian.Uint32(b[:])
		if n == 0 {
			continue
		}
		id := fmt.Sprint(n)
		if !u[id] {
			u[id] = true
			return id, nil
		}
	}
}

// cueRow is one djmdCue insert; nil pointers are NULL.
type cueRow struct {
	content           string
	contentUUID       any // NULL when the track has no UUID
	inMS, outMS, kind int
	color             int
	comment           string
	cti, al, bls, cms *int
}

const insertCue = `insert into djmdCue (ID,ContentID,InMsec,InFrame,InMpegFrame,InMpegAbs,OutMsec,
                OutFrame,OutMpegFrame,OutMpegAbs,Kind,Color,ColorTableIndex,ActiveLoop,Comment,BeatLoopSize,
                CueMicrosec,InPointSeekInfo,OutPointSeekInfo,ContentUUID,UUID,rb_data_status,
                rb_local_data_status,rb_local_deleted,rb_local_synced,usn,rb_local_usn,created_at,updated_at)
                values (?,?,?,?,0,0,?,?,0,0,?,?,?,?,?,?,?,NULL,NULL,
                ?,?,0,0,0,0,NULL,NULL,?,?)`

func nullable(p *int) any {
	if p == nil {
		return nil
	}
	return *p
}

// frames converts milliseconds to the 150-per-second frame index Rekordbox stores.
func frames(ms int) int {
	return int(float64(ms*150) / 1000)
}

func (u idSource) insert(tx *sql.Tx, c cueRow, ts string) error {
	id, err := u.next()
	if err != nil {
		return err
	}
	outF := 0
	if c.outMS > 0 {
		outF = frames(c.outMS)
	}
	_, err = tx.Exec(insertCue, id, c.content, c.inMS, frames(c.inMS), c.outMS, outF, c.kind, c.color,
		nullable(c.cti), nullable(c.al), c.comment, nullable(c.bls), nullable(c.cms),
		c.contentUUID, uuid.NewString(), ts, ts)
	return err
}

// ------------------------------------------------------------------ safe write

// Backup copies master.db to backupDir/master.before-cues.<timestamp>.db and checks the copy.
func Backup(masterDB, backupDir string) (string, error) {
	if err := os.MkdirAll(backupDir, 0o755); err != nil {
		return "", err
	}
	dest := filepath.Join(backupDir, "master.before-cues."+time.Now().Format("20060102-150405")+".db")
	if err := copyFile(masterDB, dest); err != nil {
		return "", err
	}
	a, err := os.ReadFile(masterDB)
	if err != nil {
		return "", err
	}
	b, err := os.ReadFile(dest)
	if err != nil {
		return "", err
	}
	if !bytes.Equal(a, b) {
		return "", errors.New("backup verification failed")
	}
	return dest, nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()
	st, err := in.Stat()
	if err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, st.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return err
	}
	if err := out.Sync(); err != nil {
		_ = out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Chtimes(dst, time.Now(), st.ModTime())
}

func integrityCheck(q Querier) error {
	var ok string
	if err := q.QueryRow("pragma integrity_check").Scan(&ok); err != nil {
		return err
	}
	if ok != "ok" {
		return fmt.Errorf("integrity check failed after writing: %s", ok)
	}
	return nil
}

// applyPlain runs fn in one transaction on the plain database at path, checks integrity,
// folds the WAL back in and closes it.
func applyPlain(path string, fn ApplyFunc) (*Stats, error) {
	d, err := openPlain(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = d.Close() }()
	tx, err := d.Begin()
	if err != nil {
		return nil, err
	}
	stats, err := fn(tx)
	if err != nil {
		_ = tx.Rollback()
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	if err := integrityCheck(d); err != nil {
		return nil, err
	}
	if _, err := d.Exec("pragma wal_checkpoint(TRUNCATE)"); err != nil {
		return nil, err
	}
	return stats, d.Close()
}

// DryRun applies fn to a throwaway decrypted copy of masterDB and returns the stats.
func DryRun(masterDB string, fn ApplyFunc) (*Stats, error) {
	dir, err := os.MkdirTemp("", "auto-dj-dry-")
	if err != nil {
		return nil, err
	}
	defer func() { _ = os.RemoveAll(dir) }()
	plain, err := decryptTo(masterDB, dir)
	if err != nil {
		return nil, err
	}
	return applyPlain(plain, fn)
}

// SafeWrite backs up master.db, applies fn to a decrypted copy, re-encrypts it with the
// original salt, decrypts that again and checks it, then swaps it in, unless master.db
// changed meanwhile.
func SafeWrite(masterDB, backupDir string, fn ApplyFunc) (*Stats, error) {
	key, err := sqlcipher.RekordboxKey()
	if err != nil {
		return nil, err
	}
	return safeWrite(masterDB, backupDir, key, AssertSafeToWrite, fn)
}

// safeWrite is SafeWrite with the key and the safety check passed in (for tests).
func safeWrite(masterDB, backupDir, key string, guard func(string) error, fn ApplyFunc) (*Stats, error) {
	if err := guard(masterDB); err != nil {
		return nil, err
	}
	st, err := os.Stat(masterDB)
	if err != nil {
		return nil, err
	}
	before := st.ModTime()
	bak, err := Backup(masterDB, backupDir)
	if err != nil {
		return nil, err
	}
	dir, err := os.MkdirTemp("", "auto-dj-write-")
	if err != nil {
		return nil, err
	}
	defer func() { _ = os.RemoveAll(dir) }()
	plain := filepath.Join(dir, "master.db")
	if err := sqlcipher.Decrypt(masterDB, plain, key); err != nil {
		return nil, fmt.Errorf("decrypting %s: %w", masterDB, err)
	}
	stats, err := applyPlain(plain, fn)
	if err != nil {
		return nil, err
	}
	if w, err := os.Stat(plain + "-wal"); err == nil && w.Size() > 0 {
		return nil, errors.New("working copy left un-checkpointed WAL data; aborting before replace")
	}
	salt, err := sqlcipher.ReadSalt(masterDB)
	if err != nil {
		return nil, err
	}
	enc := filepath.Join(dir, "master.enc.db")
	if err := sqlcipher.Encrypt(plain, enc, key, salt); err != nil {
		return nil, err
	}
	check := filepath.Join(dir, "check.db")
	if err := sqlcipher.Decrypt(enc, check, key); err != nil {
		return nil, fmt.Errorf("re-encrypted copy does not decrypt: %w", err)
	}
	if err := checkPlain(check); err != nil {
		return nil, fmt.Errorf("re-encrypted copy: %w", err)
	}
	if st, err := os.Stat(masterDB); err != nil || !st.ModTime().Equal(before) {
		return nil, errors.New("master.db changed while writing; nothing was replaced")
	}
	if err := replaceContents(enc, masterDB); err != nil {
		return nil, err
	}
	stats.Set("backup", bak)
	return stats, nil
}

func checkPlain(path string) error {
	d, err := openPlain(path)
	if err != nil {
		return err
	}
	defer func() { _ = d.Close() }()
	return integrityCheck(d)
}

// replaceContents overwrites dst with src's bytes in place (dst keeps its mode).
func replaceContents(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(dst, os.O_WRONLY|os.O_TRUNC, 0)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}
