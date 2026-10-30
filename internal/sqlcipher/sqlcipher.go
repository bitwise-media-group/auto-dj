// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package sqlcipher decrypts and encrypts SQLCipher 4 database files (the format of
// Rekordbox's master.db) in pure Go, so the plain SQLite file can be opened with a
// cgo-free driver.
//
// SQLCipher 4 defaults: the key is a passphrase run through PBKDF2-HMAC-SHA512
// (256000 iterations) with the first 16 bytes of the file as salt; the HMAC key is
// PBKDF2(encryption key, salt XOR 0x3a, 2 iterations). Pages are 4096 bytes and keep
// 80 reserve bytes at the end (IV 16 + HMAC-SHA512 64). Each page is AES-256-CBC
// encrypted, then authenticated with HMAC-SHA512 over ciphertext ‖ IV ‖ page number
// (uint32 little-endian). Page 1 carries the salt in place of the SQLite header string.
package sqlcipher

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha512"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
)

const (
	// PageSize is SQLCipher 4's default page size.
	PageSize = 4096
	// Reserve is the bytes at the end of each page holding the IV and HMAC.
	Reserve = ivSize + hmacSize
	// SaltSize is the length of the KDF salt at the start of the file.
	SaltSize = 16

	ivSize     = 16
	hmacSize   = 64
	keySize    = 32
	kdfIter    = 256000
	fastKDF    = 2
	hmacMask   = 0x3a
	headerSize = 16
)

// sqliteHeader is the plain SQLite file's magic string, which page 1 replaces with the salt.
var sqliteHeader = []byte("SQLite format 3\x00")

// ErrHMAC means a page failed authentication: wrong key, or a damaged file.
var ErrHMAC = errors.New("sqlcipher: HMAC check failed (wrong key or corrupt file)")

type keys struct {
	enc, mac []byte
}

var (
	kdfMu    sync.Mutex
	kdfCache = map[string]keys{}
)

// deriveKeys runs the (slow) passphrase KDF once per key and salt per process.
func deriveKeys(pass string, salt []byte) (keys, error) {
	if len(salt) != SaltSize {
		return keys{}, fmt.Errorf("sqlcipher: salt must be %d bytes", SaltSize)
	}
	id := pass + "\x00" + string(salt)
	kdfMu.Lock()
	defer kdfMu.Unlock()
	if k, ok := kdfCache[id]; ok {
		return k, nil
	}
	enc, err := pbkdf2.Key(sha512.New, pass, salt, kdfIter, keySize)
	if err != nil {
		return keys{}, err
	}
	msalt := make([]byte, SaltSize)
	for i, b := range salt {
		msalt[i] = b ^ hmacMask
	}
	mac, err := pbkdf2.Key(sha512.New, string(enc), msalt, fastKDF, keySize)
	if err != nil {
		return keys{}, err
	}
	k := keys{enc: enc, mac: mac}
	kdfCache[id] = k
	return k, nil
}

func pageHMAC(macKey, data []byte, pgno uint32) []byte {
	h := hmac.New(sha512.New, macKey)
	h.Write(data)
	var n [4]byte
	binary.LittleEndian.PutUint32(n[:], pgno)
	h.Write(n[:])
	return h.Sum(nil)
}

// ReadSalt returns the KDF salt (the first 16 bytes) of an encrypted database.
func ReadSalt(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	salt := make([]byte, SaltSize)
	if _, err := io.ReadFull(f, salt); err != nil {
		return nil, fmt.Errorf("sqlcipher: reading salt of %s: %w", path, err)
	}
	return salt, nil
}

func readPages(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(data) == 0 || len(data)%PageSize != 0 {
		return nil, fmt.Errorf("sqlcipher: %s is %d bytes, not a whole number of %d-byte pages", path, len(data), PageSize)
	}
	return data, nil
}

