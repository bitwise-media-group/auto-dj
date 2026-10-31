---
description: Write the plan into Rekordbox's master.db, with a dry run first and a verified backup.
---

# apply

```text
auto-dj apply [--write] [--only TITLE ...] [--plan FILE]
```

Without `--write`, applies the plan to a throwaway decrypted copy of `master.db` and prints what would change. With
`--write`, it does it for real. **Quit Rekordbox first**: it keeps the database open and would overwrite the changes
when it quits.

```text
192 tracks in plan
DRY RUN (nothing written): {
 "updated": 0,
 "skipped": [],
 "removed": 1605,
 "added": 1630
}
Re-run with --write once Rekordbox is quit.
```

What a write does, in order:

1. refuses if Rekordbox is running, or `master.db-wal` / `-shm` exist;
2. backs up `master.db` to `~/Library/Pioneer/_cue_work/master.before-cues.<timestamp>.db` and checks the backup;
3. applies the plan to a decrypted copy in one transaction and integrity-checks it;
4. re-encrypts it with the original salt, decrypts that again and checks it once more;
5. swaps it in, unless `master.db` changed in the meantime;
6. adds the tracks to the ledger, so they become [`auto`](../cues/track-states.md).

A track whose cues changed after the plan was made is skipped (listed under `skipped`).

| Flag               | Default            | Meaning                                                                               |
| ------------------ | ------------------ | ------------------------------------------------------------------------------------- |
| `--write`          | off (dry run)      | Actually write                                                                        |
| `--only TITLE ...` |                    | Only tracks whose title contains any of these strings: `--only "Loleatta" "Trust Me"` |
| `--plan FILE`      | `<work>/plan.json` | The plan to apply                                                                     |

After writing, open Rekordbox and spot-check, then re-export or sync your USB sticks. To undo, see
[Safety & undo](../reference/safety.md).
