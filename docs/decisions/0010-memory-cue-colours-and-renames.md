---
status: accepted
date: 2026-10-16
decision-makers: Deavon
---

# Recolour and normalise memory cue names on set tracks

## Context and Problem Statement

Hand-placed memory cues used many spellings (FILTER DOWN, LOW PASS, CUT-OUT RES, JUMP TO DROP…) and arbitrary colours.
In the booth a cue's colour should say what it is at a glance, and the set tooling needs one name per kind of cue.

## Considered Options

- Recolour and rename on `set --write`, rated tracks included
- Leave hand-placed memory cues as they are

## Decision Outcome

Chosen option: "Recolour and rename on `set --write`", because a set's tracks are the ones about to be played.

On `--write`, a set recolours every memory cue on its tracks that's named in `config.MemoryColor`, rated tracks
included: START, IN and LATE red, BASS SWAP orange, DROP green, VOCAL yellow, FILTER purple, JUMP pink, CUT blue, SYNC
red. The IN / OUT markers ([0011](0011-transition-markers-on-both-tracks.md)) take their base name's colour, except SYNC
IN / OUT, which are aqua.

Renames happen first (`config.RenameTo`). All but the JUMP rename apply to memory cues only, so the OUT hot cue on D is
untouched:

- FILTER DOWN and LOW PASS → FILTER; OUT → CUT OUT.
- Old markers FILTER OUT OUT / FILTER OUT IN → FILTER OUT / FILTER IN (FILTER was called FILTER OUT until 2026-10-17).
- Since 2026-10-17, memory cues with the word CUT-OUT / CUT-IN anywhere in the name (CUT-OUT, CUT-OUT RES, LONG CUT-OUT
  RES, CUT-IN DRACUL) → CUT OUT / CUT IN.
- Any `JUMP <label>` (JUMP TO DROP, JUMP TO BRIDGE) → JUMP, **hot cues included**. This is the one change `set` makes to
  the DJ's pads, so all of a track's jump pads are called JUMP.

Names are matched case-insensitively. The report lists each rename and warns about any other memory cue name, which gets
no colour rule.

### Consequences

- Good, because colours mean the same thing on every set track.
- Bad, because the original spelling of a renamed cue is lost (the timestamp is kept).

## More Information

CUT OUT and OUT were briefly renamed CUT; that changed when markers got their IN / OUT side.
