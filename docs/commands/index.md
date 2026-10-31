# Commands

```text
auto-dj <command> [flags]
```

| Command                   | What it does                                                     | Writes to Rekordbox? |
| ------------------------- | ---------------------------------------------------------------- | -------------------- |
| [`status`](status.md)     | Tracks per state; is Rekordbox running?                          | no                   |
| [`features`](features.md) | Decode audio once into the feature cache                         | no                   |
| [`evaluate`](evaluate.md) | Score the rules against your hand-cued tracks                    | no                   |
| [`plan`](plan.md)         | Plan cues for Mixed In Key / `CUE(Auto)` / uncued tracks         | no                   |
| [`review`](review.md)     | Render the plan as an HTML review page                           | no                   |
| [`apply`](apply.md)       | Write the plan (dry run unless `--write`)                        | with `--write`       |
| [`set`](set.md)           | Key check, suggested order, set cues and previews for a playlist | with `--write`       |
| [`demo`](demo.md)         | Render the demo set, cue it, plan the set and open its preview   | no                   |

A typical run:

```sh
auto-dj status
auto-dj features            # decode audio once, cached
auto-dj evaluate            # how well the rules match your hand-cued tracks
auto-dj plan                # -> ~/.cache/auto-dj/plan.json
auto-dj review              # -> ~/.cache/auto-dj/review.html
auto-dj apply --write       # quit Rekordbox first; backs up master.db
auto-dj set "Dark Mode"     # key check + set cues for a playlist
```

## Global flags

| Flag             | Default                       | Meaning                                     |
| ---------------- | ----------------------------- | ------------------------------------------- |
| `--rb-dir DIR`   | `~/Library/Pioneer/rekordbox` | The folder holding `master.db` and `share/` |
| `--work-dir DIR` | `~/.cache/auto-dj`            | Feature cache and plan output               |
| `--version`      |                               | Print the version                           |

## Environment

| Variable            | Meaning                                                                                                 |
| ------------------- | ------------------------------------------------------------------------------------------------------- |
| `AUTO_DJ_WORK`      | Default for `--work-dir`                                                                                |
| `AUTO_DJ_PATH_MAP`  | Remap audio paths for a library mounted elsewhere: `/Users/me/Music=/mnt/Music` (`;` separates several) |
| `AUTO_DJ_CLOUD_DIR` | Where Cloud Library Sync tracks live (default: `~/Library/CloudStorage/*/rekordbox`)                    |
| `REKORDBOX_DB_KEY`  | `master.db`'s key, only if a future Rekordbox changes it (it starts with `402fd`)                       |

## Files

| Path                                                  | What                                                 |
| ----------------------------------------------------- | ---------------------------------------------------- |
| `~/.cache/auto-dj/features/*.f32.gz`                  | Per-track audio features (`features`)                |
| `~/.cache/auto-dj/plan.json`, `review.html`           | The cue plan and its review page                     |
| `~/.cache/auto-dj/set-plan.json`                      | The last `set` plan                                  |
| `~/Library/Pioneer/_cue_work/master.before-cues.*.db` | A backup before every write                          |
| `~/Library/Pioneer/_cue_work/applied-tracks.json`     | The ledger of tracks auto-dj cued (the `auto` state) |
| `~/Library/Pioneer/_cue_work/transitions.json`        | The transition cache of every E/G pair               |

## Through mise

In a checkout, every command is also a mise task that builds the binary first; arguments go straight through:

```sh
mise run set "Dark Mode" --preview-dir ~/Desktop
mise run cue -- set --help     # mise keeps a bare --help for itself; pass it through `cue --`
```
