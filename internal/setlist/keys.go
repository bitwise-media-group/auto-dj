// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

package setlist

import (
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
)

// notes maps note names (upper-cased) to pitch classes.
var notes = map[string]int{
	"C": 0, "C#": 1, "DB": 1, "D": 2, "D#": 3, "EB": 3, "E": 4, "F": 5, "F#": 6, "GB": 6,
	"G": 7, "G#": 8, "AB": 8, "A": 9, "A#": 10, "BB": 10, "B": 11,
}

// minorCamelot is the Camelot number of a minor key by tonic pitch class (8A = Am); a major
// key has its relative minor's number.
var minorCamelot = map[int]int{9: 8, 4: 9, 11: 10, 6: 11, 1: 12, 8: 1, 3: 2, 10: 3, 5: 4, 0: 5, 7: 6, 2: 7}

var (
	reCamelot = regexp.MustCompile(`^(\d{1,2})([AB])$`)
	reKey     = regexp.MustCompile(`^([A-Ga-g])([#b]?)\s*(m|min|minor)?$`)
)

// Camelot is a key on the Camelot wheel: number and letter (A minor, B major).
type Camelot struct {
	N      int
	Letter string
}

// ToCamelot parses 'F#m' / 'Abm' / 'Eb' / '9A'; ok is false for an unknown key.
func ToCamelot(key string) (Camelot, bool) {
	k := strings.TrimSpace(key)
	if k == "" {
		return Camelot{}, false
	}
	if m := reCamelot.FindStringSubmatch(strings.ToUpper(k)); m != nil {
		n, _ := strconv.Atoi(m[1])
		return Camelot{n, m[2]}, true
	}
	m := reKey.FindStringSubmatch(k)
	if m == nil {
		return Camelot{}, false
	}
	pc, ok := notes[strings.ToUpper(m[1]+m[2])]
	if !ok {
		return Camelot{}, false
	}
	if m[3] != "" {
		return Camelot{minorCamelot[pc], "A"}, true
	}
	return Camelot{minorCamelot[(pc+9)%12], "B"}, true // major: same number as its relative minor
}

// KeyMove says whether mixing from key a into key b is harmonic: ok, a description and a
// cost. Mixed In Key's harmonic chart: same key, Camelot +-1, relative major/minor (cost 0);
// energy boost +-2 semitones (Camelot +-2, cost 1) and +-1 semitone (Camelot +-7, cost 2).
func KeyMove(a, b string) (bool, string, int) {
	ca, okA := ToCamelot(a)
	cb, okB := ToCamelot(b)
	if !okA || !okB {
		return true, "key unknown", 1
	}
	d := pyMod(cb.N-ca.N, 12)
	if d > 6 {
		d -= 12
	}
	if ca.Letter == cb.Letter {
		switch {
		case d == 0:
			return true, "same key", 0
		case abs(d) == 1:
			return true, fmt.Sprintf("Camelot %+d", d), 0
		case abs(d) == 2:
			return true, fmt.Sprintf("%+d semitones (energy boost)", d), 1
		case abs(d) == 5: // +-7 Camelot steps == +-1 semitone
			s := "-1"
			if d == -5 {
				s = "+1"
			}
			return true, s + " semitone (energy boost)", 2
		}
		return false, fmt.Sprintf("clash (Camelot %+d)", d), 100
	}
	if d == 0 {
		return true, "relative major/minor", 0
	}
	return false, fmt.Sprintf("clash (%d%s -> %d%s)", ca.N, ca.Letter, cb.N, cb.Letter), 100
}

// OrderItem is what SuggestOrder needs per track.
type OrderItem struct {
	Key string
	BPM float64
}

