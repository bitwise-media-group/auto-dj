// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

// Package config holds paths, the cue template and the rule thresholds.
//
// Every threshold here was tuned against Deavon's 51 hand-cued tracks on 2026-10-14
// (see docs/DECISIONS.md for what each one does and how it scored). Change them in one
// place and re-run `adj evaluate` to see the effect before writing anything.
package config

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode"
)

// ------------------------------------------------------------------ paths

// DefaultRBDir holds master.db and share/.
func DefaultRBDir() string {
	return filepath.Join(home(), "Library", "Pioneer", "rekordbox")
}

// DefaultWorkDir is the feature cache and plan output folder (ADJ_WORK overrides it).
func DefaultWorkDir() string {
	if w := os.Getenv("ADJ_WORK"); w != "" {
		return w
	}
	return filepath.Join(home(), ".cache", "adj")
}

func home() string {
	h, err := os.UserHomeDir()
	if err != nil {
		return "."
	}
	return h
}

// PathMap is an optional audio path remap for a library mounted somewhere else (e.g. a VM):
// ADJ_PATH_MAP="/Users/me/Music=/mnt/Music;/Volumes/USB=/mnt/usb".
var PathMap = parsePathMap(os.Getenv("ADJ_PATH_MAP"))

func parsePathMap(s string) [][2]string {
	var out [][2]string
	for _, p := range strings.Split(s, ";") {
		if src, dst, ok := strings.Cut(p, "="); ok {
			out = append(out, [2]string{src, dst})
		}
	}
	return out
}

// CloudDirs are where Cloud Library Sync tracks live. Their FolderPath is relative to the
// cloud drive's rekordbox folder ('/contents_<device id>/artist/album/file'); the files are
// in e.g. ~/Library/CloudStorage/Dropbox-<team>/<member>/rekordbox. ADJ_CLOUD_DIR overrides.
var CloudDirs = cloudDirs()

