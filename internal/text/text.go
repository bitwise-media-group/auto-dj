// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package text has the string formatting the reports need, counted in characters like
// Python's slicing and format widths rather than in bytes.
package text

import (
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

// Truncate keeps the first n characters of s (Python's s[:n]).
func Truncate(s string, n int) string {
	i := 0
	for j := range s {
		if i == n {
			return s[:j]
		}
		i++
	}
	return s
}

// PadRight pads s with spaces to n characters (Python's f"{s:<n}").
func PadRight(s string, n int) string {
	if c := utf8.RuneCountInString(s); c < n {
		return s + strings.Repeat(" ", n-c)
	}
	return s
}

// PadLeft right-aligns s in n characters (Python's f"{s:>n}").
func PadLeft(s string, n int) string {
	if c := utf8.RuneCountInString(s); c < n {
		return strings.Repeat(" ", n-c) + s
	}
	return s
}

// Slug makes a folder name from s: lower case, each run of anything but letters and digits
// turned into one '-' ("Melodic Dark (Live)" -> "melodic-dark-live"); "set" when nothing is left.
func Slug(s string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			if dash && b.Len() > 0 {
				b.WriteByte('-')
			}
			b.WriteRune(r)
			dash = false
		} else {
			dash = true
		}
	}
	if b.Len() == 0 {
		return "set"
	}
	return b.String()
}

// FileName makes s safe as one path element on macOS, Windows and Linux: Unicode NFC, runs of
// white space collapsed to one space, path and reserved characters (/ \ : * ? " < > |) and
// control characters replaced by '_', no leading dot or trailing dots and spaces, at most
// 200 bytes (cut on a character boundary).
func FileName(s string) string {
	var b strings.Builder
	space := false
	for _, r := range norm.NFC.String(s) {
		switch {
		case unicode.IsSpace(r):
			space = b.Len() > 0
			continue
		case strings.ContainsRune(`/\:*?"<>|`, r) || unicode.IsControl(r):
			r = '_'
		}
		if space {
			b.WriteByte(' ')
			space = false
		}
		b.WriteRune(r)
	}
	out := strings.TrimRight(strings.TrimLeft(b.String(), "."), ". ")
	for len(out) > 200 {
		_, n := utf8.DecodeLastRuneInString(out)
		out = out[:len(out)-n]
	}
	if out == "" {
		return "_"
	}
	return out
}
