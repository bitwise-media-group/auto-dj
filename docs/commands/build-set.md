---
description:
  Build a set around a few picked tracks, choosing the rest from the library by key, tempo, vocal overlaps and an energy
  arc.
---

# build-set

```text
auto-dj build-set --pick "<title or ID>" [--pick ...] [--tracks 16] [--arc build|peak|flat]
                  [--keep-order] [--opener] [--closer] [--bpm N] [--tempo-range 6]
                  [--from "<playlist>"] [--write --name "<playlist>" [--folder "<folder>"]]
```

Pick a few tracks; `build-set` fills the rest of the set from your library (or one playlist with `--from`) so that:

- **keys mix**: every move is harmonic on Mixed In Key's chart, with energy boosts allowed at a small cost
  ([ADR 0007](../decisions/0007-harmonic-key-check.md));
- **tempos fit**: every track is within `--tempo-range` percent of the set tempo (half and double time count), which
  defaults to the picks' median BPM;
- **vocals don't overlap**: each transition is planned as [`set`](set.md) would plan it, and candidates whose vocals
  would clash with the outgoing track's are passed over
  ([ADR 0020](../decisions/0020-transition-endings-and-vocal-overlaps.md));
- **energy follows an arc**: `build` (low to high), `peak` (up to a peak two thirds in, then halfway down) or `flat`.

A pick is matched by its Rekordbox content ID or by part of its title (it must match one track). The picks are spread
through the set, or `--opener` / `--closer` make the first / last pick start / end it. They're placed along the arc by
energy unless `--keep-order`.

```text
Set of 14 tracks at 126 BPM, from a pool of 214 (* = picked; energy: yours, ~ Mixed In Key's, arc target in brackets):
  1  ~2.5 (2.5)  C#m    126  Got You In My Chest (Extended Mix)
  2  ~2.5 (2.6)  F#m    128  Show Me How (Original Mix)
  3  ~3   (2.7)   Bm    126  I Want It  (Original Mix)
  4* ~2.5 (2.9)   Em    129  Loleatta  (Original Mix)
  ...
0 key clash(es), 0 vocal overlap(s), 0 transition(s) ending in the last 16 bars
```

It's a dry run: nothing is written. With `--write --name "<playlist>"` (Rekordbox quit) it creates the set as a new
playlist, backing up `master.db` first, and gives its tracks that have no auto-dj cues yet (`mik`, `nohot`) the cue
template, as `apply --write` would ([ADR 0022](../decisions/0022-cue-template-on-every-write.md)); then
[`set "<playlist>"`](set.md) previews it and writes its cues. In the app, pick tracks in the Library (Return picks,
Space previews from the drop) and press **Build Set**: the draft opens in Sets, where tracks can be re-rolled or removed
before it's saved as a playlist.

## Energy

A track's energy is **your star rating**, else **Mixed In Key's energy level** (1–10) halved: the `EnergyLevel` tag
Mixed In Key writes into the audio file, else its comment when it's `<tempo> - <key> - <energy>`. auto-dj never writes
ratings (a rating marks a track as hand-cued, see [Track states](../cues/track-states.md)), so rate tracks in Rekordbox
to sharpen the arc. `auto-dj evaluate --energy` shows where each track's energy comes from and how Mixed In Key's levels
compare with your ratings ([ADR 0021](../decisions/0021-build-sets-around-picked-tracks.md)).

Run [`features`](features.md) first after adding tracks: only analysed tracks (features and vocals cached) are
candidates.

| Flag                  | Meaning                                                               |
| --------------------- | --------------------------------------------------------------------- |
| `--pick TRACK`        | A track to build around (repeat)                                      |
| `--tracks N`          | Tracks in the set, picks included (default 16)                        |
| `--arc SHAPE`         | `build`, `peak` (default) or `flat`                                   |
| `--keep-order`        | Keep the picks in the order given                                     |
| `--opener/--closer`   | The first pick opens / the last pick closes the set                   |
| `--bpm N`             | The set tempo (default: the picks' median BPM)                        |
| `--tempo-range PCT`   | How far a track may be from the set tempo (default 6)                 |
| `--from PLAYLIST`     | Only add tracks from this playlist or intelligent playlist            |
| `--write --name NAME` | Create the set as a playlist (Rekordbox quit), in `--folder` if given |
