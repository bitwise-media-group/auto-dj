// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package sqlcipher

import (
	"bytes"
	"compress/zlib"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// keyBlob is master.db's key as pyrekordbox ships it (pyrekordbox/db6/database.py BLOB):
// base85 (RFC 1924 alphabet), XORed with blobKey, zlib-compressed.
const (
	keyBlob = "PN_Pq^*N>(JYe*u^8;Yg76HuZ<mR13S?=>)b9;DpoTXV(6ItkU`}8*m6tx_I{Solh_N#dfe{v="
	blobKey = "657f48f84c437cc1"
	// keyPrefix is how every Rekordbox 6/7 master.db key starts.
	keyPrefix = "402fd"
)

// RekordboxKey returns master.db's key: REKORDBOX_DB_KEY when set, else the known key.
func RekordboxKey() (string, error) {
	if k := os.Getenv("REKORDBOX_DB_KEY"); k != "" {
		if !strings.HasPrefix(k, keyPrefix) {
			return "", errors.New("REKORDBOX_DB_KEY doesn't look like a Rekordbox database key")
		}
		return k, nil
	}
	return deobfuscate(keyBlob)
}

func deobfuscate(blob string) (string, error) {
	data, err := b85decode(blob)
	if err != nil {
		return "", err
	}
	for i := range data {
		data[i] ^= blobKey[i%len(blobKey)]
	}
	r, err := zlib.NewReader(bytes.NewReader(data))
	if err != nil {
		return "", fmt.Errorf("sqlcipher: key blob: %w", err)
	}
	defer func() { _ = r.Close() }()
	out, err := io.ReadAll(r)
	if err != nil {
		return "", fmt.Errorf("sqlcipher: key blob: %w", err)
	}
	return string(out), nil
}

const b85alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~"

// b85decode is Python's base64.b85decode (RFC 1924 alphabet, short final group padded with '~').
func b85decode(s string) ([]byte, error) {
	var rev [256]int
	for i := range rev {
		rev[i] = -1
	}
	for i := 0; i < len(b85alphabet); i++ {
		rev[b85alphabet[i]] = i
	}
	pad := (5 - len(s)%5) % 5
	s += strings.Repeat("~", pad)
	out := make([]byte, 0, len(s)/5*4)
	for i := 0; i < len(s); i += 5 {
		var acc uint64
		for _, c := range []byte(s[i : i+5]) {
			v := rev[c]
			if v < 0 {
				return nil, fmt.Errorf("sqlcipher: bad base85 character %q", c)
			}
			acc = acc*85 + uint64(v)
		}
		if acc > 0xffffffff {
			return nil, errors.New("sqlcipher: base85 overflow")
		}
		out = append(out, byte(acc>>24), byte(acc>>16), byte(acc>>8), byte(acc))
	}
	return out[:len(out)-pad], nil
}