// SuggestOrder finds the cheapest path through all tracks (Held-Karp DP). Cost = key-move
// cost (clash 100, energy boost 1-2) + 0.02 per BPM of tempo jump + 0.5 for every pair of
// neighbours that isn't already next to each other in your order, so the suggestion changes
// as little as possible. It returns the order and its total key cost.
func SuggestOrder(items []OrderItem, keepFirst bool) ([]int, int) {
	n := len(items)
	keyCost := func(order []int) int {
		total := 0
		for i := 0; i+1 < len(order); i++ {
			_, _, c := KeyMove(items[order[i]].Key, items[order[i+1]].Key)
			total += c
		}
		return total
	}
	if n <= 2 {
		order := make([]int, n)
		for i := range order {
			order[i] = i
		}
		return order, keyCost(order)
	}
	c := func(i, j int) float64 {
		_, _, k := KeyMove(items[i].Key, items[j].Key)
		v := float64(k) + 0.02*math.Abs(items[i].BPM-items[j].BPM)
		if j != i+1 { // keep your existing neighbours where possible
			v += 0.5
		}
		return v
	}
	if n > 14 { // exact search gets slow; improve your order by moving one track at a time
		order := localSearch(n, c, keepFirst)
		return order, keyCost(order)
	}
	order := heldKarp(n, c, keepFirst)
	return order, keyCost(order)
}

// heldKarp is the exact cheapest path through all n tracks (from track 0 when keepFirst;
// starting elsewhere costs 0.5).
func heldKarp(n int, c func(i, j int) float64, keepFirst bool) []int {
	size := 1 << n
	inf := math.Inf(1)
	dp := make([]float64, size*n)
	parent := make([]int, size*n)
	for i := range dp {
		dp[i], parent[i] = inf, -1
	}
	for s := range n {
		switch {
		case s == 0:
			dp[(1<<s)*n+s] = 0
		case !keepFirst:
			dp[(1<<s)*n+s] = 0.5
		}
	}
	for mask := range size {
		for j := range n {
			v := dp[mask*n+j]
			if v == inf || (mask>>j)&1 == 0 {
				continue
			}
			for nxt := range n {
				if (mask>>nxt)&1 == 1 {
					continue
				}
				nm := mask | 1<<nxt
				if cost := v + c(j, nxt); cost < dp[nm*n+nxt] {
					dp[nm*n+nxt] = cost
					parent[nm*n+nxt] = j
				}
			}
		}
	}
	full := size - 1
	end := 0
	for j := 1; j < n; j++ {
		if dp[full*n+j] < dp[full*n+end] {
			end = j
		}
	}
	var rev []int
	for mask, cur := full, end; cur != -1; {
		rev = append(rev, cur)
		prev := parent[mask*n+cur]
		mask ^= 1 << cur
		cur = prev
	}
	order := make([]int, len(rev))
	for i, v := range rev {
		order[len(rev)-1-i] = v
	}
	return order
}

func localSearch(n int, c func(i, j int) float64, keepFirst bool) []int {
	order := make([]int, n)
	for i := range order {
		order[i] = i
	}
	cost := func(o []int) float64 {
		s := 0.0
		for i := 0; i+1 < len(o); i++ {
			s += c(o[i], o[i+1])
		}
		if o[0] != 0 {
			s += 0.5
		}
		return s
	}
	best := cost(order)
	start := 0
	if keepFirst {
		start = 1
	}
	for improved := true; improved; {
		improved = false
		for i := start; i < n; i++ {
			for j := start; j < n; j++ {
				if i == j {
					continue
				}
				o := make([]int, 0, n)
				o = append(o, order[:i]...)
				o = append(o, order[i+1:]...)
				o = append(o[:j], append([]int{order[i]}, o[j:]...)...)
				if v := cost(o); v < best-1e-9 {
					order, best, improved = o, v, true
				}
			}
		}
	}
	return order
}

// pyMod is Python's % (the result has the divisor's sign).
func pyMod(a, b int) int {
	m := a % b
	if m != 0 && (m < 0) != (b < 0) {
		m += b
	}
	return m
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}
