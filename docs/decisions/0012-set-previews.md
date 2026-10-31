---
status: accepted
date: 2026-10-16
decision-makers: Deavon
---

# Render set previews offline with ffmpeg, at a fixed set tempo

## Context and Problem Statement

Before writing a set's cues, the DJ wants to hear each transition and the whole set as the cues describe it. How should
`set` produce that audio?

## Decision Drivers

- The library is AIFF.
- Previews should follow exactly the same rules as the cues (E, G, swap, exit, jumps).

## Considered Options

- Play the original files live in the browser through Web Audio
- Render MP3s offline with ffmpeg, a set-list page to play them

## Decision Outcome

Chosen option: "Render MP3s offline with ffmpeg", because Chrome can't play AIFF, and a page opened from disk can't run
local files through Web Audio filters (the output is silenced).

**Where (decision 2026-10-30).** Every `set` run renders the previews, so what you hear always matches the plan just
made. They go in a folder named after the set (`text.Slug`: `Melodic Dark` → `melodic-dark`) inside `--preview-dir`
(default `<work>`), so sets never overwrite each other. `--no-preview` skips them for a quick key check.

**Full-set mix (2026-10-16).** `set.mp3` is a dry run of the whole set played from the page. Each track plays from E
(START for the first) until it leaves. If the outgoing track leaves before the swap, the incoming bass comes in when it
leaves. A track without local audio leaves a 1 s gap, and the track before it plays to its end. The output is streamed
through ffmpeg a track at a time, with a fixed 0.85 gain and a soft knee at 0.8 instead of normalising. "Melodic Dark"
(14 tracks) renders to 56 minutes and 67 MB in about 50 s. `--no-mix` skips it.

**Tempo (decision 2026-10-30).** The default is a fixed set tempo: `--bpm 128`, every track stretched with ffmpeg
`atempo` (key kept) for its whole time in the mix, so the tempo never drifts with the running order. With `--bpm 0` the
incoming track is stretched to the playing tempo until the outgoing one has gone, then returns to its own tempo with a
20 ms crossfade. It only affects the previews; cue placement is in beats either way.

**Transition clips (since 2026-10-17).** Each clip is the full-set mix of just A and B, so both follow the same rules:

- A plays from 8 beats before it reaches G (after any jumps from its E).
- B enters at E, beat-matched (both at the set tempo, or with `--bpm 0` B stretched by A BPM / B BPM using `atempo`),
  and fades in over 8 beats. On a SYNC there's no fade-in: B comes in at full volume.
- Until the bass swap, B is low-cut at 180 Hz. At the swap, A is low-cut instead (30 ms crossfade).
- A leaves the mix on its exit (decision 2026-10-17). On FILTER it's a log low-pass sweep from 16 kHz to 20 Hz
  (effectively silent) over 8 beats (STFT, 24 dB/oct), then a 4-beat fade out. On CUT it's an immediate cut on the beat
  (5 ms ramp). With neither, A fades out over 8 beats from the bass swap. The clip ends 8 beats after A has gone.
- The swap point is the BASS SWAP cue, else the drop the bass comes in on, else E + 32 beats (marked "estimated").

**Jumps (decision 2026-10-17).** On reaching a JUMP memory cue, a track jumps to its JUMP hot cue (any hot cue whose
name starts with JUMP: JUMP, JUMP TO DROP, JUMP AGAIN…), with a 10 ms crossfade. The n-th jump goes to the n-th of those
hot cues in time order, and the last one is reused after that ("Dracul": JUMP, then JUMP AGAIN). Each memory cue jumps
once, so a jump back ("Kuliki") replays the section once rather than looping. A JUMP memory cue within a beat of a JUMP
hot cue marks the landing and doesn't jump ("Here In My Arms"; `set --write` deletes it when it's on the same beat). If
taking the jumps would mean the track never reaches its G, they're ignored for that track. `set` still plans E/G, swaps
and markers on each track's own grid, as if nothing jumps.

### Consequences

- Good, because what you hear is exactly what the cues say, end to end.
- Good, because the page works from disk in any browser.
- Bad, because rendering adds about a minute to every `set` run for an hour-long set (`--no-preview` skips it).