// Decrypt writes the plain SQLite database for the SQLCipher file src to dst. Every page's
// HMAC is checked. The plain file keeps the 80 reserve bytes per page (its header says so),
// filled with the page's IV and HMAC as SQLCipher itself does.
func Decrypt(src, dst, key string) error {
	data, err := readPages(src)
	if err != nil {
		return err
	}
	k, err := deriveKeys(key, data[:SaltSize])
	if err != nil {
		return err
	}
	block, err := aes.NewCipher(k.enc)
	if err != nil {
		return err
	}
	out := make([]byte, len(data))
	for p := 0; p < len(data)/PageSize; p++ {
		pgno := uint32(p + 1)
		in, o := data[p*PageSize:(p+1)*PageSize], out[p*PageSize:(p+1)*PageSize]
		if allZero(in) { // a page SQLite never wrote (short read): stays zero
			continue
		}
		off := 0
		if pgno == 1 {
			off = headerSize
			copy(o, sqliteHeader)
		}
		size := PageSize - Reserve
		ct, iv, mac := in[off:size], in[size:size+ivSize], in[size+ivSize:]
		want := pageHMAC(k.mac, in[off:size+ivSize], pgno)
		if !hmac.Equal(want, mac) {
			return fmt.Errorf("%w (page %d)", ErrHMAC, pgno)
		}
		cipher.NewCBCDecrypter(block, iv).CryptBlocks(o[off:size], ct)
		copy(o[size:], iv)
		copy(o[size+ivSize:], want)
	}
	if p1 := out[:PageSize]; int(p1[20]) != Reserve {
		return fmt.Errorf("sqlcipher: decrypted header of %s has reserve %d, expected %d", src, p1[20], Reserve)
	}
	return os.WriteFile(dst, out, 0o600)
}

// Encrypt writes src (a plain SQLite database with 4096-byte pages and 80 reserve bytes)
// to dst as a SQLCipher 4 file keyed with key and salt, using a fresh random IV per page.
func Encrypt(src, dst, key string, salt []byte) error {
	return EncryptWithIVs(src, dst, key, salt, nil)
}

// EncryptWithIVs is Encrypt with each page's IV taken from iv(pgno) when it returns 16
// bytes (random otherwise). Re-encrypting a decrypted file with its original IVs gives
// the original file byte for byte, which is how the round trip is tested.
func EncryptWithIVs(src, dst, key string, salt []byte, iv func(pgno uint32) []byte) error {
	data, err := readPages(src)
	if err != nil {
		return err
	}
	if !bytes.Equal(data[:headerSize], sqliteHeader) {
		return fmt.Errorf("sqlcipher: %s is not a plain SQLite database", src)
	}
	if int(data[20]) != Reserve {
		return fmt.Errorf("sqlcipher: %s has %d reserve bytes per page, need %d", src, data[20], Reserve)
	}
	if ps := int(binary.BigEndian.Uint16(data[16:18])); ps != PageSize {
		return fmt.Errorf("sqlcipher: %s has page size %d, need %d", src, ps, PageSize)
	}
	k, err := deriveKeys(key, salt)
	if err != nil {
		return err
	}
	block, err := aes.NewCipher(k.enc)
	if err != nil {
		return err
	}
	out := make([]byte, len(data))
	size := PageSize - Reserve
	for p := 0; p < len(data)/PageSize; p++ {
		pgno := uint32(p + 1)
		in, o := data[p*PageSize:(p+1)*PageSize], out[p*PageSize:(p+1)*PageSize]
		off := 0
		if pgno == 1 {
			off = headerSize
			copy(o, salt)
		}
		var v []byte
		if iv != nil {
			v = iv(pgno)
		}
		if len(v) != ivSize {
			v = make([]byte, ivSize)
			if _, err := rand.Read(v); err != nil {
				return err
			}
		}
		copy(o[size:], v)
		cipher.NewCBCEncrypter(block, v).CryptBlocks(o[off:size], in[off:size])
		copy(o[size+ivSize:], pageHMAC(k.mac, o[off:size+ivSize], pgno))
	}
	return writeFileSync(dst, out)
}

// PageIVs returns a lookup of each page's IV in the encrypted file path (for EncryptWithIVs).
func PageIVs(path string) (func(pgno uint32) []byte, error) {
	data, err := readPages(path)
	if err != nil {
		return nil, err
	}
	return func(pgno uint32) []byte {
		p := int(pgno) - 1
		if p < 0 || (p+1)*PageSize > len(data) {
			return nil
		}
		start := p*PageSize + PageSize - Reserve
		return data[start : start+ivSize]
	}, nil
}

func allZero(b []byte) bool {
	for _, x := range b {
		if x != 0 {
			return false
		}
	}
	return true
}

func writeFileSync(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
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
