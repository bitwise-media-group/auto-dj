---
status: accepted
date: 2026-11-07
decision-makers: Deavon
---

# Split live recordings by aligning the play history's tracks with the audio

## Context and Problem Statement

After a gig there is one long WAV of the mix (the mixer's recording) and the CDJs' play history, which Rekordbox imports
from the USB. The goal is one tagged AAC file per track, a cue sheet and a tracklist, the transitions as played (for the
transition cache) and a playlist ([0016](0016-create-playlists-from-histories.md)).

The history gives the order but not the timing. Imported rows (`djmdHistory` / `djmdSongHistory`) carry only `TrackNo`;
their `created_at` is the import: on the 2026-11-07 gig all five histories' rows were written within the same few
milliseconds (`auto-dj history <name>` shows them). Where does each track start and end, and where should the files be
cut?

## Decision Drivers

- The files must join back into the recording with nothing lost or doubled, and play back gaplessly.
- Cuts should fall where a listener hears the new track arrive, on its phrase.
- The way sets are played: tracks pitched up to ±10% (with or without master tempo), started from a cue deep in the
  track, only part of a track played, mashups, loops and hot cue jumps.
- Reviewable before anything is written, like `plan` → `review` → `apply`.

## Considered Options

- Time the tracks from the history (row times, or the order plus track lengths)
- Detect track boundaries in the recording alone (novelty / segmentation)
- Find each known track in the recording by its sound, in history order

## Decision Outcome

Chosen option: "find each known track by its sound, in history order", because the history's times are unusable,
boundary detection without the tracks can't tell a breakdown from a new track, and knowing both the order and the source
files makes the search small and specific.

**Locating** (`internal/mixalign`). The recording and each track are decoded at 11 025 Hz (`features.DecodeFrames`
streams the recording, so hours fit in memory; both are cached in the feature folder). Matching uses six z-scored
channels per frame: the low- and high-band spectral flux with their local mean removed, and the log power of the four
bands (`features.Bands`). Flux alone is too generic: tracks on one drum kit match each other. Each track gets 12 probe
windows of 8 s, the busiest in each twelfth of its middle 80%. Each probe is cross-correlated (FFT, normalised) against
the recording over tempo ratios 0.90–1.10 in 0.25% steps, searching from where the previous track's beat 1 would play to
10 minutes past its end. A fit's score is the mean correlation of its best 3 probes agreeing on one offset and tempo (a
set plays only part of a track). Each ratio's best few peaks are refined (position ±3 frames in quarter frames, then
tempo ±0.25% in 0.025% steps, then position again) and the best refined fit wins, because the max filter that tolerates
the tempo grid flatters lookalikes.

On the 2026-11-07 set the 20 tracks played scored 0.83–0.98 and 35 tracks from the day's other sessions 0.14–0.73. Below
0.78 a track is `not-found` (left out), unless a trace (below) hears it straight for 4 probes (about 30 s) at 0.85 or
better, which a lookalike can't sustain. Below 0.88 it is `low-confidence`. Tracks without a file here are `no-audio`.
The peak ratio (best fit over the best half a beat away) is reported but not used: correct fits ranged 1.00–1.37.

**Tracing.** A probe every 16 beats is matched within 40 s of the track's fit, keeping its 16 best places. A Viterbi
path through them collects correlation and pays 0.6 for each change of offset. It must pass through the overall fit, or
it may follow a bar-shifted lookalike. Probes before the track is heard, after it has gone, or inaudible in between (a
breakdown, a mashup, a fader down) may sit out at a fixed score. Straight runs become pieces: the first is extended back
to the track's start and the last to its end, so a transition is mapped from the solo playing next to it. A change of
offset is reported as a jump (a loop or hot cue). Loops inside a transition can't be resolved: the material there is
shared with the other track.

