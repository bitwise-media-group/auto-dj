---
description: Bring Rekordbox's second copy of every track's cues (contentCue), which the players read, in line.
---

# cue-sync

```text
auto-dj cue-sync [--write]
```

Rekordbox keeps each track's cues twice in `master.db`: in `djmdCue`, and as a JSON copy in `contentCue`, which the
players read. Before 2026-11-15 auto-dj only wrote `djmdCue`, so cues it wrote (and the EMERGENCY active loop) could be
missing or stale on the players. `apply` and `set --write` now update both; `cue-sync` brings every track whose copy is
out of step back in line, once ([ADR 0005](../decisions/0005-write-master-db-directly.md)).

Without `--write` it runs on a throwaway decrypted copy and reports how many tracks are out of step. With `--write` it
writes them, the same way [`apply`](apply.md) does: **quit Rekordbox first**; `master.db` is backed up and checked, and
the copy is integrity-checked before it replaces the live file.
