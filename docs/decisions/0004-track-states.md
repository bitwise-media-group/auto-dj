---
status: accepted
date: 2026-10-14
decision-makers: Deavon
---

# Only cue tracks in a generated state, and never touch rated tracks

## Context and Problem Statement

The library holds hand-cued tracks next to tracks that only carry generated cues. The tool must replace the generated
cues without ever overwriting the DJ's own work, and the hand-cued tracks should keep improving the rules.

## Decision Drivers

- The Mixed In Key tracks (`Energy N`) are the priority; Rekordbox's `CUE(Auto)` memory cues are poor and get replaced
  too, as do tracks with no hot cues at all.
- Tracks the DJ has hand-named or rated must never be touched.
- Corrections the DJ makes should feed back into rule changes.

## Considered Options

- Classify every track into a state, and target only the generated ones
- Let the DJ pick tracks by hand for every run

## Decision Outcome

Chosen option: "Classify every track into a state", because it makes "never touch hand-cued tracks" a rule the tool
enforces rather than something to remember (`db.Classify`).

| State  | Meaning                                                                                           | Used for                                                                                                |
| ------ | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| manual | Rated, or has hand-named IN/DROP/OUT                                                              | Training/evaluation; never modified                                                                     |
| mik    | Only generated cues: `Energy N` (Mixed In Key), `CUE(Auto)` (Rekordbox), + optional START hot cue | Default target                                                                                          |
| nohot  | No hot cues at all (no cues, or memory cues only)                                                 | Default target; generated memory cues are replaced, memory cues you named are kept and never duplicated |
| auto   | Unrated and listed in the ledger (cued by this tool)                                              | Can be re-cued (`--categories auto`); cues with other names (E/F/G notes) are kept                      |
| other  | Anything else                                                                                     | Left alone                                                                                              |

Tool-cued track IDs are recorded in a ledger, `~/Library/Pioneer/_cue_work/applied-tracks.json`, which is what makes a
track `auto`.

**Feedback loop:** once a tool-cued track has been checked or fixed in Rekordbox, give it a star rating. It then counts
as hand-cued, and `evaluate` uses it to judge rule changes ([0003](0003-cue-placement-rules.md)).

### Consequences

- Good, because a rule change can be re-applied to `auto` tracks without losing E/F/G notes.
- Good, because the evaluation set grows as the DJ rates checked tracks.
- Bad, because a track the DJ fixed but forgot to rate is still `auto` and can be re-cued.

## More Information

First run (2026-10-14):

- 192 Mixed In Key tracks cued (189 local AIFF, 3 streaming).
- 1,605 `Energy N` cues removed, 1,630 cues added. 11 tracks have no BRIDGE; 45 have no BASS SWAP.
- Two tracks ("Castles In The Sky", "1998") had a hand START hot cue on A. It was replaced by IN, and START moved to a
  memory cue.
- Backup: `~/Library/Pioneer/_cue_work/master.before-claude-cues.20261014.db`.

`set --write` is the one exception to "never modified": by the DJ's decision it writes E/G and set markers, recolours
and renames memory cues, and renames `JUMP <label>` hot cues on rated tracks too ([0009](0009-sets-own-e-and-g.md),
[0010](0010-memory-cue-colours-and-renames.md), [0011](0011-transition-markers-on-both-tracks.md)).
