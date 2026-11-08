---
description:
  Split a set recording into one tagged AAC file per track, with a cue sheet and tracklist, using the play history.
---

# recording

```text
auto-dj recording "<history>" <mix.wav> --dj NAME --art COVER [--album NAME] [--date YYYY-MM-DD]
                  [--out DIR] [--realign] [--no-export] [--no-trim] [--encoder auto|afconvert|ffmpeg]
                  [--write [--playlist NAME] [--folder FOLDER]]
```

Turns the mixer's recording of a set into an album. The [history](history.md) says which tracks were played and in what
order; the audio says when. Each track is found in the recording by its sound: at the tempo it was played (±10%), from
whichever cue it was started on, for however much of it was played, through loops and hot cue jumps. Each file starts
where its track took the bass over from the previous one, snapped to its phrase start
([ADR 0017](../decisions/0017-split-recordings-by-alignment.md)).

Into `--out` (default `<work>/recordings/<history>`):

| File                      | What                                                                                      |
| ------------------------- | ----------------------------------------------------------------------------------------- |
| `alignment.json`          | Each track's status, where it was heard, its fit, its transition and its `cut`            |
| `NN - Artist - Title.m4a` | The track: 256 kb/s AAC, its own tags, the set's album, the DJ as album artist, the cover |
| `<album>.cue`             | A cue sheet for the whole WAV, one track per cut                                          |
| `tracklist.txt`, `.json`  | `h:mm:ss  Artist – Title` for each track                                                  |

## The report

```text
   no  cut           status           conf  title
    1  0:00:00.000   ok               0.92  Make You Move  (Original Mix)
                     ! jumps at 0:03:38.105 from 0:03:21.310 to 0:03:52.281 of the track (a loop or hot cue)
    2  0:05:10.714   low-confidence   0.86  Midnight Funk (Deeplomatik Mix)
    …
```

| Status           | Meaning                                                                 |
| ---------------- | ----------------------------------------------------------------------- |
| `ok`             | Found with a score of 0.88 or more                                      |
| `low-confidence` | Found, but check it: a lower score, a short excerpt, a tempo at ±10%    |
| `not-found`      | Not heard in the recording (loaded but not played): left out            |
| `no-audio`       | No audio file here (a streaming track or a missing file): give it a cut |

Each transition's E is the incoming track's cue it was started on and G the outgoing beat playing then. You usually
start a track within 16 beats of one of the outgoing track's hot cues, so transitions that don't are flagged.

## Reviewing

`alignment.json` is the review step. Edit a track's `cut` (`h:mm:ss.sss` into the recording) to move where its file
starts, clear it (`""`) to leave the track out, or give a `no-audio` track a cut to put it in, then run the command
again: it reuses the file and its edits. `--realign` aligns from scratch, keeping cuts you edited. `--no-export` only
aligns and reports.

## Encoding

`--encoder auto` (the default) uses Apple's AAC encoder through `afconvert` when it works, else ffmpeg (Apple's encoder
through AudioToolbox when it works, else ffmpeg's own). The recording is decoded once and split at exact samples, and
each file's edit list trims the encoder's priming and padding: every file is checked to play exactly its samples, so the
album plays back gaplessly as the mix. Each file keeps the track's title, artist, composer, genre, comment and label (as
grouping); the album is `--album` (default: the history's name), the album artist `--dj`, the date `--date` (default:
the history's day), and the cover `--art` (the tracks' own art is not used).

The silence before the music and after it (below −60 dBFS: the recorder runs a moment before you start and after you
stop) is left out of the first and last files, keeping 10 ms before the first sound. `--no-trim` keeps it, so the files
cover the whole WAV.

## --write

With Rekordbox quit, `--write` also:

- saves each transition between two `ok` tracks as played (G on the outgoing track, E and BASS SWAP on the incoming one)
  to the transition cache, so [`set`](set.md) restores them when the pair meets again;
- creates a playlist of the kept tracks, named after the history (`--playlist` to rename, `--folder` to put it in a
  playlist folder), refused if the name is taken ([ADR 0016](../decisions/0016-create-playlists-from-histories.md)).

No cues change: run `set --write` on the playlist for that.
