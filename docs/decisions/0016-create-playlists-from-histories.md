---
status: accepted
date: 2026-11-07
decision-makers: Deavon
---

# Create playlists from imported play histories

## Context and Problem Statement

After a gig, `auto-dj recording` knows which tracks were played and in what order (the CDJs' play history, imported by
Rekordbox, checked against the recording). `auto-dj set` works on playlists, so preparing that set again, or caching its
transitions as cues, needs the history as a playlist. Rekordbox can't turn a history into a playlist in one step. Until
now auto-dj only changed cues and reordered existing playlists ([0005](0005-write-master-db-directly.md),
[0009](0009-sets-own-e-and-g.md)). Should it create playlists, and how?

## Decision Drivers

- The same safety as every other write: never while Rekordbox runs, backed up, all or nothing.
- Rekordbox 7 has to show the playlist exactly as if it had made it.
- Touch nothing but the new playlist.

## Considered Options

- Create the playlist in `master.db` (`djmdPlaylist` + `djmdSongPlaylist`) and in `masterPlaylists6.xml`, together
- Create it in `master.db` only
- Leave it to the user (drag the history's tracks into a new playlist)

## Decision Outcome

Chosen option: "in `master.db` and `masterPlaylists6.xml`, together", because Rekordbox 7 keeps that XML file next to
`master.db` as its playlist tree (one `NODE` per playlist: hex `Id`, `ParentId`, `Attribute`, `Timestamp`), and a
playlist in only one of the two is a state Rekordbox never creates itself.

- `db.CreatePlaylist` inserts a plain playlist (`Attribute` 0) at the end of the root, or of a named folder
  (`--folder`): a random unused numeric `ID` (like the cue IDs, drawn over `djmdPlaylist` including deleted rows), the
  next `Seq`, a fresh `UUID`, the timestamp format the cue writes use. Each track is a `djmdSongPlaylist` row whose `ID`
  and `UUID` are both new UUIDs, as Rekordbox writes them, `TrackNo` 1..n (a track played twice is listed twice).
- It refuses a name already in use (playlist or folder) and track IDs that aren't in the library.
- `masterPlaylists6.xml` gets a `NODE` (the ID in upper-case hex, the root as `ParentId="0"`, the creation time in
  milliseconds as `Timestamp`, `Lib_Type="0" CheckType="0"`) before `</PLAYLISTS>`, in the file's own line endings and
  indentation.
- Both go through `db.SafeWrite`, which now takes "sidecars": files replaced with `master.db`. The new XML is computed
  and the old one backed up before anything is replaced; if writing it fails after `master.db` was swapped in, the
  backup of `master.db` (and any sidecar already written) is put back.
- `usn`, `rb_local_usn` and `agentRegistry` are left alone, as the cue writes leave them
  ([0005](0005-write-master-db-directly.md)): Rekordbox numbers local changes itself when it next syncs.
- Only `recording --write` creates playlists. It never changes rated tracks or cues: the transitions it learned go to
  the transition cache ([0009](0009-sets-own-e-and-g.md)), and the E/G pads only move when `set --write` runs on the
  playlist.

### Consequences

- Good, because a gig's set is one command away from `auto-dj set`, with its played transitions already cached.
- Good, because the write is as safe as the cue writes: refused while Rekordbox runs, backed up, checked, all or
  nothing.
- Bad, because the XML format is undocumented. If Rekordbox changes it, the write is refused (no `</PLAYLISTS>`, or the
  ID already there) rather than guessed at.
- Neutral, because cloud-synced libraries will see the playlist as a local change the next time Rekordbox syncs, like a
  playlist made by hand.

### Confirmation

`internal/db` tests: the rows and their fields on a plain copy of Rekordbox's schema, the XML node (hex IDs, folder
parents, line endings), refusal of a taken name, an unknown track or folder, and on the SQLCipher fixture that
`master.db` is left untouched when the sidecar can't be updated. On a real library: run `recording --write` with
Rekordbox quit, open Rekordbox and check the playlist is there with its tracks in order.
