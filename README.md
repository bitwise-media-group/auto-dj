# auto-dj

`auto-dj` prepares Rekordbox tracks and sets.

It places Deavon's hot cue and memory cue layout on Rekordbox tracks. It replaces Mixed In Key's `Energy N` cues and
Rekordbox's `CUE(Auto)` cues, and cues tracks that have no hot cues, with:

- **Hot cues:** A `IN` · B `BRIDGE` (breakdown) · C `DROP` · D `OUT` · H `EMERGENCY` (32-beat active loop)
- **Memory cues:** `START` · `DROP` (every drop) · `BASS SWAP`
- E (IN from a named previous track), F (jumps) and G (OUT to a named next track) are yours. The tool never writes them.

The rules were learned from the 51 hand-cued tracks in the library. Most cues land on the same beat as the hand-placed
ones or one phrase away. The decision records in `docs/decisions/` have the template, how the rules work, the accuracy
tables and the Rekordbox DB details.

It works from Rekordbox's own beat grid and phrase analysis, plus a bass/mid energy analysis of the audio (ffmpeg and an
FFT). It's a single Go binary that reads and writes Rekordbox's encrypted `master.db` itself, and it needs no external
services.

The documentation site (`mise run serve`, published at <https://oss.bitwisemedia.uk/auto-dj/>) explains the cue layout
and every command, and walks through building a set from scratch. To see the whole thing without Rekordbox:

```sh
mise run demo        # render 10 original demo tracks, cue them, plan the set and open its preview
```

## Setup (macOS)

```sh
brew install mise
cd ~/Repos/bitwise-media-group/auto-dj
git submodule update --init         # the shared toolchain, mounted at .mise/
mise trust --all                    # once per clone
mise install                        # Go, govulncheck and ffmpeg at the pinned versions
mise run build                      # -> ./auto-dj (or: go install ./cmd/auto-dj)
```

`auto-dj` knows Rekordbox's `master.db` key. Set `REKORDBOX_DB_KEY` only if a future Rekordbox changes it.

In Rekordbox, analyse tracks with **phrase analysis** turned on (Preferences › Analysis). The rules depend on it.

## Command line

Each CLI command is a mise task that builds `auto-dj` from this checkout and runs it. Arguments after the task name go
straight to the CLI. `mise run cue -- <args>` runs any command, and `auto-dj <args>` is the same thing without mise.
`mise tasks` lists everything.

```sh
mise run status                      # tracks per state, is Rekordbox running?
mise run features                    # decode audio once (cached in ~/.cache/auto-dj)
mise run evaluate [-v]               # score the rules against your rated tracks
mise run plan                        # MIK / CUE(Auto) / no-hot-cue tracks -> ~/.cache/auto-dj/plan.json
mise run review                      # -> ~/.cache/auto-dj/review.html (open in a browser)
mise run apply                       # dry run on a copy of master.db
mise run apply --write               # QUIT REKORDBOX FIRST. Backs up master.db, then writes
mise run demo                        # the generated demo set, end to end, without Rekordbox
mise run cue -- set --help           # mise keeps a bare --help for itself; pass it through `cue --`
```

### Sets (playlist-specific E / G cues)

```sh
mise run set                                       # list playlists
mise run set "Melodic Dark"                        # key check, suggested order if keys clash, cue plan
mise run set "Melodic Dark" --order suggested      # plan with the suggested order (or --order 1,3,2,...)
mise run set "Melodic Dark" --write                # add the new cues (Rekordbox quit; backs up first)
mise run set "Melodic Dark" --order suggested --write --reorder   # ...and save the order
mise run set "Melodic Dark" --preview-dir ~/Desktop               # previews in ~/Desktop/melodic-dark
```

Run `mise run features` first after adding tracks: `set` reads the cached audio features to place bass swaps.

For each transition A → B:

- **A gets G**, named after B, at A's OUT.
- **B gets E**, named after A, at B's IN. E moves earlier if it has to, so B's bass swap lands before A runs out, and it
  always sits on the same phrase position as A's G.
- **B gets a BASS SWAP IN memory cue** on a phrase start in both tracks, where B's bass comes in or A's bass drops out.
  It's skipped if that point is already one of B's drops.
- **Every transition marker is on both tracks**, named by side: `BASS SWAP IN` on B and `BASS SWAP OUT` on A at the same
  moment. Where A leaves the mix (the first `FILTER` or `CUT` memory cue at or after G in A, or after E in B) becomes
  `FILTER OUT` / `CUT OUT` on A and `FILTER IN` / `CUT IN` on B. A `SYNC` memory cue on A's G or B's E (an instant
  mashup, where B comes in at full volume) becomes `SYNC OUT` on A and `SYNC IN` on B. A plain `BASS SWAP`, `FILTER`,
  `CUT` or `SYNC` already at that point is renamed rather than duplicated. A `CUT IN` on B beats a `CUT` on A.
- **Clean-up on `--write`:** `CUT-OUT…` / `CUT-IN…` memory cues are renamed `CUT OUT` / `CUT IN`, and `JUMP <label>`
  cues (hot cues too) are renamed `JUMP`. Two kinds of memory cue are deleted: a `CUT OUT` that doesn't line up with a
  `CUT IN` on the next track, and a `JUMP` on the same beat as a `JUMP` hot cue.

The first track's E is `START` (its first downbeat), and the last track's G is cleared.

- Existing E/G cues for the same neighbours are kept, even with typos like `DIALOG` or `RAJ`, unless they're misaligned;
  then E is moved onto the phrase.
- E/G cues that belong to other sets are overwritten. F and every other cue are never touched.
- **Transition cache:** every E/G pair in the library is saved to `~/Library/Pioneer/_cue_work/transitions.json` before
  anything changes, along with every pair a set writes. When two tracks meet again in another playlist, their pair is
  restored from it.

Every run renders an MP3 of every transition, the whole set as `set.mp3`, and an `index.html` set-list page into a
folder named after the set (`Melodic Dark` → `melodic-dark/`) in `--preview-dir DIR` (default `<work>`); `--no-preview`
skips them. **Play full set** on the page plays the mix (or tap a track number to start there). It's a dry run built
from the original audio files: each track from E (the first from START) until it leaves the mix. The whole set plays at
a fixed 128 BPM, every track time-stretched with the key kept; `--bpm N` picks another tempo, and `--bpm 0` beat-matches
each incoming track to the outgoing one instead, returning it to its own tempo once the outgoing track has gone.
Rendering takes about a minute for an hour-long set; `--no-mix` skips it. Each transition clip is the same mix of just
those two tracks:

- The outgoing track plays from 8 beats before it reaches G.
- The incoming track starts at E, beat-matched (both at the set tempo, or with `--bpm 0` the incoming one stretched to
  the outgoing tempo), and fades in over 8 beats. On a `SYNC` it comes in at full volume instead.
- At the bass swap the bass moves across (the track without the bass is low-cut).
- The outgoing track leaves on its `FILTER` (low-pass sweep to silence over 8 beats, then a 4-beat fade out) or `CUT`
  (immediate cut), else it fades out over 8 beats from the bass swap. The clip ends 8 beats later.
- On reaching a `JUMP` memory cue a track jumps to its `JUMP…` hot cue
  ([ADR 0012](docs/decisions/0012-set-previews.md)).

If your music is mounted somewhere else, set `AUTO_DJ_PATH_MAP="/Users/me/Music=/mnt/Music"` (`;` separates several).
Cloud Library Sync tracks are found under `~/Library/CloudStorage/*/rekordbox`, or set `AUTO_DJ_CLOUD_DIR`.
`AUTO_DJ_WORK` moves the cache (default `~/.cache/auto-dj`).

You get warnings when an E/G pair doesn't line up on the phrase and letting A play to the end wouldn't start a new
phrase in B either. You also get them when a bass swap only happens after A's bass has ended, when a track's bar grid
disagrees with Rekordbox's phrases, or when a hand-placed E, G, OUT or BASS SWAP cue is off-phrase (kept, and the
preview follows it).

