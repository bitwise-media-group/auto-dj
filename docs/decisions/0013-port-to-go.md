---
status: accepted
date: 2026-10-30
decision-makers: Deavon
---

# Port rekordbox-cue to Go as auto-dj

## Context and Problem Statement

The tool was written in Python as `rekordbox-cue` (numpy, pyrekordbox, SQLAlchemy). The other BitWise Media Group CLIs
are single Go binaries built on the shared toolchain. Should this one be too, without changing a single cue?

## Decision Drivers

- Output must stay identical: the same cues, plans and set reports.
- One static binary with no Python runtime or native SQLCipher library.

## Considered Options

- Keep the Python tool
- Port to Go, reproducing numpy's arithmetic where cues depend on it

## Decision Outcome

Chosen option: "Port to Go", because a single binary matches the other CLIs, and the cue logic ports straight across.
Where a cue depends on numpy's arithmetic the port reproduces it (`internal/num`): linear percentiles, pairwise float32
sums, round-half-even, first-wins argmin/argmax, and audio features computed in float32. It builds with `CGO_ENABLED=0`:
`master.db` is decrypted and re-encrypted by `internal/sqlcipher` in pure Go ([0005](0005-write-master-db-directly.md)).

The port was first called `adj` (`ADJ_*` variables, cache `~/.cache/adj`) and renamed `auto-dj`, after its repository,
the same day.

### Consequences

- Good, because the tool is one binary built and linted like the other CLIs.
- Bad, because rule code must keep using the `internal/num` helpers to stay in step with the scored results.

### Confirmation

Checked against the Python version on the real library before it was removed:

- `status`, `evaluate -v`, `plan` (all 263 tracks, every category) and the review page data: identical, both on the
  Python feature cache and on features computed by Go (per-column differences below 1e-6 of the column maximum).
- `set` on all four playlists, with and without `--order suggested`: identical reports, `set-plan.json` and transition
  cache.
- `set` previews on Melodic Dark: identical `set.json`; transition clips match the Python renders closely (39–53 dB
  SNR).
- `apply --write` and `set --write --reorder` on copies of `master.db`: the same `djmdCue` rows and track order as the
  Python writes (ignoring IDs, UUIDs and timestamps), and SQLCipher (`sqlcipher3`) opens the Go-written files.

## More Information

Deliberate differences from the Python version:

- The full-set mix no longer drops audio when the next track starts after the buffered audio ends. Python lost the 1 s
  gap after a track without local audio, and one sample at a CUT that ends exactly where the next track starts, so
  `set.mp3` could drift from the page's timeline.
- JSON writes whole numbers without `.0` (`128` rather than `128.0`) and keeps non-ASCII text as UTF-8. Only `auto-dj`
  and its own pages read these files.
- The feature cache is `~/.cache/auto-dj/features/<md5 of the NFC file name>.f32.gz` (gzip: `ADJF`, version, frame
  count, column count, then float32 rows) instead of `.npz`. Run `auto-dj features` once after switching. The format
  kept its `ADJF` magic through the rename, so a cache under `~/.cache/adj` works once moved to `~/.cache/auto-dj`.
- Environment variables: `AUTO_DJ_WORK`, `AUTO_DJ_PATH_MAP` and `AUTO_DJ_CLOUD_DIR` replace the `REKORDBOX_CUE_*` ones.
