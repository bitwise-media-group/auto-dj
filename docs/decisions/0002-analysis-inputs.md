---
status: accepted
date: 2026-10-14
decision-makers: Deavon
---

# Place cues from Rekordbox's grid and phrases plus a bass analysis

## Context and Problem Statement

To place the template ([0001](0001-cue-template.md)) the tool needs to know where bars, phrases, breakdowns and drops
are. Which signals should it read?

## Considered Options

- Mixed In Key's `Energy N` cue positions
- Rekordbox's beat grid and phrase analysis, plus band energies decoded from the audio

## Decision Outcome

Chosen option: "Rekordbox's beat grid and phrase analysis, plus band energies", because almost every hand cue sits
exactly on a Rekordbox phrase start, and the bass level tells breakdowns and drops apart.

- **Rekordbox beat grid** (`ANLZ0000.DAT`, tag `PQTZ`): beat times and beat-in-bar.
- **Rekordbox phrase analysis** (`ANLZ0000.EXT`, tag `PSSI`): phrase starts and labels. Mid/low-mood labels are
  collapsed: Verse\* → Up, Bridge → Down. This was the most useful single signal.
- **Audio features** (`internal/features`): ffmpeg decodes to 11 kHz mono, then FFT band energies per beat. The _sub
  band (30–120 Hz)_ is the bass/kick indicator. Each track is normalised so its loudest 5% ≈ 1.0. "No bass" < 0.35,
  "bass present" ≥ 0.45.

### Consequences

- Good, because the cues follow the same phrases Rekordbox shows on the waveform.
- Bad, because tracks must be analysed with **phrase analysis** turned on (Preferences › Analysis).
- Bad, because streaming tracks have no local audio, so they get phrase-only rules.
- Neutral, because `ffmpeg` must be on `PATH`, and decoding is cached (`auto-dj features`).

## Pros and Cons of the Options

### Mixed In Key's `Energy N` cue positions

- Good, because they already exist on the target tracks.
- Bad, because they mark section changes less precisely than Rekordbox phrases, so they are **not used**.
