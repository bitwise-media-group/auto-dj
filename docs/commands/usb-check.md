---
description: List the tracks whose cues on a USB device no longer match Rekordbox's, and the playlists to resync.
---

# usb-check

```text
auto-dj usb-check [/Volumes/<device>]
```

Rekordbox's Sync Manager doesn't update the cues of tracks that are already on a USB device. Cues that auto-dj writes
(`set --write`, `apply --write`), or that you change in Rekordbox with the device unplugged, stay out of date there
until the track is exported afresh ([ADR 0024](../decisions/0024-refresh-usb-devices-by-re-exporting.md)).

`usb-check` reads every track's analysis file on the device and compares its hot cues and memory cues with Rekordbox's
`master.db`. It lists the tracks that differ and the synced playlists that hold them. Without a device it checks every
mounted volume with a Rekordbox export. It only reads, so Rekordbox can be open.

```text
PRIMARY: 16 tracks exported, 14 up to date, 2 out of date
synced playlists: Jazz Hands

  Loleatta  (Original Mix) (on the device since 2026-11-01 22:22)
     E: missing on the device (BEAT STARTS STOMPIN @ 0:22)
     G: missing on the device (PANTERAS @ 5:12)

  Rushing In (Original Mix) (on the device since 2026-11-01 22:23)
     E: missing on the device (PANTERAS @ 0:26)
     G: missing on the device (ALL I NEED @ 3:28)
     memory cues missing on the device: BASS SWAP OUT

Sync Manager doesn't update the cues of tracks already on a device. To refresh them, right-click "Jazz Hands" in
Rekordbox, Export Playlist > PRIMARY, and OK to replace it: only the changed tracks are exported again.
```

## Refreshing the device

For each playlist it names, right-click the playlist in Rekordbox, choose **Export Playlist → the device**, and **OK**
to replace the list on the device. Rekordbox exports the tracks whose cues changed again, with the cues it has now, and
leaves the rest. Unticking the playlist in Sync Manager, syncing, ticking it again and syncing also works, but
re-exports every track. Run `usb-check` again afterwards to confirm.

## What it compares

- **Hot cues** A–H by slot: missing, extra, renamed, or moved by more than 5 ms.
- **Memory cues** by position and name. Rekordbox exports one memory cue per position, so cues on the same beat (a BASS
  SWAP and a DROP, say) count as one.

Device files are matched to collection tracks by file name. Rekordbox shortens long names on the device, so the device's
name only has to start the collection's. A file that matches no track, or several, is listed with a `?`.
