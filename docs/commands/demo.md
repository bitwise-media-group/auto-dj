---
description:
  Render ten original house tracks, run the whole pipeline on them and open the set's preview, no Rekordbox needed.
---

# demo

```text
auto-dj demo [DIR] [--tracks DIR] [--bpm 128] [--no-open]
```

Shows what auto-dj does end to end, on music that's free to use. It renders the ten tracks of the demo set as 24-bit
AIFF (released CC0), then runs the same code the real commands do:

1. [`features`](features.md) on the rendered files;
2. [`plan`](plan.md), and puts the planned cues on the tracks as [`apply --write`](apply.md) would;
3. [`set`](set.md) on the playlist as filed (one key clash), then with `--order suggested`;
4. the set's [preview](set.md#previews): every transition and the whole mix, as a set-list page it opens in your
   browser.

It prints each step's output as the real command would, takes about a minute, and never touches Rekordbox. The generator
knows each track's beat grid and phrases, so it supplies the analysis Rekordbox would have made
([ADR 0014](../decisions/0014-generated-demo-set.md)). The output is the same on every run.

| Flag           | Default       | Meaning                                                                    |
| -------------- | ------------- | -------------------------------------------------------------------------- |
| `DIR`          | `<work>/demo` | Where the reports and `preview/` go                                        |
| `--tracks DIR` | `DIR/tracks`  | Where the AIFF files go (about 560 MB)                                     |
| `--bpm N`      | 128           | The preview's fixed tempo, key kept; `0` plays each track at its own tempo |
| `--no-open`    | off           | Don't open the preview page                                                |

To follow the [walkthrough](../guides/building-a-set.md) in Rekordbox, import `DIR/tracks` from this command.
