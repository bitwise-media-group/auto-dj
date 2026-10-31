---
description: Place the hot cue and memory cue layout on the target tracks and save it as a reviewable plan.
---

# plan

```text
auto-dj plan [--categories mik,nohot] [--out FILE]
```

Runs the [cue rules](../cues/hot-cues.md) on every track in the chosen [states](../cues/track-states.md) and writes the
result to `~/.cache/auto-dj/plan.json`. Nothing is written to Rekordbox; [`review`](review.md) shows the plan and
[`apply`](apply.md) writes it.

The summary counts what's worth a look. On the [demo set](../guides/building-a-set.md):

```text
--8<-- "demo/plan.txt"
```

Possible flags: `no bridge` (no breakdown of 16+ beats), `no bass swap`, `phrase analysis only` (no local audio, so no
bass analysis) and `cue order` (the pads aren't in A–D order).

| Flag           | Default            | Meaning                                                                                                  |
| -------------- | ------------------ | -------------------------------------------------------------------------------------------------------- |
| `--categories` | `mik nohot`        | `mik` (`Energy N` / `CUE(Auto)` cues), `nohot` (no hot cues), `auto` (re-cue tracks auto-dj cued before) |
| `--out FILE`   | `<work>/plan.json` | Where to write the plan                                                                                  |

## What the plan contains

For each track: the hot cues (pad, name, beat and position in ms; EMERGENCY with its 32-beat loop), the memory cues
(START, every DROP, BASS SWAP) and the flags. The demo set's plan:

--8<-- "demo/plan.md"
