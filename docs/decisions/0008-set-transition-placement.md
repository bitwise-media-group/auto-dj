---
status: accepted
date: 2026-10-14
decision-makers: Deavon
---

# Place set transitions in beats, aligned on phrases

## Context and Problem Statement

For each transition A → B in a set, the tool places A's G (where to start mixing out), B's E (where B comes in) and a
BASS SWAP (where the bass moves across). Where should they go so that the two tracks' phrases line up?

## Decision Drivers

- Tracks are beat-matched when mixed, so position is best measured in beats.
- Phrases must line up across the transition.
- Cues the DJ placed by hand win, even when they look wrong.

## Considered Options

- Model the transition in beats on each track's own grid, aligned on phrase position
- Model it in seconds at each track's own tempo

## Decision Outcome

Chosen option: "Model the transition in beats", because beat-matched tracks share a beat clock no matter their tempo.

**Mixing model.** Each track uses its own Rekordbox grid, which is the same as assuming a common 120 BPM. When A reaches
G, B starts at E, so B beat = E + (A beat − G).

**Phrases.** A phrase is 16 beats. Two ways of measuring phrase position are both accepted: the plain grid from the
first downbeat, and Rekordbox phrase starts that fall on a downbeat. The second one handles tracks whose phrasing shifts
by half a phrase mid-track (On My Own: 353 → 521 → 649). Rekordbox phrase starts that aren't on a downbeat are ignored;
Dialogue's are one beat off.

**Placement.**

- G = the outgoing track's OUT.
- E = the incoming track's IN, or the nearest earlier beat with the same phrase position as G for which a bass swap
  fits.
- BASS SWAP = a phrase start in both tracks, at least 16 beats after E, where B's bass rises and/or A's bass falls
  (score ≥ 0.3). It must come before A's bass ends, or failing that before A's audio ends. It's skipped when it would
  land on one of B's drops. An existing BASS SWAP memory cue in B is used as is when it falls in that window (at least
  16 beats after E, before A's audio ends), even off A's phrasing: the DJ placed it (decision 2026-10-17).
- First track: E = START. Last track: no G. Cue names use the title stem in capitals: "The Lost Hawk (Original Mix)" →
  `LOST HAWK`, "Don't Wake Up" → `DONT WAKE UP`.

**Warnings.** An E/G pair is fine if E and G share a phrase position, so every phrase start (and the bass swap) lines
up. It's also fine if B starts a new phrase on A's last audible beat, which covers letting A play to completion. If
neither holds, you get a warning. If E is a hand-placed cue it is kept even then; otherwise E is moved to fix it.

**Off-phrase cues (decision 2026-10-17).** `set` and the preview follow the cues the DJ placed by hand: E, G (or the OUT
hot cue it comes from) and an existing BASS SWAP. Any of them that isn't on a phrase start gets a warning ("off-phrase …
kept, check it"), because it may be a mistake.

### Consequences

- Good, because phrase starts and the bass swap line up across every generated transition.
- Good, because hand-placed cues are never silently moved; they're flagged instead.
- Bad, because a wrong downbeat in Rekordbox's grid shifts everything; `set` warns when a track's bar grid disagrees
  with its phrases.

## More Information

First run on "Melodic Dark" (since renamed "Dark Mode"; 14 tracks, keys all compatible, 10 of 13 transitions already
hand-cued): every hand pair lines up except Therapy → 16x16, where 16x16's E sat 4 beats before a phrase. It was fixed
by moving E to beat 49, which is 16x16's IN. The Lost Hawk's bass swap lands after On My Own's bass has ended
(informational).
