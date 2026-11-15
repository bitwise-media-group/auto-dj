---
status: accepted
date: 2026-11-14
decision-makers: Deavon
---

# Rewrite auto-dj as a native macOS app in Swift

## Context and Problem Statement

Building a set meant a terminal command, about a minute of silent ffmpeg work, then a static page in a browser. There
was no way to reorder tracks and hear the result, no progress per track, and nothing to hear until the whole render
had finished. Should auto-dj become an app, and if so, how much of the Go code should survive?

## Decision Drivers

- Set building should be interactive: reorder, replan, hear each transition as soon as it is ready.
- Keep every existing capability (status, features, evaluate, plan, review, apply, set, history, recording, demo) and
  the safety rules around `master.db`.
- Keep the behaviour, not the bytes: small numeric drift is fine where nobody would notice it in the cues or the audio.
- Prefer what Apple's frameworks give for free (AVFoundation, Accelerate, CommonCrypto, SQLite, Codable) over code that
  emulates Go or numpy.

## Considered Options

- A SwiftUI app with the Go binary as a sidecar
- A full Swift rewrite: a library (AutoDJKit), a command line and an app
- Keep the Go CLI and improve the static preview page

## Decision Outcome

Chosen option: "A full Swift rewrite", because the interactive parts (live replanning, streamed renders, playback) need
the engine in-process, and a sidecar would have meant two languages and an IPC protocol for the same rules. The Go tree
stays as the reference until the cut-over; every phase is gated on a diff against the Go binary.

- **AutoDJKit** (SwiftPM) holds every rule and engine with no UI: the SQLCipher page codec on CommonCrypto with the
  system SQLite, ANLZ, the feature extraction (AVFoundation decode, vDSP FFT), the cue rules, set planning, and the
  preview timeline and render engine ([0019](0019-render-previews-in-process.md)).
- **`auto-dj`** is the command line (swift-argument-parser), with the same commands and flags.
- **AutoDJ.app** is SwiftUI on AutoDJKit, built from `project.yml` with XcodeGen (`mise run gen`, `mise run app-build`),
  like glyph. It is distributed outside the App Store with Developer ID and the hardened runtime, and without the App
  Sandbox: it reads and writes Rekordbox's library in `~/Library/Pioneer` and music wherever it lives.
- Only the numpy semantics that decide where a cue lands are kept: linear-interpolation percentiles, round-half-even
  beat snapping, first-wins ties. [0013](0013-port-to-go.md)'s bit-exact pairwise sums and Go-compatible JSON are not.
- File formats may change. The feature cache is now `<md5 of the NFC file name>.f32.lzfse` (LZFSE: `ADJ2`, version,
  frame count, column count, float32 rows) beside the Go build's `.f32.gz`. JSON artifacts are written by
  `JSONEncoder` (pretty-printed, sorted keys).

### Consequences

- Good, because sets are built interactively, and the preview render is about 20× faster (see 0019).
- Good, because Apple's frameworks replace ffmpeg, gonum, golang.org/x/text and a hand-written JSON layer: `ffmpeg` is no
  longer required.
- Bad, because the app is macOS-only, and the CLI no longer builds on Linux.
- Bad, because a JSON artifact written by the Go build and one written by the Swift build differ in layout. Both builds
  read each other's `plan.json`, `transitions.json` and `applied-tracks.json`.

### Confirmation

Checked against the Go binary on the real library (263 tracks):

- Features: decoding follows ffmpeg's: a stereo source is downmixed to (L + R) / √2, and 44.1 kHz audio is decimated to
  11025 Hz by a Kaiser-windowed sinc as ffmpeg's resampler does (other rates use AVAudioConverter's Mastering
  resampler). Bands 0–2 match the Go cache to within 0.05% of each column's maximum on every track; the top band and
  the flux to within about 2% (8% on the two 48 kHz tracks).
- `status`: the same counts. `evaluate` and `evaluate -v`: byte-identical, on features computed by the Swift build.
- `plan` (auto and manual, every track): 2,232 of 2,232 cues on the same beat.
- `apply --write` on a copy of `master.db`: the same updated / skipped / removed / added counts as Go, and Go reads the
  Swift-written database.
- `set` on all nine playlists (five playlists, four intelligent playlists), with and without `--order suggested`: 18 of
  18 reports byte-identical.
- `set --write --reorder` from the app on a copy: the Go binary then reads the saved order and reports every set cue as
  `existing`.
- `recording` on two real gigs (the 2026-11-07 calibration set and the 2026-11-14 While You Work set, both against the
  20-track history): with the Go build's own track features the Swift alignment is identical to Go's (status, cut and
  transition for all 20 tracks). With its own features, 15 and 17 of 20 tracks are identical; the rest are tracks the
  report flags for review: a status either side of the 0.88 threshold, the same cut with another start cue, and three
  cuts that land elsewhere. The export (AAC through AVFoundation instead of afconvert and ffmpeg) is checked to play
  each file's exact samples, and `--write` creates a playlist Go reads.
- `demo`: every walkthrough fragment the docs include (tracks, features, plan, both set reports) is byte-identical to the
  Go build's, though the synth draws its noise from its own seeded generator.

## More Information

`scripts/parity.py` compares a Go plan with a Swift one by cue beat and prints the movers. Every command is ported; the
cut-over (removing the Go tree and switching the mise tasks and docs to the Swift CLI) is the last step.
