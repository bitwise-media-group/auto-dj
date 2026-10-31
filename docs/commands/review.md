---
description: Render the current plan as a self-contained HTML page to check before writing.
---

# review

```text
auto-dj review [--plan FILE] [--out FILE]
```

Renders the plan as one self-contained page, `~/.cache/auto-dj/review.html`. Each track is drawn as a bass/energy strip
with Rekordbox's phrases and the planned cue markers on top, so a BRIDGE that isn't on the breakdown or an OUT in the
wrong place is easy to spot. The **No bridge** and **No bass swap** chips filter the list to the tracks most worth
checking by ear.

```text
review page: /Users/you/.cache/auto-dj/review.html
```

Open it in any browser. It needs no server and nothing is written to Rekordbox.

| Flag          | Default              | Meaning           |
| ------------- | -------------------- | ----------------- |
| `--plan FILE` | `<work>/plan.json`   | The plan to show  |
| `--out FILE`  | `<work>/review.html` | Where to write it |
