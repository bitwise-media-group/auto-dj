---
status: accepted
date: 2026-11-22
decision-makers: Deavon
---

# Grade where transitions finish, and let sets move any E/G

## Context and Problem Statement

[0020](0020-transition-endings-and-vocal-overlaps.md) charged a flat 48 when the outgoing track leaves the mix in its
last 16 bars and nothing otherwise. Moving G a phrase earlier cost 6, so the planner stopped as soon as a transition was
past the line. On "Jazz Hands" (2026-11-22) 7 of 15 transitions finished 16–18 bars before the end. That's 35–40 s, well
into the outro, so the bass swaps looked like they were at the very end. Tracks played nearly to the end make a set
dull. E and G the DJ had placed, or that a set had placed and the cache restored, were never moved
([0008](0008-set-transition-placement.md)). So a G an earlier run had moved off OUT counted as hand-placed from then on.
Where should transitions finish, and which E/G may the planner move?

## Decision Drivers

- Tracks shouldn't play to the end. The closer to the end a transition finishes, the worse.
- They shouldn't be cut short either, but that matters less.
- E/G the DJ placed by hand are for a particular set. When a set is being built they're a starting point, not a
  constraint.
- Vocal overlaps still matter most ([0020](0020-transition-endings-and-vocal-overlaps.md)).

## Considered Options

- A graded cost on where the outgoing track leaves the mix, with a sweet spot; every E/G may move
- A larger late zone (24 or 32 bars), still flat
- Move OUT earlier in the cue template

## Decision Outcome

Chosen option: "A graded cost with a sweet spot; every E/G may move", because it changes only set planning, keeps the
template's OUT where the DJ's hand-cued OUTs are ([0003](0003-cue-placement-rules.md)), and rewards each phrase nearer
the sweet spot instead of only crossing one line.

**Where a transition finishes** (`SetPlanner.endingCost`), in bars between where A leaves the mix (as in
[0020](0020-transition-endings-and-vocal-overlaps.md)) and A's last audible beat:

| Bars left | Cost                                                        |
| --------- | ----------------------------------------------------------- |
| 24–40     | 0                                                           |
| 16–24     | 2 per bar under 24 (16 at 16 bars)                          |
| under 16  | 16 + 4 per bar under 16 (48 at 8 bars, 80 at the end): late |
| over 40   | 1 per bar over 40                                           |

The last 16 bars still count as late in reports (`build-set`'s count, `Fit.late`).

**Moving G and E.** G starts at the pair's own G (named after the next track), else the transition cache, else A's OUT,
else the rules' OUT. It's tried up to 8 phrases either way, and the same around the OUT hot cue, so an off-phrase hand G
can move onto OUT's phrasing. It stays within the second half, after the DROP hot cue + 8 bars, and a phrase before the
end. E starts at the pair's own E, else the cache, else IN, and is chosen for each G as before. Moving costs 2 per
phrase for G (was 6) and 4 for E, both ways, from where they started. That's a mild preference for OUT / IN or the DJ's
cue: one phrase nearer the sweet spot (8 when late, 4 when early) outweighs it. Nothing is fixed any more. A G or E that
moves away from a cue of the DJ's is noted ("G moved 20 bars earlier than G 'OTHER' (beat 593 -> 513): finishes 25 bars
before the end (was 5)", "E moved from E 'RUN' (beat 33 -> 29)"). One that's kept off the phrase is still flagged
("kept, check it"). The old pair is saved in the transition cache when it's replaced, as before
([0009](0009-sets-own-e-and-g.md)).

`SetBuilder` uses the same plans and cost ([0021](0021-build-sets-around-picked-tracks.md)).

### Consequences

- Good, because transitions now finish in the middle of the outro rather than at its end: on the DJ's playlists 79 of
  109 transitions finish 24–40 bars before the end.
- Good, because a G an earlier run moved is no longer frozen.
- Bad, because E/G placed by hand for a pair move when the planner finds better, and `set --write` writes the move. The
  old cue is in the transition cache and the report names the move, but it's no longer kept as is.
- Bad, because the planner tries about four times as many G positions. `build-set` takes about 2 s for 14 or 40 tracks,
  library load included.
- Neutral, because some transitions still finish late or early for reasons the cost can't override. The DROP + 8 bars
  floor keeps G after a late drop (Titanium, Consequence, No Broke Boys: 8–14 bars left). A FILTER the DJ placed sets
  the exit (Unspoken Words). Vocal overlaps outweigh the ending (I'm Still Standing). And G moves at most 8 phrases from
  a very early OUT (Dracul: 78 bars left).

### Confirmation

`RulesTests` cover the cost's shape, G moving earlier to finish 24–40 bars out, G moving later so a track isn't cut
short, the DJ's G and E moving, a G of the DJ's that works staying put (off-phrase, flagged), and vocal overlaps and
loops as before.

On the DJ's library (2026-11-22, a dry run of `set` on every normal playlist), bars between where the outgoing track
leaves and its end:

| Playlist       | Transitions | < 16 | 16–24 | 24–40 | > 40 | Median |
| -------------- | ----------- | ---- | ----- | ----- | ---- | ------ |
| Jazz Hands     | 15          | 0    | 2     | 13    | 0    | 25.75  |
| While You Work | 20          | 1    | 7     | 12    | 0    | 25.75  |
| Dark Mode      | 13          | 2    | 0     | 11    | 0    | 26.0   |
| Light Mode     | 20          | 1    | 3     | 15    | 1    | 25.75  |
| Wake Up        | 26          | 4    | 4     | 17    | 1    | 25.75  |
| Hello          | 15          | 0    | 4     | 11    | 0    | 25.75  |

Before, "Jazz Hands" had 7 of its 15 transitions 16–18 bars from the end and a median of 21.75. No playlist has a vocal
overlap.
