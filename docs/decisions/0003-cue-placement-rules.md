---
status: accepted
date: 2026-10-14
decision-makers: Deavon
---

# Place each cue with phrase-grid rules scored against the hand-cued tracks

## Context and Problem Statement

Given the grid, phrases and bass energy ([0002](0002-analysis-inputs.md)), where exactly should each template cue go?
The rules should land where the DJ would put the cue by hand, and changes to them need a way to be judged.

## Decision Drivers

- Hand cues almost always sit on a Rekordbox phrase start.
- Rule changes must be measurable against the DJ's own cues (`auto-dj evaluate`).

## Considered Options

- The rules below (`internal/rules`)
- EMERGENCY placed purely from "bass end − 64"
- OUT where the mids drop out (the stripped outro)
- The _longest_ breakdown as BRIDGE

## Decision Outcome

Chosen option: "The rules below", because they scored best against the hand-cued tracks.

All positions snap to a grid: Rekordbox phrase starts plus every 16 beats from the first downbeat.

1. **IN**: start of the first phrase after Rekordbox's Intro, clamped to beats 33–129 (else the first phrase start in
   that range, else beat 33).
2. **EMERGENCY**: find where the bass ends (last 16-beat window with bass ≥ 0.45). Pick the grid point nearest
   `last_beat − 68` (8-beat bonus for real phrase starts) such that the 32-beat loop has bass throughout, ends ≥ 8 beats
   before the end, and ends before the bass does.
3. **BRIDGE**: group consecutive non-intro/outro phrases with low bass into "breakdown runs" (start below 0.35, or a
   Down phrase below 0.6; continue while below 0.45). Keep runs after the first Chorus, starting in the first 75% of the
   track, that are followed by a Chorus before EMERGENCY. Take the **first run ≥ 64 beats**, unless a later run is at
   least twice as long. Fallbacks: a mid-track Rekordbox Down phrase, then the lowest-bass window. **Runs < 16 beats =
   no bridge.**
4. **DROP**: first Chorus phrase at or after the end of the breakdown. With no bridge: the first point after IN where
   bass jumps from < 0.35 to ≥ 0.7, else the first Chorus after IN.
5. **OUT**: grid point with bass present, 32–128 beats before EMERGENCY, closest to 64 before.
6. **Ordering fix for short edits**: if OUT ≤ DROP, move OUT later; if there's no room, move EMERGENCY later.
7. **Memory START**: first downbeat.
8. **BASS SWAP**: the first "bass entry" (≥ 0.7 after 16 beats ≤ 0.4) between IN+16 and the bridge; otherwise the
   biggest sub/low-mid jump ≥ 0.3 in that window; otherwise none.
9. **Memory DROPs**: bass entries after the BASS SWAP, preceded by ≥ 32 low-bass beats, on a Chorus phrase, before OUT;
   plus the hot cue DROP. Drops closer than 32 beats are merged.

Thresholds live only in `internal/config` (`DefaultRules`).

### Consequences

- Good, because most cues land on the hand-placed beat or one phrase away (see Confirmation).
- Bad, because misses are mostly one phrase (16–32 beats) early or late, which is down to taste rather than the wrong
  section. IN is the most subjective: the DJ sometimes uses beat 1 and sometimes 65/97/129.

### Confirmation

`auto-dj evaluate` scores each rule against the hand-cued (manual) tracks, comparing each predicted beat to the
hand-placed one. Change thresholds only in `DefaultRules`, re-run it and compare with the tables below.

Scored on the 51 hand-cued tracks (2026-10-14):

| Cue       | n   | exact | ≤ 16 beats | ≤ 32 beats |
| --------- | --- | ----- | ---------- | ---------- |
| IN        | 42  | 18    | 21         | 33         |
| BRIDGE    | 41  | 24    | 30         | 31         |
| DROP      | 41  | 25    | 28         | 28         |
| OUT       | 42  | 14    | 20         | 33         |
| EMERGENCY | 36  | 12    | 21         | 29         |

Memory DROP: 33 hit, 14 missed, 29 extra (many of the extras are real drops the DJ simply didn't mark). BASS SWAP: only
15 hand examples, which aren't consistent with each other.

Re-scored on 2026-10-30, when the library had 65 hand-cued tracks (the Python and Go versions give identical output):

| Cue       | n   | exact | ≤ 16 beats | ≤ 32 beats | not placed |
| --------- | --- | ----- | ---------- | ---------- | ---------- |
| IN        | 65  | 33    | 35         | 51         | 0          |
| BRIDGE    | 57  | 36    | 44         | 45         | 2          |
| DROP      | 65  | 42    | 45         | 45         | 1          |
| OUT       | 65  | 24    | 31         | 44         | 0          |
| EMERGENCY | 63  | 30    | 40         | 53         | 0          |

Memory DROP: 71 hit, 34 missed, 37 extra.

## Pros and Cons of the Options

### EMERGENCY purely from "bass end − 64"

- Bad, because exact matches fell from 12 to 6.

### OUT where the mids drop out

- Good, because it looks right by eye.
- Bad, because it scored worse.

### The longest breakdown as BRIDGE

- Bad, because the DJ usually picks the _first_ big one.

## More Information

Ideas not built yet:

- Learn per-cue offsets from the DJ's corrections. Rated auto tracks give before/after pairs.
- EMERGENCY loop length 64 when the stripped outro is long (the DJ does this sometimes).
- Use Mixed In Key energy levels as a tie-breaker for which drop is "the" drop.
