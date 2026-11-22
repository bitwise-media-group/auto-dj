---
status: accepted
date: 2026-11-14
decision-makers: Deavon
---

# Render set previews in-process, in parallel, streamed to playback

## Context and Problem Statement

[0012](0012-set-previews.md) renders the transition clips and the full-set mix with ffmpeg, one after the other. Each
track was decoded about three times by short ffmpeg processes, there was no progress or cancellation, and nothing could
be heard until `set.mp3` had been encoded. Melodic Dark took about 50 s, and Dark Mode about 96 s. How should the Swift
app ([0018](0018-rewrite-as-a-native-macos-app.md)) render previews?

## Decision Drivers

- Hear transition 1 while later ones are still rendering; play the mix up to the rendered point.
- Reordering a set should re-render only the transitions that changed.
- Same mix as 0012: fades, the bass swap, the FILTER sweep, CUTs, jumps, a fixed set tempo with the key kept.
- No ffmpeg, and nothing that can't be tested in CI.

## Considered Options

- Keep ffmpeg (bundle it) and parallelise the processes
- Render in-process with AVFoundation and Accelerate, time-stretching with `AVAudioUnitTimePitch`
- Render in-process with AVFoundation and Accelerate, time-stretching with WSOLA in Swift

## Decision Outcome

Chosen option: "In-process, with WSOLA", because it keeps 0012's mix with no external tool, and the stretcher is the
same algorithm family as ffmpeg's `atempo`, so the previews sound as before. `AVAudioUnitTimePitch` is a phase vocoder
that sounds different on drums, and it needs the Audio Unit registry. That registry isn't available in sandboxed CI or
tests.

- The timeline (`Timeline.mix`, `Timeline.pair`) is pure data, known before any audio exists, so the app draws the whole
  set at once.
- Each file is decoded once per session into a size-bounded source cache (AVAudioFile and AVAudioConverter, 44.1 kHz
  stereo float).
- Each track's mix segment and each clip render in a task group with progress per job. A segment is cached as CAF under
  `<work>/renders/segments/`, keyed by a hash of its file and every parameter relative to its own start. A segment that
  only moved in time is found again, so a reorder re-renders just the tracks around the change.
- A mix assembler sums finished segments in order and releases each final chunk (everything before the next track's
  start) once all earlier tracks are done. The app's player schedules the chunks as they arrive, and plays and seeks up
  to the rendered edge.
- A file that can't be read costs only its own segment (silence in the mix) and its clips; the render goes on.
- The DSP ports from 0012 unchanged in effect: the zero-phase FFT low-cut (vDSP, padded to a power of two), the STFT
  low-pass sweep, the soft limiter.
- Export writes 0012's bundle layout (`index.html`, `set.json`, `01-02.<ext>`, `set.<ext>`) to a folder you pick, as m4a
  (AAC 192 kbps, the default; every browser plays it) or WAV. MP3 would need LAME bundled and isn't offered. The page
  now escapes the playlist name in its title.

### Consequences

- Good, because Dark Mode renders in about 4 s cold and under 2 s warm, against 96 s with ffmpeg, and a reorder takes
  seconds.
- Good, because previews play in the app while they render; nothing is encoded until you export.
- Bad, because the render cache grows with every set you try (`~/.cache/auto-dj/renders`); it isn't pruned yet.
- Neutral: the stretcher differs from ffmpeg's at the waveform level (WSOLA picks windows differently), so 0013's SNR
  check can't confirm it (about −3 dB on stretched audio). The loudness check below replaces it.

### Confirmation

Dark Mode at the default 128 BPM, compared with the Go build's renders:

- `set.json`: identical, timeline field by timeline field.
- Every clip: loudness per band (bass, mids, highs) on half-second windows within 0.3–0.7 dB median and about 1 dB p95,
  3.1 dB at worst (one clip's highs). Fades, bass swaps, filter sweeps and cuts land in the same places.
- Tests cover the timeline cases from the Go suite, the DSP filters, the stretcher (pitch and level kept), and an
  end-to-end render whose mix length matches the timeline.
