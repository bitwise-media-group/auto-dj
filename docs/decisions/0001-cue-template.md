---
status: accepted
date: 2026-10-14
decision-makers: Deavon
---

# Use one hot cue and memory cue template on every track

## Context and Problem Statement

The library mixed three kinds of cues: Mixed In Key's `Energy N` cues, Rekordbox's own `CUE(Auto)` memory cues, and
hand-placed cues in several older layouts. Mixing is faster when every track has the same pads in the same places. Which
layout should the tool place, so that its cues sit where hand-placed ones would?

## Decision Drivers

- Every hand-cued track already followed one layout; it was worked out from 34 rated tracks and 17 hand-named unrated
  tracks on 2026-10-14. "Rated" (1–5 stars) means the track was cued by hand.
- Pads the DJ uses for their own notes (other track names, jumps, tricks) must stay theirs.
- Everything follows standard house phrasing (8/16/32-bar blocks).

## Considered Options

- Keep Mixed In Key's `Energy N` cues
- Learn the template from the hand-cued tracks and place it everywhere

## Decision Outcome

Chosen option: "Learn the template from the hand-cued tracks", because every hand-cued track already uses the same
layout, so the tool's cues land where the DJ expects them.

### Hot cues

| Slot | Name             | Meaning                                                                                                   | Where it usually sits                                                                                      |
| ---- | ---------------- | --------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| A    | **IN**           | A good place to start mixing the track in                                                                 | Start of the first phrase after the intro: beat 33 or 65, sometimes 1, 97 or 129                           |
| B    | **BRIDGE**       | The breakdown: little or no drums/bass; used for mashups                                                  | Start of the main mid-track breakdown (Rekordbox "Down" phrase)                                            |
| C    | **DROP**         | The first drop after the bridge                                                                           | First "Chorus" phrase after the breakdown                                                                  |
| D    | **OUT**          | A good place to start mixing out                                                                          | A Chorus phrase about 64 beats (32–128) before EMERGENCY                                                   |
| H    | **EMERGENCY**    | Active loop (a plain one if the track has an active loop already) that can run forever to buy mixing time | 32-beat loop (sometimes 64) in the outro, ending before the bass runs out, usually ~15–30 s before the end |
| E    | _track name_     | Reserved IN point: where to bring this track in when the named track is playing before it                 | First half of the track                                                                                    |
| F    | jumps / specials | In-song jumps and tricks: JUMP, JUMP TO DROP, ROLL 145, CROSS-MIX, EXIT LOOP…                             | Anywhere                                                                                                   |
| G    | _track name_     | Reserved OUT point: where to start mixing out into the named next track                                   | Second half of the track                                                                                   |

E, F and G (and H when it isn't EMERGENCY) hold the DJ's own cues: other track names, JUMP, CUT, ECHO and so on. **The
tool never writes to them**, except `set`: it owns E/G ([0009](0009-sets-own-e-and-g.md)) and renames `JUMP <label>`
pads to JUMP ([0010](0010-memory-cue-colours-and-renames.md)). Generic markers don't belong on pads. BASS SWAP in
particular is **always a memory cue** in the incoming track.

"Bridge" is the DJ's word. The usual dance-music term is **breakdown**. Rekordbox's phrase analysis calls it "Down" for
high-mood tracks and "Bridge" for mid/low-mood tracks.

### Memory cues

| Name                                                    | Colour (`djmdCue.Color`) | Rule                                                                                                                  |
| ------------------------------------------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| **START**                                               | 1 (red)                  | First beat of the first full bar (first downbeat in the grid)                                                         |
| **DROP**                                                | 4 (green)                | Every drop: bass returning after a breakdown. 1–3 per track                                                           |
| **BASS SWAP**                                           | 2 (orange)               | ≥ 4 bars (16 beats) after IN, where the bassline spikes in on a phrase boundary. Always a memory cue, never a hot cue |
| (set) BASS SWAP IN / OUT, FILTER IN / OUT, CUT IN / OUT | orange / purple / blue   | Transition markers from `set`, one per side ([0011](0011-transition-markers-on-both-tracks.md))                       |
| (set) SYNC IN / OUT                                     | 5 (aqua)                 | Instant-mashup markers from `set` on A's G and B's E ([0011](0011-transition-markers-on-both-tracks.md))              |
| (hand-only) IN, LATE                                    | 1 (red)                  | Not generated; `set` recolours them                                                                                   |
| (hand-only) FILTER                                      | 7 (purple)               | Not generated; `set` recolours them                                                                                   |
| (hand-only) VOCAL                                       | 3 (yellow)               | Not generated; `set` recolours them                                                                                   |
| (hand-only) JUMP                                        | 0 (pink)                 | Not generated; `set` recolours them. Previews jump to the JUMP hot cue there ([0012](0012-set-previews.md))           |
| (hand-only) CUT                                         | 6 (blue)                 | Not generated; `set` recolours them                                                                                   |
| (hand-only) SYNC                                        | 1 (red)                  | Not generated; `set` recolours them. On A's G or B's E: an instant mashup                                             |
| (hand-only) FILTER DOWN, LOW PASS                       | → FILTER                 | Not generated; `set` renames them FILTER (purple)                                                                     |
| (hand-only) CUT-OUT…, CUT-IN… (e.g. CUT-OUT RES)        | → CUT OUT / CUT IN       | Not generated; `set` renames them (blue)                                                                              |
| (hand-only) JUMP … (e.g. JUMP TO DROP)                  | → JUMP                   | Not generated; `set` renames them, hot cues included                                                                  |
| (hand-only) OUT                                         | → CUT OUT                | Not generated; `set` renames it CUT OUT (blue)                                                                        |
| (hand-only) any other name                              | as set by hand           | Not generated; `set` warns about them                                                                                 |

### Other rules stated by the DJ

- If the breakdown is **shorter than 16 beats, there is no bridge**. Not every song has one.
- The Mixed In Key tracks (cues named `Energy N`) are the priority. Rekordbox's own `CUE(Auto)` memory cues are poor and
  get replaced too, as do tracks with no hot cues at all. Tracks the DJ has hand-named or rated are never touched by the
  tool ([0004](0004-track-states.md)).
- Everything should follow standard house phrasing (8/16/32-bar blocks).

### Consequences

- Good, because pads mean the same thing on every track, in the booth and in the set tooling.
- Good, because E/F/G stay free for the DJ's own transition notes and tricks.
- Bad, because a few older hand-cued tracks used other layouts and had to be migrated
  ([0006](0006-migrate-older-cue-layouts.md)).

## More Information

The template lives in `internal/config` (`Kind`, `MemoryColor`, `MemoryColorOrder`). How each cue is placed is
[0003](0003-cue-placement-rules.md).
