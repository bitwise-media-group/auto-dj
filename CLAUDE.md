# auto-dj

`auto-dj` places Deavon's hot cue / memory cue layout on Rekordbox tracks, mainly to replace Mixed In Key's `Energy N`
cues, and prepares sets. Read the ADRs in `docs/decisions/` (MADR, `NNNN-title.md`) before changing rules: the template
is 0001, the rules and their evaluation numbers 0003, the `djmdCue` field encodings 0005, and sets 0007–0012. Record a
new decision as the next-numbered ADR (see `docs/decisions/index.md`).

- Go CLI (cobra), module `github.com/bitwise-media-group/auto-dj`, main in `cmd/auto-dj`: `mise run build` →
  `./auto-dj`, or `mise run <command> [args]` (CLI tasks in `mise.toml`). Needs `ffmpeg` on PATH. Builds with
  `CGO_ENABLED=0`, so `master.db` is decrypted / re-encrypted by `internal/sqlcipher` (pure Go) and opened with
  `modernc.org/sqlite`.
- Toolchain: the `.mise/` submodule (bitwise-media-group/toolchain, go archetype). Run `mise run fmt` then
  `mise run lint` before committing; never run `mise lock` here.
- Pipeline: `features` → `plan` → `review` → `apply --write` (see README). Sets: `set "<playlist>"` (`internal/setlist`,
  ADRs 0007–0012).
- Change thresholds only in `internal/config` (`DefaultRules`), then run `auto-dj evaluate` and compare with the tables
  in ADR 0003.
- The port from Python keeps numpy's arithmetic where cues depend on it (`internal/num`: linear percentiles, pairwise
  float32 sums, round-half-even, first-wins argmin); keep using those helpers in rule code.
- Never write to `master.db` while Rekordbox is running; `db.SafeWrite` enforces backup + checks. Never modify rated
  tracks or hot cue slots E/F/G, except what `set --write` does by user decision (ADRs 0009–0011): E/G, memory-cue
  renames/recolours/markers, and renaming `JUMP <label>` hot cues to `JUMP`.
- Tests: `mise run test` (synthetic tracks and checked-in fixtures, no Rekordbox needed).
- Docs site: Zensical (`zensical.toml`, `docs/`, `overrides/`); `mise run serve` / `mise run docs-build`.