func cloudDirs() []string {
	if d := os.Getenv("ADJ_CLOUD_DIR"); d != "" {
		return []string{d}
	}
	set := map[string]bool{}
	for _, pat := range []string{"Library/CloudStorage/*/rekordbox", "Library/CloudStorage/*/*/rekordbox"} {
		m, _ := filepath.Glob(filepath.Join(home(), pat))
		for _, p := range m {
			set[p] = true
		}
	}
	out := make([]string, 0, len(set))
	for p := range set {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// MapPath applies PathMap, then resolves Cloud Library Sync paths against CloudDirs.
func MapPath(path string) string {
	for _, m := range PathMap {
		if path != "" && strings.HasPrefix(path, m[0]) {
			return m[1] + path[len(m[0]):]
		}
	}
	if strings.HasPrefix(path, "/contents_") {
		for _, d := range CloudDirs {
			p := filepath.Join(d, path[1:])
			if _, err := os.Stat(p); err == nil {
				return p
			}
		}
	}
	return path
}

// Paths are the folders one run works with.
type Paths struct {
	RBDir   string
	WorkDir string
}

// MasterDB is Rekordbox's encrypted database.
func (p Paths) MasterDB() string { return filepath.Join(p.RBDir, "master.db") }

// ShareDir holds the ANLZ analysis files.
func (p Paths) ShareDir() string { return filepath.Join(p.RBDir, "share") }

// FeatureDir is the per-track audio feature cache.
func (p Paths) FeatureDir() string { return filepath.Join(p.WorkDir, "features") }

// BackupDir holds master.db backups, the ledger and the transition cache.
func (p Paths) BackupDir() string { return filepath.Join(filepath.Dir(p.RBDir), "_cue_work") }

// Transitions is the E/G transition cache (pairs package).
func (p Paths) Transitions() string { return filepath.Join(p.BackupDir(), "transitions.json") }

// Ledger lists the tracks this tool has cued.
func (p Paths) Ledger() string { return filepath.Join(p.BackupDir(), "applied-tracks.json") }

// ------------------------------------------------------------------ template

// Kind maps a slot to Rekordbox's djmdCue.Kind: 0 = memory cue, hot cues A..H =
// 1,2,3,5,6,7,8,9 (4 is skipped).
var Kind = map[string]int{"MEM": 0, "A": 1, "B": 2, "C": 3, "D": 5, "E": 6, "F": 7, "G": 8, "H": 9}

// HotSlot is one entry of the hot cue template.
type HotSlot struct{ Name, Slot string }

// HotTemplate maps cue names to hot cue slots, in template order. E, F, G are Deavon's
// personal mix-pairing notes (other track names); never written by `plan`.
var HotTemplate = []HotSlot{
	{"IN", "A"},
	{"BRIDGE", "B"}, // a.k.a. the breakdown
	{"DROP", "C"},   // first drop after the bridge
	{"OUT", "D"},
	{"EMERGENCY", "H"}, // active loop in the outro
}

// MemoryColorOrder lists MemoryColor's names in the order messages show them.
var MemoryColorOrder = []string{
	"START", "IN", "LATE",
	"BASS SWAP", "BASS SWAP IN", "BASS SWAP OUT",
	"DROP", "VOCAL",
	"FILTER", "FILTER IN", "FILTER OUT",
	"JUMP",
	"CUT", "CUT IN", "CUT OUT",
	"SYNC", "SYNC IN", "SYNC OUT",
}

// MemoryColor is djmdCue.Color for memory cues: 0 pink, 1 red, 2 orange, 3 yellow, 4 green,
// 5 aqua, 6 blue, 7 purple (one below the djmdColor IDs used for track colours; checked
// against Rekordbox's cue list on 2026-10-16). `set` also recolours existing memory cues
// with these names on every track in the playlist.
var MemoryColor = map[string]int{
	"START": 1, "IN": 1, "LATE": 1, // red
	"BASS SWAP": 2, "BASS SWAP IN": 2, "BASS SWAP OUT": 2, // orange
	"DROP":   4,                                  // green
	"VOCAL":  3,                                  // yellow
	"FILTER": 7, "FILTER IN": 7, "FILTER OUT": 7, // purple
	"JUMP": 0,                            // pink
	"CUT":  6, "CUT IN": 6, "CUT OUT": 6, // blue
	"SYNC":    1,                // red
	"SYNC IN": 5, "SYNC OUT": 5, // aqua
}

// `set` names transition markers by side: "<marker> IN" on the incoming track, "<marker> OUT"
// on the outgoing one (BASS SWAP, FILTER, CUT, SYNC), so a track's OUT markers are easy to
// find and replace.

// memoryRename holds old memory cue names `set` renames (memory cues only: OUT stays the D
// hot cue name). FILTER OUT OUT / IN are the markers from before FILTER OUT became FILTER.
var memoryRename = map[string]string{
	"FILTER DOWN":    "FILTER",
	"LOW PASS":       "FILTER",
	"FILTER OUT OUT": "FILTER OUT",
	"FILTER OUT IN":  "FILTER IN",
	"OUT":            "CUT OUT",
}

// memoryRenameWord renames memory cues with these words anywhere in the name
// ('CUT-OUT RES', 'LONG CUT-OUT RES' -> 'CUT OUT'), in this order.
var memoryRenameWord = [][2]string{{"CUT-OUT", "CUT OUT"}, {"CUT-IN", "CUT IN"}}

// Names `set` renames whatever label follows them; hot cues only get the JUMP one
// ('JUMP TO DROP' -> 'JUMP', so a track's jump pads are all called JUMP).
var (
	memoryRenamePrefix = [][2]string{{"JUMP", "JUMP"}}
	hotRenamePrefix    = [][2]string{{"JUMP", "JUMP"}}
)

// IsSpace is Python's str.isspace for one character.
func IsSpace(r rune) bool {
	return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f)
}

// Strip is Python's str.strip().
func Strip(s string) string { return strings.TrimFunc(s, IsSpace) }

// Norm is a cue name as compared everywhere: stripped and upper-cased.
func Norm(s string) string { return strings.ToUpper(Strip(s)) }

// RenameTo is the name `set --write` gives a cue (the renames, then the words, then the
// prefixes), or "" to keep it.
func RenameTo(name string, hot bool) string {
	n := Norm(name)
	if !hot {
		if to, ok := memoryRename[n]; ok {
			return to
		}
		for _, w := range memoryRenameWord {
			if hasWord(n, w[0]) {
				return w[1]
			}
		}
	}
	prefixes := memoryRenamePrefix
	if hot {
		prefixes = hotRenamePrefix
	}
	for _, p := range prefixes {
		if strings.HasPrefix(n, p[0]+" ") {
			return p[1]
		}
	}
	return ""
}

// hasWord reports whether w occurs in s delimited by whitespace or the ends of s
// (Python's re.search(rf"(^|\s){w}(\s|$)", s)).
func hasWord(s, w string) bool {
	for i := 0; ; {
		j := strings.Index(s[i:], w)
		if j < 0 {
			return false
		}
		j += i
		before := j == 0 || IsSpace(lastRune(s[:j]))
		end := j + len(w)
		after := end == len(s) || IsSpace(firstRune(s[end:]))
		if before && after {
			return true
		}
		i = j + 1
	}
}

func lastRune(s string) rune {
	r := []rune(s)
	return r[len(r)-1]
}

func firstRune(s string) rune {
	for _, r := range s {
		return r
	}
	return 0
}

// HotColor is the default hot cue colour.
const HotColor = -1

// EmergencyLoopBeats is the EMERGENCY loop length (the user uses 32, sometimes 64).
const EmergencyLoopBeats = 32

// Rules are the thresholds for the rules package. Units: beats (1-based beat index into the
// Rekordbox grid) and normalised bass level (0 = silence, ~1 = the track's loudest 5% of bass).
type Rules struct {
	InMin           int     // IN never earlier than beat 33 (8 bars) unless phrase says so
	InMax           int     // ... and never later than beat 129 (32 bars)
	BridgeMin       int     // breakdown shorter than this = no BRIDGE (user rule)
	BridgeBig       int     // a "real" breakdown is >= 64 beats
	BassLow         float64 // below this a phrase counts as "no bass"
	BassCont        float64 // a breakdown run continues while bass stays below this
	BassPresent     float64 // loop / OUT regions must have at least this much bass
	EmBack          int     // EMERGENCY targets ~68 beats before the last beat
	PhraseBonus     int     // preference (in beats) for real Rekordbox phrase starts
	DropOn          float64 // bass level after a drop
	DropOff         float64 // bass level before a drop
	DropPre         int     // beats of low bass needed before a memory DROP
	DropNeedsChorus bool
	BassSwapMin     float64 // minimum bass jump for a fallback BASS SWAP
}

// DefaultRules are the tuned thresholds.
var DefaultRules = Rules{
	InMin:           33,
	InMax:           129,
	BridgeMin:       16,
	BridgeBig:       64,
	BassLow:         0.35,
	BassCont:        0.45,
	BassPresent:     0.45,
	EmBack:          68,
	PhraseBonus:     8,
	DropOn:          0.7,
	DropOff:         0.4,
	DropPre:         32,
	DropNeedsChorus: true,
	BassSwapMin:     0.3,
}
