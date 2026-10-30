# adj

`adj` (auto dj) places Deavon's hot cue / memory cue layout on Rekordbox tracks, mainly to replace Mixed In Key's
`Energy N` cues, and prepares sets. Read `docs/DECISIONS.md` before changing rules: it has the template, the rationale,
evaluation numbers and the `djmdCue` field encodings.

- Go CLI (cobra), module `github.com/bitwise-media-group/adj`, main in `cmd/adj`: `mise run build` → `./adj`, or
  `mise run <command> [args]` (CLI tasks in `mise.toml`). Needs `ffmpeg` on PATH. Builds with `CGO_ENABLED=0`, so
  `master.db` is decrypted / re-encrypted by `internal/sqlcipher` (pure Go) and opened with `modernc.org/sqlite`.
- Toolchain: the `.mise/` submodule (bitwise-media-group/toolchain, go archetype). Run `mise run fmt` then
  `mise run lint` before committing; never run `mise lock` here.
- Pipeline: `features` → `plan` → `review` → `apply --write` (see README). Sets: `set "<playlist>"` (`internal/setlist`,
  DECISIONS.md §5c).
- Change thresholds only in `internal/config` (`DefaultRules`), then run `adj evaluate` and compare with the table in
  DECISIONS.md §4.
- The port from Python keeps numpy's arithmetic where cues depend on it (`internal/num`: linear percentiles, pairwise
  float32 sums, round-half-even, first-wins argmin); keep using those helpers in rule code.
- Never write to `master.db` while Rekordbox is running; `db.SafeWrite` enforces backup + checks. Never modify rated
  tracks or hot cue slots E/F/G, except what `set --write` does by user decision (DECISIONS.md §5c): E/G, memory-cue
  renames/recolours/markers, and renaming `JUMP <label>` hot cues to `JUMP`.
- Tests: `mise run test` (synthetic tracks and checked-in fixtures, no Rekordbox needed).
