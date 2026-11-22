---
status: accepted
date: 2026-11-21
decision-makers: Deavon
---

# Build sets around picked tracks, by key, tempo, vocals and an energy arc

## Context and Problem Statement

`set` orders and cues a playlist the DJ has already put together. The DJ wants to pick a few tracks instead, listen to
them, and have auto-dj choose the rest of the set around them: tracks that mix harmonically
([0007](0007-harmonic-key-check.md)), at a workable tempo, without vocal overlaps
([0020](0020-transition-endings-and-vocal-overlaps.md)), and following an energy arc (warm up, peak, cool down). Where
does energy come from, which tracks may be chosen, and how is the set searched for?

## Decision Drivers

- The DJ's own judgement wins: their star ratings mean energy, and every rating means energy.
- Rekordbox is the source for tempo, beat grid and key; Mixed In Key's are not used.
- Energy must not be stored in hot or memory cues (Mixed In Key's `Energy N` cues are what auto-dj replaces,
  [0001](0001-cue-template.md)).
- Ratings keep their meaning in [0004](0004-track-states.md): a rated track is `manual` and its cues are never modified.
  auto-dj must not write ratings.
- Writing to master.db needs Rekordbox closed, so building and listening to a set must not.

## Considered Options

- Energy from the DJ's ratings, then Mixed In Key's level
- Energy from an audio estimate only, calibrated on the ratings
- Energy written back to Rekordbox as ratings
- No energy: key, tempo and vocals only

## Decision Outcome

Chosen option: "Energy from the DJ's ratings, then Mixed In Key's level", because it uses the DJ's judgement where it
exists and Mixed In Key's analysis (already in the audio files) for the rest, without writing anything to Rekordbox.
Writing ratings would lock tracks as `manual` and add unchecked tracks to the cue evaluation set.

**Energy** (`Energy`), on the star scale (fractional), from the first of:

1. The track's rating, when it has one.
2. Mixed In Key's energy level (1–10), halved. Mixed In Key writes it into the audio file as an `EnergyLevel` tag (ID3
   `TXXX`), which `EnergyTags` reads with AVFoundation and caches in `<work>/energy-tags.json` by path, size and
   modification time, so only new or re-tagged files are opened (refreshed by `features`, `evaluate --energy`,
   `build-set` and the app's library refresh). Failing that, the comment, when Mixed In Key wrote
   `<tempo> - <key> - <energy>` ("126 - 10A - 7") or `<key> - <energy>` into it; only the energy is read. Rekordbox's
   copy of the comment is often stale: on the DJ's library every comment was the key alone ("9A"), written before the
   setting changed, while the files' `EnergyLevel` tags were all there.
3. Otherwise none: the track takes no arc cost. An audio estimate can be added if untagged tracks turn up.

The app and the report show the source: `4` (rated), `~3.5` (Mixed In Key). `evaluate --energy` reports where energy
comes from and how Mixed In Key agrees with the ratings.

**Pool.** Every analysed track (features and vocals cached, audio on this machine) within the tempo range, or only those
in one playlist, normal or intelligent ([0015](0015-intelligent-playlist-sets.md)). Picks and tracks taken out of a
draft are never added; nor is a second mix of a track already in the set (same title stem).

**Picks and length.** The DJ picks one or more tracks and a number of tracks for the set. The picks are spread evenly,
with as many tracks before the first and after the last as between them, unless the first opens or the last closes the
set. They're placed along the arc by energy (the lowest-energy pick at the arc's lowest point, and so on), or kept in
the DJ's order. The set tempo defaults to the picks' median BPM.

**Search** (`SetBuilder`). The positions between the picks are filled gap by gap with a beam search (32 sequences per
step, the best one per last track). A track costs:

- its key move from the previous track (`Keys.move`: 0, energy boost 1–2, clash 100),
- 0.1 per BPM it's stretched from the set tempo (half and double time count; beyond ±6% it isn't a candidate), and 0.02
  per BPM between neighbours,
- 2 per star between its energy and the arc, and 2 per star a neighbour's energy differs beyond one,
- the transition into it: first a cheap estimate (2 × 48 × the vocal share of the outgoing track's least vocal 48 beats
  from OUT back up to 8 phrases × the vocal share of the incoming track's 48 beats from IN), then, for the 6 best
  candidates of each beam sequence, the real plan: `SetPlanner.fit` places E and G as `set` does and costs 2 per beat of
  vocal overlap, 48 for finishing in the outgoing track's last 16 bars, and 24 when the phrases don't line up. The real
  plans run in parallel. (2026-11-22: the finish now costs `SetPlanner.endingCost`,
  [0023](0023-graded-endings-and-movable-e-g.md).)

**Arc.** Build (low to high), peak (up to the top two thirds in, then halfway back down) or flat (no arc cost), between
the 10th and 90th percentile of the pool's energies (at least a star apart).

**Draft, preview, save.** In the app, the Library picks tracks (Return) and previews them from their DROP hot cue
(Space); Build Set opens the result as a draft in the Sets view, previewed like any set
([0019](0019-render-previews-in-process.md)). A draft track can be re-rolled (the best other track there, with every
other track in place; the old one is left out from then on) or removed, and the draft rebuilt. Saving creates a normal
playlist with `PlaylistWriter` ([0016](0016-create-playlists-from-histories.md)), which then opens as an ordinary set
(write its cues as usual). The CLI's `build-set` runs the same search and creates the playlist with `--write --name`.

### Consequences

- Good, because a set can be started from three tracks instead of a hand-built playlist.
- Good, because energy needs no new tagging: ratings and Mixed In Key's tags are already there.
- Good, because nothing is written to Rekordbox until the DJ saves, and then only a playlist.
- Bad, because Mixed In Key's level says little about the DJ's ratings on this library: its levels bunch at 5–7 (2.5–3.5
  stars), and level 6 covers ratings 1–4 (see Confirmation). Until more tracks are rated, the arc is shaped mostly by
  the rated tracks and the picks, and the unrated ones sit near the middle.
- Bad, because the planner is run for thousands of candidate pairs; it is only quick enough because a track's normalised
  bass level and last loud beat are now computed once with its features (`Track.bass`, `Track.loudEnd`) rather than on
  every call.
- Neutral, because key, tempo, vocals and energy say nothing about style; the playlist pool is how the DJ keeps a set in
  one style.

### Confirmation

`SetBuilderTests` and `EnergyTests` cover the comment parser, the energy order (rating, tag, comment), pick placement,
the arcs, and filling on synthetic tracks: no clashes or tempo outliers, no repeats, picks in place, vocal overlaps
avoided, the arc followed, the pool and re-rolls respected.

On the DJ's library (2026-11-21, 263 tracks): 74 rated (1★ 4, 2★ 14, 3★ 31, 4★ 25), every track with an `EnergyLevel`
tag (2: 1, 4: 1, 5: 38, 6: 157, 7: 61, 8: 5). On the 74 rated tracks, the halved level is within half a star of the
rating for 57% and within one star for 88%, with a mean difference of +0.02, but by level the ratings spread widely:

| Mixed In Key level | 1★  | 2★  | 3★  | 4★  |
| ------------------ | --- | --- | --- | --- |
| 2                  | 1   |     |     |     |
| 5                  | 2   | 2   | 5   |     |
| 6                  | 1   | 6   | 20  | 17  |
| 7                  |     | 6   | 6   | 6   |
| 8                  |     |     |     | 2   |

A fitted map would do no better than halving, so the fixed map stays. Built around Loleatta, Jolene (Destructo Remix)
and Levels, 14 and 40-track sets came out with no key clashes, vocal overlaps or late endings, in under a second each.
