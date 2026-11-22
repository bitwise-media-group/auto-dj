---
description: Decode every track's audio once and cache its band energies and vocals for the rules.
---

# features

```text
auto-dj features [--categories manual,mik,nohot,auto,other] [--workers N]
```

Decodes each local track with AVFoundation (11 kHz mono) and stores per-frame band energies in
`~/.cache/auto-dj/features/`: sub (30–120 Hz, the bass and kick), low-mid, mid, high, and spectral flux. `plan`, `set`
and `evaluate` read them to find where the bass is. It also runs Apple's on-device sound classifier over each track and
caches where it has vocals (singing, rapping, speech), which `set` uses to keep vocals from overlapping in transitions
([ADR 0020](../decisions/0020-transition-endings-and-vocal-overlaps.md)). Already-cached tracks are skipped, so re-run
it after adding tracks.

```text
--8<-- "demo/features.txt"
```

| Flag           | Default    | Meaning                                                                              |
| -------------- | ---------- | ------------------------------------------------------------------------------------ |
| `--categories` | all states | Which [track states](../cues/track-states.md) to decode (`mik nohot` or `mik,nohot`) |
| `--workers`    | core count | Parallel decodes                                                                     |

Streaming tracks have no local file and are skipped; the rules fall back to phrases alone for them. Decode errors are
printed per file and don't stop the run.
