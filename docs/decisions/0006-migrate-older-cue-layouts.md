---
status: accepted
date: 2026-10-14
decision-makers: Deavon
---

# Migrate older hand-cued layouts onto the template, losslessly

## Context and Problem Statement

Older hand-cued tracks used other layouts than the template ([0001](0001-cue-template.md)). Left as they were, the pads
would mean different things on different tracks, and the evaluation would compare against the wrong cues. The main
layouts were:

- **Old pad layout:** A START · B IN · C LATE · D BRIDGE · E/F DROP · G OUT · H EMERGENCY.
- **Memory-first layout:** IN/BRIDGE/DROP/OUT as memory cues (plus EARLY/LATE), track names on A, BASS SWAP on B/F,
  EMERGENCY in the hidden Kind 4 slot.
- **Near-standard:** missing H, a stray generic cue on F/G (VOCAL, OUT, BUILD, START), or an unnamed pad.

## Decision Drivers

- No hand-placed timestamp or loop may be lost.
- BRIDGE must never be invented, because not every song has one.

## Considered Options

- A one-off migration script, run out of band
- Leave older tracks as they are

## Decision Outcome

Chosen option: "A one-off migration script", because it puts every track on the same layout while keeping every original
cue. 45 tracks were migrated and checked lossless: every original timestamp and loop still exists on the same track,
possibly moved between pads and memory cues. The script has since been removed. The rules applied:

1. A–D keep their template cue. An unnamed pad takes the slot's name unless a named one exists elsewhere.
2. Empty template pads are filled from same-named cues (hot first, then memory). C takes the first DROP after the
   bridge; a memory DROP is copied, not moved, because every drop keeps a memory DROP.
3. Track-name cues: first half → E, second half → G. If two want the same pad, the earliest keeps E and the latest keeps
   G; any extra goes to F, then to a memory cue. Names are recognised by matching library titles.
4. Other specific cues (JUMP, CUT, ECHO, BLEND, CROSS-MIX…) stay on E/F/G/H. If they were on A–D they move to F, then
   any free E/G.
5. Generic cues (START, EARLY, LATE, BASS SWAP, VOCAL, BUILD, extra IN/OUT/DROP…) become memory cues. Exact duplicates
   (same name and time) merge. Memory EARLY on the first downbeat → START.
6. Missing IN / DROP / OUT / EMERGENCY are placed by the rules and marked as new: 19 EMERGENCY, 7 DROP, 5 OUT and 2 IN.
   **BRIDGE is never invented**. A track whose H holds the DJ's own cue (JUMP, ECHO OFF) gets no EMERGENCY.

### Consequences

- Good, because every hand-cued track now follows the template, so `evaluate` compares like with like.
- Good, because EMERGENCY loops left the hidden Kind 4 slot ([0005](0005-write-master-db-directly.md)).
- Neutral, because the migration is not repeatable from this repository.

## More Information

- Backup: `~/Library/Pioneer/_cue_work/master.before-migration.20261014.db`.
- The same run cued the 4 tracks that had no hot cues (`CUE(Auto)` or nothing).
