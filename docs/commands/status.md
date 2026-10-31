---
description: Tracks per state, whether Rekordbox is running, and the size of the feature cache.
---

# status

```text
auto-dj status
```

Reads a decrypted copy of `master.db` and prints where it is, how many tracks are in each
[state](../cues/track-states.md), whether Rekordbox is running (writes refuse while it is) and how many tracks have
cached audio features.

```text
master.db: /Users/you/Library/Pioneer/rekordbox/master.db
tracks: 263  auto=198  manual=65
Rekordbox running: True
feature cache: /Users/you/.cache/auto-dj/features (263 files)
```

No flags besides the [global ones](index.md#global-flags).
