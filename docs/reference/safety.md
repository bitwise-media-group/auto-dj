# Safety & undo

auto-dj writes straight into Rekordbox's encrypted database, so every write is built to be all-or-nothing and reversible
([ADR 0005](../decisions/0005-write-master-db-directly.md)).

## Reads

Every read decrypts a temporary copy of `master.db` and works on that. Reading is safe with Rekordbox open: `status`,
`features`, `evaluate`, `plan`, `review`, `set` without `--write` and `apply` without `--write` never change the
library.

## Writes

`apply --write` and `set --write`:

1. **Refuse while Rekordbox is running**, or while `master.db-wal` / `master.db-shm` exist. Rekordbox keeps the database
   open and would overwrite the changes when it quits.
2. **Back up** `master.db` to `~/Library/Pioneer/_cue_work/master.before-cues.<timestamp>.db`, and check the backup.
3. Apply every change to a decrypted copy **in one transaction**, then run SQLite's integrity check.
4. **Re-encrypt** it with the original salt, **decrypt it again** and check it once more.
5. **Swap it in**, unless `master.db` changed while all that was happening.

What auto-dj never changes:

- rated or hand-cued tracks (except the set clean-up `set --write` does on a set's tracks, see
  [Set cues](../cues/set-cues.md#clean-up-on-write));
- hot cues E, F and G, except E/G written by `set` and `JUMP <label>` pads renamed `JUMP`;
- a track whose cues changed after the plan was made (it's skipped).

## Undo

Quit Rekordbox and copy a backup over the live database:

```sh
cp ~/Library/Pioneer/_cue_work/master.before-cues.20261030-213000.db \
   ~/Library/Pioneer/rekordbox/master.db
```

Pick the backup taken just before the write you want to undo (they're timestamped). E/G pairs that a set replaced are
also kept in the transition cache, `~/Library/Pioneer/_cue_work/transitions.json`, and come back the next time those two
tracks meet in a set.

## After writing

Rekordbox reads cues from its database, not from the analysis files on your USB sticks. Re-export or sync your devices
after a write so they pick the new cues up.