Options: `plan --categories mik nohot auto` (or `mik,nohot,auto`) picks targets (see the track states below).
`apply --only "Loleatta" "Trust Me"` limits a write. `--rb-dir` and `--work-dir` point at another library or cache.

After writing, open Rekordbox and spot-check. Then re-export or sync your USB sticks.

## Track states

| State  | What it is                                    | What happens                                                                       |
| ------ | --------------------------------------------- | ---------------------------------------------------------------------------------- |
| manual | Rated, or has your own IN/DROP/OUT cues       | Used to score the rules. Never modified                                            |
| mik    | Only generated cues (`Energy N`, `CUE(Auto)`) | Default target                                                                     |
| nohot  | No hot cues at all                            | Default target. Generated memory cues are replaced; memory cues you named are kept |
| auto   | Cued by this tool, still unrated              | Re-cue with `--categories auto`. Your E/F/G notes are kept                         |
| other  | Anything else                                 | Left alone                                                                         |

**Rate a track once you've checked it.** It then counts as hand-cued, so future rule changes are scored against your
corrections.

## Development

The shared [toolchain](https://github.com/bitwise-media-group/toolchain) submodule at `.mise/` provides the gates (go
archetype: golangci-lint, govulncheck, gotestsum and the version-stamped build, plus license, prose and workflow lint).
`make <task>` and `mise run <task>` are interchangeable.

