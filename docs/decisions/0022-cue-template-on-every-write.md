---
status: accepted
date: 2026-11-22
decision-makers: Deavon
---

# Write the cue template on every track a write touches, and let set-owned cues not count

## Context and Problem Statement

The cue template ([0001](0001-cue-template.md)) only reached a track through `plan` → `apply --write`. A track imported
after the last `apply` and put straight into a set got E/G hot cues and transition markers from `set --write`, but no IN
/ BRIDGE / DROP / OUT / EMERGENCY. Those E/G cues then made it `other` ([0004](0004-track-states.md)), so `plan` never
cued it. On "Jazz Hands" (built 2026-11-21) 7 of the 16 tracks, imported that evening, ended up like that. How does
every track auto-dj writes to get the template, and how do the tracks it missed get it?

## Decision Drivers

- Any write to Rekordbox should leave the tracks it touches with the standard hot cues and memory cues where they are
  missing.
- A rated track is never touched.
- Hand-cued tracks stay hand-cued: their cues must not be replaced.
- A set's E/G should still line up with the track's IN and OUT once the template is there.

## Considered Options

- Write the template on the tracks of every write, and don't count set-owned cues in a track's state
- Only warn in `set` when a track has no template
- Let `set` treat tracks with no template as `nohot`, but leave writing them to `plan` / `apply`

## Decision Outcome

Chosen option: "Write the template on the tracks of every write", because the DJ never has to remember to run `plan` /
`apply` after importing tracks, and the tracks already missed are picked up again.

**The tracks.** Every write that names tracks writes the template first, in the same `SafeWrite` and backup, on those of
its tracks still in a generated state (`mik`, `nohot`; unrated): `set --write` (CLI and app) on the set's tracks,
`build-set --write` and the app's **Save as Playlist** on the new playlist's tracks, and `recording --write` on the
playlist's tracks. The cues are the ones `apply --write` places (`CuePlan.plan`, `CueWriter.applyPlan`); the tracks go
into the ledger, so they are `auto` from then on. `cue-sync` names no tracks and copies cues as they are; `apply` writes
the template itself.

**Sets are planned with it.** `SetRun.plan` plans the set with the template on those tracks, as they will be once
written (`CueTemplate.overlay`), so G sits on the new OUT and E near the new IN, and the report lists the tracks under
"Cue template (written first …)".

**Set-owned cues don't count.** E and G hot cues ([0009](0009-sets-own-e-and-g.md)) and `set`'s transition markers (BASS
SWAP / FILTER / CUT / SYNC IN and OUT, [0011](0011-transition-markers-on-both-tracks.md)) no longer decide a track's
state (`Category.setOwned`): a track with only those is `nohot` again, one with `Energy N` cues besides them `mik`.
`apply` keeps them: a hot cue on E or G no longer makes it skip a track, and E/G aren't removed unless they're generated
(`Energy N`). A hand cue on F, or on A–D or H, still makes a track `other`.

**Rated tracks.** `applyPlan` now checks the rating at write time, so a track rated after it was planned is skipped,
whether the plan came from `plan` or from a write. `set --write` still writes E/G and markers on rated tracks
([0004](0004-track-states.md)); the template never goes on them.

### Consequences

- Good, because a newly imported track gets the template the first time auto-dj writes anything that includes it.
- Good, because the tracks a set reached before this change are `nohot` again: re-running `set --write` (or `plan` and
  `apply`) cues them, and their set cues stay as they are.
- Bad, because a track with only hand-made E/G notes (no other hot cues) is now a target too. Its E/G are kept, and only
  empty pads A–D and H are filled, so nothing of the DJ's is lost.
- Neutral, because a track with no cached features is cued from Rekordbox's phrase analysis alone, as `apply` does
  (flagged `phrase analysis only`). Writes that include a track almost always have its features: sets and recordings
  need them.

### Confirmation

`TemplateTests` and `WriteTests` cover the states with set-owned cues, which tracks get the template (not rated, not
`auto` or `other`), planning a set with it, and writing it before the rest of a write. `applyPlan` keeps an E and skips
a rated track or one with a hand F.

On the DJ's library (2026-11-22, 281 tracks), the 7 "Jazz Hands" tracks went from `other` to `nohot`, the only `nohot`
tracks in the library. A dry run of `set --write` on "Jazz Hands" added 58 cues on those 7 tracks: A–D and H on each and
23 memory cues. It removed none, and left every E/G and marker of the set as it was.
