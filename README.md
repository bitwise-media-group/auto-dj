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

It works from Rekordbox's own beat grid and phrase analysis, plus a bass/mid energy analysis of the audio (AVFoundation
and an FFT). It's a native macOS app and command-line tool (Swift,
[ADR 0018](docs/decisions/0018-rewrite-as-a-native-macos-app.md)) that reads and writes Rekordbox's encrypted
`master.db` itself, and it needs no external tools or services.

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
mise install                        # Swift and XcodeGen at the pinned versions
mise run build                      # the auto-dj CLI, in $(swift build -c release --show-bin-path)
mise run app-run                    # the AutoDJ app (signed Debug build, launched; needs Xcode)
```

It needs macOS 15 and Xcode (for the macOS SDK); there is nothing else to install. The app carries the same CLI inside
it, so with the app installed you can put that on `PATH` instead of building it:

```sh
ln -s /Applications/AutoDJ.app/Contents/MacOS/auto-dj ~/.local/bin/auto-dj
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
mise run build-set --pick "Jolene" --pick "Levels"   # a set around picked tracks (see below)
mise run history                     # play histories (after a gig: see below)
mise run cue -- set --help           # mise keeps a bare --help for itself; pass it through `cue --`
```

### Sets (playlist-specific E / G cues)

```sh
mise run set                                       # list playlists and intelligent playlists
mise run set "Melodic Dark"                        # key check, suggested order if keys clash, cue plan
mise run set "Melodic Dark" --order suggested      # plan with the suggested order (or --order 1,3,2,...)
mise run set "Melodic Dark" --write                # add the new cues (Rekordbox quit; backs up first)
mise run set "Melodic Dark" --order suggested --write --reorder   # ...and save the order
mise run set "Melodic Dark" --preview-dir ~/Desktop               # previews in ~/Desktop/melodic-dark
```

Run `mise run features` first after adding tracks: `set` reads the cached audio features to place bass swaps.
Intelligent playlists work too, numbered in the order the tracks were added; `--reorder` is refused for them because
Rekordbox orders them itself (ADR 0015).

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

Every run renders an AAC (`.m4a`; `--format wav` for WAV) of every transition, the whole set as `set.m4a`, and an
`index.html` set-list page into a folder named after the set (`Melodic Dark` → `melodic-dark/`) in `--preview-dir DIR`
(default `<work>`); `--no-preview` skips them. **Play full set** on the page plays the mix (or tap a track number to
start there). It's a dry run built from the original audio files: each track from E (the first from START) until it
leaves the mix. The whole set plays at a fixed 128 BPM, every track time-stretched with the key kept; `--bpm N` picks
another tempo, and `--bpm 0` beat-matches each incoming track to the outgoing one instead, returning it to its own tempo
once the outgoing track has gone. Rendering takes about a minute for an hour-long set; `--no-mix` skips it. Each
transition clip is the same mix of just those two tracks:

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
disagrees with Rekordbox's phrases, or when an E, G, OUT or BASS SWAP cue you placed is off-phrase and still the best
point (kept, and the preview follows it). Your E/G cues are moved when a nearby point finishes the transition 24–40 bars
before the outgoing track's end or avoids a vocal overlap; the report says so.

Options: `plan --categories mik nohot auto` (or `mik,nohot,auto`) picks targets (see the track states below).
`apply --only "Loleatta" "Trust Me"` limits a write. `--rb-dir` and `--work-dir` point at another library or cache.

After writing, open Rekordbox and spot-check. Then re-export or sync your USB sticks.

### Building a set around picked tracks

```sh
mise run build-set --pick "Loleatta" --pick "Jolene" --pick "Levels" --tracks 14 --arc peak
mise run build-set --pick "Loleatta" --from "Deep House" --opener --tracks 20 --write --name "Sunday"
```

Fills a set around the picked tracks (by title or content ID) from the library, or from one playlist with `--from`:
harmonic keys, tempos within 6% of the set tempo, transitions planned as `set` plans them so vocals don't overlap, and
energy following an arc (`build`, `peak` or `flat`). Energy is your star rating, else Mixed In Key's `EnergyLevel` tag
halved; auto-dj never writes ratings. `--write --name` saves it as a playlist (Rekordbox quit), ready for `set`. In the
app, pick tracks in the Library (Return; Space previews from the drop) and press **Build Set** to get a draft in Sets
that you can re-roll and listen to before saving it
([ADR 0021](docs/decisions/0021-build-sets-around-picked-tracks.md)).

### After a gig (split the recording)

Plug the USB in: Rekordbox imports the CDJs' play history. Then turn the mixer recording (one long WAV) into one tagged
AAC file per track:

```sh
mise run history                                   # the play histories, oldest first
mise run history "HISTORY 2026-11-07 (4)"          # one history's tracks, in play order
mise run recording "HISTORY 2026-11-07 (4)" REC001.WAV --dj "Deavon" --art cover.jpg --album "Live at …"
mise run recording "HISTORY 2026-11-07 (4)" REC001.WAV --dj "Deavon" --art cover.jpg --write   # Rekordbox quit
```

The history gives the order but not the timing (its row times are when Rekordbox imported it), so each track is found in
the recording by its sound: at whatever tempo it was played (±10%), from whichever cue, for however much of it was
played, through loops and hot cue jumps. Each file starts where the track took the bass over from the one before,
snapped to its phrase start ([ADR 0017](docs/decisions/0017-split-recordings-by-alignment.md)). Into `--out` (default
`<work>/recordings/<history>`) it writes:

- `alignment.json`: per track its status (`ok`, `low-confidence`, `not-found` — never heard, left out, `no-audio` — no
  file here), where it was heard, and its `cut` (h:mm:ss.sss into the recording). **Review it**: edit a `cut` to move
  it, clear it to leave the track out, or give a `no-audio` track a cut to put it in. Re-runs reuse the file and its
  edits; `--realign` aligns again (keeping hand-edited cuts).
- `NN - Artist - Title.m4a` (256 kb/s AAC, Apple's encoder): the track's own title, artist, composer, genre, comment and
  label (as grouping); the set as album (default: the history's name), `--dj` as album artist, `--date` (default: the
  history's day), track n/N, and `--art` as the cover. Each file holds exactly its samples (checked), so the files play
  back gapless as the original mix.
- `<album>.cue` (the whole WAV, a track per cut), `tracklist.txt` (`h:mm:ss  Artist – Title`) and `tracklist.json`.

The silence before the music and after it (below −60 dBFS: the recorder runs a moment before you start and after you
stop) is left out of the first and last files; `--no-trim` keeps it.

With `--write` it also saves each transition as played (G on the outgoing track, E and BASS SWAP on the incoming one,
source `recording:<history>`) to the transition cache, and creates a playlist of the kept tracks, named after the
history (`--playlist` to rename, `--folder` to file it), so `auto-dj set` can run on it. Nothing else in Rekordbox
changes: the E/G pads only move when you run `set --write` on that playlist
([ADR 0016](docs/decisions/0016-create-playlists-from-histories.md)).

The report flags transitions that don't look like yours: E is the incoming track's cue it was started on, and G is the
outgoing beat playing then, normally within 16 beats of one of the outgoing track's hot cues.

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

The shared [toolchain](https://github.com/bitwise-media-group/toolchain) submodule at `.mise/` provides the common gates
(license, prose, shell and workflow lint); `tasks.toml` adds the Swift build, test, format and lint, the Xcode tasks and
the CLI tasks. `make <task>` and `mise run <task>` are interchangeable.

```sh
mise run fmt        # swift format, license headers, prettier for markdown
mise run lint       # swift format lint --strict, license, prose, shell and workflow checks
mise run test       # swift test + coverage -> coverage/ (synthetic tracks; no Rekordbox needed)
mise run build      # swift build -c release (AutoDJKit + the auto-dj CLI)
mise run gen        # AutoDJ.xcodeproj from project.yml (XcodeGen; after adding/removing app files)
mise run app-build  # the app, unsigned
mise run pr         # all of the above, then ./commit.sh if present
mise run serve   # docs site on http://localhost:8004 (regenerates the demo walkthrough first)
```

AutoDJKit uses Apple frameworks, so `build` and `test` skip on Linux (the GitHub CI jobs); Xcode Cloud builds the app
and runs `swift test` first (`ci_scripts/ci_post_clone.sh`).

Renovate bumps the submodule to each new toolchain tag (`.gitmodules` records the tag in `branch`). Don't run
`mise lock` here: the lockfile lives in the toolchain.

## Safety

- Reads use a decrypted temporary copy of `master.db`.
- Writes refuse to run while Rekordbox is running (or while `master.db-wal` / `-shm` exist). Each write backs up
  `master.db` to `~/Library/Pioneer/_cue_work/` and checks the backup, applies the changes to a decrypted copy in one
  transaction, and runs an integrity check. It then re-encrypts the copy with the original salt, decrypts that again and
  checks it once more, and only then swaps it in (unless `master.db` changed meanwhile).
- A track is skipped if its cues changed after the plan was made.
- `recording --write` creates a playlist (refused if the name is taken) and nothing else. Its node goes into
  `masterPlaylists6.xml` in the same step: that file is backed up too, and if it can't be written `master.db` is put
  back.
- To undo: quit Rekordbox and copy a `master.before-cues.*.db` backup over `~/Library/Pioneer/rekordbox/master.db`.

## Layout

```text
Package.swift        AutoDJKit + the auto-dj CLI (SwiftPM)
Sources/AutoDJKit/
  Num/               numpy behaviours the rules rely on (percentiles, pairwise sums, rounding)
  Config/            paths, cue template, rule thresholds (Rules.default)
  DB/                SQLCipher 4 (CommonCrypto), master.db access, safe writer, ledger, histories, playlists
  Tracks/            beat grid (PQTZ) + phrase (PSSI) parsing, per-track records
  Audio/             AVFoundation decode, decimation, WSOLA time-stretch
  Features/          band energies via vDSP (cache: <work>/features/*.f32.lzfse)
  Rules/             cue placement rules, the reviewable JSON plan, accuracy against hand-cued tracks
  Review/            HTML review page
  Setlist/           playlists: key check, order suggestion, set E/G + BASS SWAP cues, transition cache
  Preview/           transition previews, the full-set mix and the set-list page (in process)
  Recording/         line a play history up against a set recording; cut, encode and tag its tracks
  Demo/              the synthetic demo tracks and walkthrough
Sources/AutoDJCommands/  the commands (swift-argument-parser)
Sources/AutoDJCLI/   the auto-dj entry point (also embedded in the app as Contents/MacOS/auto-dj)
Tests/               Swift Testing (synthetic tracks, checked-in fixtures)
App/                 the macOS app (SwiftUI); project.yml -> AutoDJ.xcodeproj (XcodeGen)
```
