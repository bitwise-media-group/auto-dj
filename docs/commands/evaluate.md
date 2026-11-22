---
description: Score the cue rules against your hand-cued tracks, cue by cue.
---

# evaluate

```text
auto-dj evaluate [-v] [--energy]
```

Runs the rules on every hand-cued (`manual`) track and compares each predicted cue with the one you placed: how many
land exactly, within 16 beats (one phrase) and within 32. It writes nothing. Use it before and after changing a
threshold in `Rules.default` (`Sources/AutoDJKit/Config/Config.swift`) to see whether the change helps.

```text
cue            n  exact   <=16   <=32  none
IN            65     33     35     51     0
BRIDGE        57     36     44     45     2
DROP          65     42     45     45     1
OUT           65     24     31     44     0
EMERGENCY     63     30     40     53     0
memory DROP  hit 71  missed 34  extra 37
BASS SWAP    n 18  exact 5  <=16 6
```

`none` counts tracks where you placed the cue and the rules placed nothing. Memory DROPs are matched as sets: "extra"
drops are often real drops you didn't mark.

| Flag              | Meaning                                                                                                                                                                                                         |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-v`, `--verbose` | Also list each track with its cues as `yours/the rules'`, e.g. `IN:97/113`                                                                                                                                      |
| `--energy`        | Instead: where each track's energy comes from (your rating or Mixed In Key's level), and how Mixed In Key's levels compare with your ratings ([ADR 0021](../decisions/0021-build-sets-around-picked-tracks.md)) |

The history of these numbers is in [ADR 0003](../decisions/0003-cue-placement-rules.md#confirmation).