```sh
mise run fmt     # license headers, go fmt + golangci-lint --fix, prettier for markdown
mise run lint    # golangci-lint, govulncheck, license, prose, shell and workflow checks
mise run test    # go test with race detector + coverage -> coverage/ (synthetic tracks; no Rekordbox needed)
mise run build   # -> ./auto-dj with version metadata
mise run pr      # all of the above, then ./commit.sh if present
mise run serve   # docs site on http://localhost:8004 (regenerates the demo walkthrough first)
```

The preview render test runs only when `ffmpeg` and `ffprobe` are on `PATH`.

Renovate bumps the submodule to each new toolchain tag (`.gitmodules` records the tag in `branch`). Don't run
`mise lock` here: the lockfile lives in the toolchain.

## Safety

- Reads use a decrypted temporary copy of `master.db`.
- Writes refuse to run while Rekordbox is running (or while `master.db-wal` / `-shm` exist). Each write backs up
  `master.db` to `~/Library/Pioneer/_cue_work/` and checks the backup, applies the changes to a decrypted copy in one
  transaction, and runs an integrity check. It then re-encrypts the copy with the original salt, decrypts that again and
  checks it once more, and only then swaps it in (unless `master.db` changed meanwhile).
- A track is skipped if its cues changed after the plan was made.
- To undo: quit Rekordbox and copy a `master.before-cues.*.db` backup over `~/Library/Pioneer/rekordbox/master.db`.

## Layout

```text
cmd/auto-dj/         main
internal/
  cli/               command line (cobra)
  config/            paths, cue template, rule thresholds (Rules)
  sqlcipher/         SQLCipher 4 decrypt / encrypt of master.db (pure Go)
  db/                master.db access, track states, safe writer, ledger
  anlz/              beat grid (PQTZ) + phrase (PSSI) parsing
  features/          audio band energies via ffmpeg + FFT (cache: <work>/features/*.f32.gz)
  num/               numpy behaviours the rules rely on (percentiles, pairwise sums, rounding)
  tracks/            per-track records
  rules/             cue placement rules
  plan/              rules -> reviewable JSON plan
  setlist/           playlists: key check, order suggestion, set E/G + BASS SWAP cues
  pairs/             transition cache (restore set pairs when tracks meet again)
  preview/           transition audio previews + set-list page
  evaluate/          accuracy against hand-cued tracks
  review/            HTML review page; templates/ holds both pages
  testtrack/         synthetic tracks for the tests
  demo/              the generated demo set + walkthrough (`auto-dj demo`); synth/ renders the tracks
docs/                documentation site (Zensical, zensical.toml); decisions/ holds the ADRs
overrides/           the docs site's landing page and header
```
