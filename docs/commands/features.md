---
description: Decode every track's audio once with ffmpeg and cache its band energies for the rules.
---

# features

```text
auto-dj features [--categories manual,mik,nohot,auto,other] [--workers 4]
```

Decodes each local track with ffmpeg (11 kHz mono) and stores per-frame band energies in `~/.cache/auto-dj/features/`:
sub (30–120 Hz, the bass and kick), low-mid, mid, high, and spectral flux. `plan`, `set` and `evaluate` read them to
find where the bass is. Already-cached tracks are skipped, so re-run it after adding tracks.

```text
--8<-- "demo/features.txt"
```

| Flag           | Default    | Meaning                                                                              |
| -------------- | ---------- | ------------------------------------------------------------------------------------ |
| `--categories` | all states | Which [track states](../cues/track-states.md) to decode (`mik nohot` or `mik,nohot`) |
| `--workers`    | 4          | Parallel decodes                                                                     |

Streaming tracks have no local file and are skipped; the rules fall back to phrases alone for them. Decode errors are
printed per file and don't stop the run.
