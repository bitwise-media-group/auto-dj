---
description: List the play histories Rekordbox imported from the CDJs, or one history's tracks in play order.
---

# history

```text
auto-dj history                  # list the histories, oldest first
auto-dj history "<history>"      # one history's tracks, in play order
```

When you plug in a USB stick the CDJs played from, Rekordbox imports their play histories as `HISTORY yyyy-mm-dd (n)` (a
new one each time the players start a session). This lists them with their track counts, or one history's tracks with
the time Rekordbox wrote each row:

```text
HISTORY 2026-11-07 (4) (created 2026-11-07 19:58:27): 20 tracks
   1. 2026-11-07 19:58:27.430 +00:00   G#m  Make You Move  (Original Mix)
   2. 2026-11-07 19:58:27.430 +00:00   G#m  Midnight Funk (Deeplomatik Mix)
   …
```

Those times are when the history was imported, not when the tracks played, which is why [`recording`](recording.md)
times the tracks from the audio. Reads a copy of `master.db`; nothing is written.
