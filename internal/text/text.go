// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package text has the string formatting the reports need, counted in characters like
// Python's slicing and format widths rather than in bytes.
package text

import (
	"strings"
	"unicode/utf8"
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
