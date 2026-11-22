---
description:
  Key check, suggested order, E/G and transition cues for a playlist or intelligent playlist, with audio previews of
  every transition.
---

# set

```text
auto-dj set                                   # list playlists and intelligent playlists
auto-dj set "<playlist>" [--order suggested|1,3,2,...] [--free-start]
                         [--preview-dir DIR | --no-preview] [--bpm 128] [--no-mix]
                         [--write [--reorder]] [--out FILE]
```

Prepares a playlist as a set:

1. **Key check.** Each neighbouring pair is checked on Mixed In Key's harmonic chart: same key, Camelot ±1 and relative
   major/minor are free; ±2 and ±1 semitone "energy boosts" are allowed; anything else is a clash
   ([ADR 0007](../decisions/0007-harmonic-key-check.md)).
2. **Suggested order.** On a clash, it suggests the cheapest order that keeps the first track and as many neighbours as
   possible. Use it with `--order suggested`, or give your own (`--order 1,3,2,...`).
3. **Set cues.** E/G, BASS SWAP IN/OUT and exit markers for every transition, as described in
   [Set cues](../cues/set-cues.md). Each line says what would happen: `existing` (kept as is), `new` (empty slot),
   `rename` (an existing cue gets its set name), `replace` (overwritten; the old cue is saved in the transition cache)
   or `clear` (removed from the last track).
4. **Endings and vocals.** G starts at the pair's own G (else the transition cache, else the outgoing OUT) and may move
   up to 8 phrases either way, E with it, so the transition finishes 24–40 bars before the outgoing track's end (later
   costs more the closer it gets to the end, earlier a little) and the two tracks' vocals don't overlap. Your own E/G
   are moved too when that does better: they were placed for another set. An overlap that can't be avoided is a warning,
   like a key clash, with a vocal-free 4, 8 or 16-bar loop in the outgoing track to hold it (ADRs
   [0020](../decisions/0020-transition-endings-and-vocal-overlaps.md),
   [0023](../decisions/0023-graded-endings-and-movable-e-g.md)).

Tracks with no auto-dj cues yet (`mik`, `nohot`: just imported, say) are planned with the cue template, and `--write`
writes it on them first, as `apply --write` would, so E and G line up with their new IN and OUT. The report lists them
under "Cue template (written first …)"; rated tracks never get it
([ADR 0022](../decisions/0022-cue-template-on-every-write.md)).

Run [`features`](features.md) first after adding tracks: `set` reads the cached features to place bass swaps and the
vocal analysis to avoid vocal overlaps.

## Intelligent playlists

An intelligent playlist works too: `set` matches your collection against its conditions the way Rekordbox does, and
numbers the matching tracks in the order they were added to the collection. Rekordbox decides an intelligent playlist's
order itself, so `--reorder` is refused for one; use `--order suggested` (or your own order) to plan and write the cues,
and copy the tracks to a normal playlist if you want the order kept in Rekordbox. A condition auto-dj doesn't know is an
error rather than a guess ([ADR 0015](../decisions/0015-intelligent-playlist-sets.md)).

The report for the [demo set](../guides/building-a-set.md), as imported, starts like this:

```text
--8<-- "demo/set-check.txt:1:27"
```

## Previews

Every run renders an AAC (`.m4a`) of every transition, the whole set as `set.m4a`, and an `index.html` set-list page
into `DIR/<set>`, a folder named after the set (`Melodic Dark` → `melodic-dark`) in `--preview-dir DIR` (default
`<work>`): **Play full set**, or tap a track number to start there. It's a dry run built from your audio files,
following the cues exactly:

- the outgoing track plays from 8 beats before G; the incoming one starts at E, beat-matched, and fades in over 8 beats
  (at full volume on a SYNC);
- at the bass swap the bass moves across (the track without the bass is low-cut);
- the outgoing track leaves on its FILTER (8-beat low-pass sweep, then a 4-beat fade) or CUT, else it fades out over 8
  beats from the swap;
- on a JUMP memory cue a track jumps to its JUMP hot cue.

The whole set plays at a fixed 128 BPM, every track time-stretched with its key kept. `--bpm N` picks another tempo;
`--bpm 0` beat-matches each incoming track to the outgoing one instead. Rendering takes about a minute for an hour-long
set; `--no-mix` skips `set.m4a`, `--format wav` renders WAV instead, and `--no-preview` skips the previews altogether.
Hear the demo set's [preview](../demo/preview/index.html).

## Getting the set onto a USB device

Rekordbox's Sync Manager doesn't update the cues of tracks that are already on a USB device, so after `--write` the
tracks a set changed keep their old cues there. Plug the device in and run [`usb-check`](usb-check.md): it lists them,
and the playlists to refresh. Right-click each in Rekordbox, **Export Playlist → the device**, and **OK** to replace it:
the changed tracks are exported again with the new cues
([ADR 0024](../decisions/0024-refresh-usb-devices-by-re-exporting.md)).

## Flags

| Flag                | Default                | Meaning                                                                      |
| ------------------- | ---------------------- | ---------------------------------------------------------------------------- |
| `--order`           | the playlist's order   | `suggested`, or a comma-separated track-number order (`1,3,2,4`)             |
| `--free-start`      | off                    | Let the suggested order change the first track                               |
| `--preview-dir DIR` | `<work>`               | Render the previews, the full-set mix and the set-list page into `DIR/<set>` |
| `--no-preview`      | off                    | Skip the previews                                                            |
| `--bpm N`           | 128                    | The previews' fixed tempo (key kept); `0` plays each track at its own tempo  |
| `--no-mix`          | off                    | Skip `set.m4a`                                                               |
| `--format`          | `m4a`                  | The previews' audio format: `m4a` (AAC) or `wav`                             |
| `--write`           | off (dry run)          | Write the cues (Rekordbox quit; backs up first)                              |
| `--reorder`         | off                    | With `--write`: also save the order to the playlist (not an intelligent one) |
| `--out FILE`        | `<work>/set-plan.json` | Where to write the set plan                                                  |
