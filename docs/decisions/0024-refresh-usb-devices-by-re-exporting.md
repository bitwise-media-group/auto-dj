---
status: accepted
date: 2026-11-22
decision-makers: Deavon
---

# Refresh USB devices by re-exporting, and check them with usb-check

## Context and Problem Statement

After `set --write` on "Jazz Hands" (2026-11-22), the DJ synced the playlist to a USB device with Rekordbox's Sync
Manager. The tracks new to the device arrived with their E/G and template cues. The tracks already on it (Loleatta,
Rushing In, U know me and six more) kept the cues exported weeks earlier, without E/G. Rekordbox showed the new cues in
its collection. How do cues auto-dj writes reach a device that already holds the track?

## Decision Drivers

- The players read the device, so a set's cues are only useful once they're there.
- auto-dj writes `master.db` with Rekordbox closed ([0005](0005-write-master-db-directly.md)), and nothing else of
  Rekordbox's.
- Writing undocumented state is only worth it when it's shown to work.

## Considered Options

- Mark auto-dj's writes the way Rekordbox marks its own cue edits, so a normal sync picks them up
- Re-export: Export Playlist to the device again (or unsync and resync it in Sync Manager), with a check that lists
  what's out of date
- Write the device's export directly

## Decision Outcome

Chosen option: "Re-export, with a check", because on Rekordbox 7.2.20 a sync doesn't refresh the cues of tracks already
on a device, whoever changed them, while exporting the playlist again does, and only for the tracks that changed.
Writing the device directly would mean its OneLibrary database (`exportLibrary.db`), which is encrypted with a key other
than `master.db`'s, as well as the analysis files.

**`usb-check`** (`USBDevice`) reads every track's `ANLZ0000.EXT` on a device (`.PIONEER/USBANLZ`, or `PIONEER`): the
audio path (`PPTH`) and the hot and memory cues with their names (`PCO2`). It matches each file to a collection track by
file name (Rekordbox shortens names on the device, so the device's name is a prefix of the collection's; Unicode
compared canonically) and compares the cues with `master.db`: hot cues by slot, name and time (within 5 ms), memory cues
by position. Rekordbox exports one memory cue per position, so cues on the same beat count as one, matched by any of
their names. It lists the tracks that differ, and the synced playlists that hold them, read from the device's
`playlists3.sync` (Sync Manager's file, playlist IDs in hex). It's read-only.

**The workflow.** After auto-dj writes cues (`set --write`, `apply --write`, the cue template on any write), or after
editing cues in Rekordbox with the device unplugged, run `usb-check` with the device plugged in. For each playlist it
names, right-click it in Rekordbox, **Export Playlist → the device**, and **OK** to replace the list. Unticking it in
Sync Manager, syncing, ticking it again and syncing works too, but re-exports every track; so does removing the listed
tracks from the device and syncing.

### Consequences

- Good, because the device is known to be right before a gig, and nothing is written to undocumented state.
- Bad, because refreshing is a manual step in Rekordbox after each write; `usb-check` says when it is needed.
- Bad, because this is Rekordbox's behaviour on 7.2.20. A later version that refreshes cues on sync would make the
  workflow unnecessary, though `usb-check` would still confirm it.

### Confirmation

Tested on the DJ's device on 2026-11-22 (Rekordbox 7.2.20). "Then" is a Sync Manager sync unless the row says otherwise;
"updated" means the track's analysis files on the device were rewritten. Each test compared `master.db` and every file
in Rekordbox's folders before and after:

| Change                                                                                            | Device plugged in when made | Then                 |
| ------------------------------------------------------------------------------------------------- | --------------------------- | -------------------- |
| auto-dj's cues, marked like a Rekordbox edit (`rb_local_usn` from `localUpdateCount`, all tracks) | no                          | not updated          |
| auto-dj also counting the edit in `djmdContent.CueUpdated` (Rushing In)                           | no                          | not updated          |
| `contentCue.rb_data_status` 256 → 257, as Rekordbox's edit sets it (U know me)                    | no                          | not updated          |
| The DJ's own edit in Rekordbox: a hot cue recoloured, then back (U know me)                       | no                          | not updated          |
| The DJ's own edit in Rekordbox: a hot cue recoloured (Take Me Deep)                               | no                          | not updated          |
| The DJ's own edit in Rekordbox (Loleatta)                                                         | yes                         | **updated**          |
| The track removed from the device, then synced (Rushing In)                                       | n/a                         | **updated**          |
| The playlist unsynced, then synced again (all 16 tracks)                                          | n/a                         | **updated**          |
| A hot cue added in Rekordbox, device unplugged (Take Me Deep), then Export Playlist, replace      | no                          | **updated**, only it |

A cue edit in Rekordbox changes only `master.db`: the cue's `djmdCue` row (`updated_at`, and the field edited), the
track's `contentCue` copy (`Cues`, `rb_data_status`, `rb_local_usn`, `updated_at`), its `djmdContent` row (`CueUpdated`,
`rb_local_usn`, `updated_at`) and `agentRegistry`'s `localUpdateCount`. With the device plugged in, Rekordbox also
writes the device's databases straight away. That is the only path besides a fresh export that refreshed a track. The
marking code was removed.

`USBCheckTests` cover reading `PPTH` and `PCO2` from a synthetic `.EXT`, the comparison (including several memory cues
on one beat), matching shortened and decomposed file names, and reading the synced playlists. On the DJ's device after
the resync, `usb-check` found all 16 tracks up to date. Against `master.db` from before that evening's `set --write`, it
listed the 9 tracks whose G or markers had moved since.
