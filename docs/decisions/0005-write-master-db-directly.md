---
status: accepted
date: 2026-10-14
decision-makers: Deavon
---

# Write cues straight into Rekordbox's encrypted master.db

## Context and Problem Statement

Rekordbox reads cues from its database, not from the ANLZ files. The tool has to write hundreds of cues at once, so it
needs a way into Rekordbox 6/7's `master.db` (SQLCipher) that can't corrupt the library.

## Decision Drivers

- The library must never be left half-written or corrupted.
- Rekordbox keeps the database open and would overwrite changes on quit.
- Rows must look like the ones Rekordbox creates itself.

## Considered Options

- Decrypt, edit and re-encrypt `master.db` with checks at every step
- Edit cues through Rekordbox's XML import/export

## Decision Outcome

Chosen option: "Decrypt, edit and re-encrypt `master.db`", because it writes every cue field directly (including active
loops and memory cue colours) and can be verified before it replaces the live file.

### Writing safely

- **Rekordbox must be fully quit while writing.** Writes refuse to run while it's running, or while `master.db-wal` /
  `-shm` exist.
- Each write backs up `master.db` to `~/Library/Pioneer/_cue_work/` and checks the backup, applies the changes to a
  decrypted copy in one transaction, and runs an integrity check.
- It re-encrypts the copy with the original salt and fresh IVs, decrypts that again and integrity-checks it, and only
  then swaps it in (unless `master.db` changed meanwhile). Re-encrypting a decrypted file with its original IVs
  reproduces it byte for byte (checked on the real library).
- The DB runs in WAL mode. Checkpoint (`pragma wal_checkpoint(TRUNCATE)`) before copying it back.
- Re-export/sync USB sticks afterwards so the device ANLZ files pick the cues up.

### Rekordbox database details (rekordbox 6/7 `master.db`)

- `master.db` is SQLCipher 4 with the default settings: the key is used as a passphrase (PBKDF2-HMAC-SHA512, 256000
  iterations, salt = the file's first 16 bytes), pages are 4096 bytes with 80 reserve bytes (16-byte IV + 64-byte
  HMAC-SHA512 over ciphertext ‖ IV ‖ page number), AES-256-CBC per page, and page 1 carries the salt instead of the
  SQLite header. `internal/sqlcipher` decrypts and encrypts it in pure Go; the plain copy is opened with
  `modernc.org/sqlite`. The key is Rekordbox's own (the one pyrekordbox ships); `REKORDBOX_DB_KEY` overrides it and must
  start with `402fd`.
- Cues live in `djmdCue`.
- `Kind`: 0 memory, hot cues A–H = 1, 2, 3, **5**, 6, 7, 8, 9 (4 is unused).
- `InFrame` = `InMsec × 150 / 1000` (150 frames/s). `OutMsec = -1` for plain cues.
- Hot cue colour `-1` (default). Memory cue `Color` is 0-based: 0 pink, 1 red, 2 orange, 3 yellow, 4 green, 5 aqua, 6
  blue, 7 purple. That's one below the `djmdColor` IDs (1 Pink … 8 Purple) used for track colours; reading it as a
  `djmdColor` ID made every cue one colour off (2026-10-16). The template's colours are in `config.MemoryColor`
  ([0001](0001-cue-template.md)).
- EMERGENCY loop: `Color 255, ColorTableIndex 0, ActiveLoop 1, CueMicrosec 0`, `BeatLoopSize = (beats << 16) + 1`, so 16
  beats → 1048577, 32 → 2097153, 64 → 4194305. `ActiveLoop 1` makes it an active loop (Rekordbox starts looping when
  playback reaches it). A track can already have one of the DJ's own (a memory cue, or an E/F/G pad such as `RUN`); a
  cue that stays and has `ActiveLoop 1` wins, and EMERGENCY is written as a plain loop with `ActiveLoop 0` (how
  Rekordbox stores a loop that isn't active). Our own old EMERGENCY doesn't count, since it's replaced.
- New rows: random unused 32-bit `ID`, `UUID` uuid4, `ContentUUID` = track UUID, `usn`/`rb_local_usn` NULL (same as cues
  Rekordbox itself creates locally), timestamps `YYYY-MM-DD HH:MM:SS.mmm +00:00`.
- **`Kind 4` is not a hot cue pad.** Rekordbox doesn't show it on the pads (a track with an EMERGENCY loop stored as
  Kind 4 shows H as empty). Old layouts parked EMERGENCY loops there; the 2026-10-14 migration moved all of them to H.
  Never write Kind 4.

### Consequences

- Good, because a write is all-or-nothing and always leaves a verified backup.
- Good, because reads use a decrypted temporary copy, so planning works with Rekordbox open.
- Bad, because a future Rekordbox could change the key or schema; `REKORDBOX_DB_KEY` covers the key.
- Bad, because a track is skipped if its cues changed after the plan was made, so the plan has to be re-made.

### Confirmation

`db.SafeWrite` enforces the checks above; the SQLCipher round trip is tested in `internal/sqlcipher` (set
`AUTO_DJ_TEST_MASTER_DB` to a copy of `master.db` to run it against a real library).

## More Information

To undo a write: quit Rekordbox and copy a `master.before-cues.*.db` backup over
`~/Library/Pioneer/rekordbox/master.db`.
