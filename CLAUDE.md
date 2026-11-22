# auto-dj

`auto-dj` places Deavon's hot cue / memory cue layout on Rekordbox tracks, mainly to replace Mixed In Key's `Energy N`
cues, and prepares sets. Read the ADRs in `docs/decisions/` (MADR, `NNNN-title.md`) before changing rules: the template
is 0001, the rules and their evaluation numbers 0003, the `djmdCue` field encodings 0005, sets 0007–0012, 0015 and 0020,
and recordings 0016–0017. Record a new decision as the next-numbered ADR (see `docs/decisions/index.md`).

- Swift (ADR 0018): the `AutoDJKit` library and the `auto-dj` CLI (swift-argument-parser) in `Package.swift`, the macOS
  app in `App/` (SwiftUI, Developer ID, no App Sandbox) on AutoDJKit. `mise run build` / `mise run test`, or
  `mise run <command> [args]` (CLI tasks in `tasks.toml`, via `scripts/cli.sh`). No ffmpeg: audio is AVFoundation, DSP
  is Accelerate, `master.db` is decrypted / re-encrypted by `SQLCipher` (CommonCrypto) and opened with SQLite3. macOS
  only; on Linux `build`/`test` skip, and Xcode Cloud builds the app after `swift test` (`ci_scripts/ci_post_clone.sh`).
- The commands live in `AutoDJCommands`; `Sources/AutoDJCLI/AutoDJCLI.swift` is the entry point for both SwiftPM's
  `auto-dj` and the Xcode `auto-dj` tool target, which the app embeds as `Contents/MacOS/auto-dj` (signed and notarized
  with it; there is no separate CLI release).
- App: `project.yml` → committed `AutoDJ.xcodeproj` (XcodeGen). Run `mise run gen` after adding/removing app files, then
  `mise run app-build` (unsigned) or `mise run app-run` (signed Debug build, launched).
- Toolchain: the `.mise/` submodule (bitwise-media-group/toolchain, common tasks; the Swift ones are in `tasks.toml`).
  Run `mise run fmt` then `mise run lint` before committing (`swift format` with `.swift-format`); never run `mise lock`
  here.
- Pipeline: `features` → `plan` → `review` → `apply --write` (see README). Sets: `set "<playlist>"`
  (`Sources/AutoDJKit/Setlist`, `Preview`; ADRs 0007–0012, 0015, 0019). Gigs: `recording "<history>" <mix.wav>`
  (`Sources/AutoDJKit/Recording`, ADRs 0016–0017).
- Change thresholds only in `Rules.default` (`Sources/AutoDJKit/Config/Config.swift`), then run `auto-dj evaluate` and
  compare with the tables in ADR 0003.
- The rules keep numpy's arithmetic where cues depend on it (`Num` in `Sources/AutoDJKit/Num/Num.swift`: linear
  percentiles, pairwise float32 sums, round-half-even, first-wins argmin); keep using those helpers in rule code.
  Otherwise keep behaviour, not bytes: prefer Swift/Apple primitives over emulating the old Go/Python output.
- Never write to `master.db` while Rekordbox is running; `SafeWrite` enforces backup + checks. Never modify rated tracks
  or hot cue slots E/F/G, except what `set --write` does by user decision (ADRs 0009–0011): E/G, memory-cue
  renames/recolours/markers, and renaming `JUMP <label>` hot cues to `JUMP`.
- Tests: `mise run test` (Swift Testing; synthetic tracks and checked-in fixtures, no Rekordbox needed).
- Docs site: Zensical (`zensical.toml`, `docs/`, `overrides/`); `mise run serve` / `mise run docs-build` (both render
  the demo walkthrough with the Swift CLI first).