**Takeover and cut.** Over the overlap of A (outgoing) and B (incoming), the recording's bass amplitude is fitted as
a·A + b·B (non-negative least squares over 8 beats), with each gain relative to the track's level playing alone. The
takeover is the first moment b exceeds a for 4 beats running. The cut is the takeover moved to B's nearest phrase start
within 16 beats (`setlist.OnPhrase`), mapped back to a recording sample. The first file starts at 0 and the last runs to
the end of the recording, so the files cover it exactly. The silence before the music and after it (below −60 dBFS) is
then trimmed from the first and last files, unless `--no-trim`.

**Transitions as played.** A DJ starts the incoming track on one of its cues, usually within a phrase of one of the
outgoing track's hot cues, and often long before it is heard. E is the latest of B's cues up to 64 beats before B became
audible whose moment falls within 16 beats of one of A's hot cues; else B's latest cue up to a phrase before; else a
phrase start. G is A's beat at that same moment, and BASS SWAP is the cut's beat. On the 2026-11-07 set five transitions
matched A's EMERGENCY cue to the beat. Transitions that don't fit the pattern are flagged for review. `--write` records
consecutive `ok` pairs in the transition cache with source `recording:<history>`.

**Review.** Everything goes to `alignment.json` first. A `cut` edited by hand (it no longer matches `cut_sample`) wins;
clearing it leaves the track out; giving a `no-audio` track a cut puts it in. Re-runs reuse the file; `--realign` aligns
again and keeps hand-edited cuts.

**Export** (`internal/mixexport`). The recording is decoded once and split at exact samples into one encoder per track:
Apple's AAC encoder through `afconvert` when it works, else ffmpeg's AudioToolbox `aac_at`, else ffmpeg's `aac`, at 256
kb/s and the recording's own rate. Each file's MP4 edit list trims the encoder's priming and padding, which is what
gapless players read, and each file is checked to play exactly its samples. Tags: the track's own title, artist,
composer, genre, comment and label (as grouping, from the library); the set's album, the DJ as album artist only, date,
track n/N, disc 1/1; and the set's cover instead of the track's own art. Files are named `NN - Artist - Title.m4a`
(`text.FileName`). A cue sheet (75 frames a second) and a tracklist cover the whole WAV.

### Consequences

- Good, because one command turns a gig into an album with timestamps, and the transitions played feed the cache.
- Good, because every decision is visible and editable in `alignment.json` before anything leaves the output folder.
- Good, because the cuts are sample-exact and the files gapless, so the album plays back as the mix.
- Bad, because a section a DJ looped during a transition, or a mapping in very repetitive material, can come out a few
  bars off. The cut still lands on the takeover's phrase, but the reported E/G may be shifted, so they are flagged.
- Bad, because the thresholds are calibrated on one real set and a synthetic one. Check the report on the next few gigs.
- Neutral, because the cut is precise to a frame of the analysis (23 ms, refined to about 6 ms). The plan's raw-sample
  refinement was dropped: with master tempo the waveforms don't correlate, and the files are consecutive pieces of the
  same recording, so a cut a few milliseconds off is inaudible.

### Confirmation

`internal/mixalign` tests render a set (skipped under the race detector, where rendering takes minutes; a feature-level
alignment test runs there instead) from the demo synthesiser through `preview.RenderSet` at 126 BPM (tracks at 123–125,
so every track plays at r ≠ 1), with a 64-beat jump-back loop inside one track and a history track that was never
played. Every played track is found, the other is `not-found`, every cut is within a beat of the rendered bass swap, and
the loop track's end fit is within 0.1 s. `internal/mixexport` tests cut a synthetic recording and check the durations,
tags, cover and cue sheet with `ffprobe`. On the 2026-11-07 gig (`HISTORY 2026-11-07 (4)`, 63 minutes) all 20 tracks
were found. To check a real export, spot-check cuts in `alignment.json` against the WAV, import the folder into
Music.app for gapless playback, the art and the album artist, then run `--write` with Rekordbox quit.
