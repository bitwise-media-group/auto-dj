# Getting started

auto-dj does two jobs on a Rekordbox library:

1. **Cueing tracks.** It replaces Mixed In Key's `Energy N` cues and Rekordbox's `CUE(Auto)` cues, and cues tracks that
   have none, with one [hot cue and memory cue layout](../cues/hot-cues.md): IN, BRIDGE, DROP, OUT and an EMERGENCY loop
   on the pads, START, DROP and BASS SWAP as memory cues.
2. **Preparing sets.** For a playlist it checks the keys, suggests an order when they clash, and writes the
   [set cues](../cues/set-cues.md) for every transition: where to mix out of each track (G), where to bring the next one
   in (E), and markers on both tracks for the bass swap and the exit. It can render every transition, and the whole set,
   as audio you can listen to before you play it.

It reads Rekordbox's beat grid and phrase analysis, measures where the bass is from the audio, and writes straight into
Rekordbox's database, always with a verified backup (see [Safety & undo](../reference/safety.md)).

## See it first

`auto-dj demo` renders ten original house tracks, cues them, plans a set and opens the preview, all without touching
Rekordbox:

```sh
auto-dj demo
```

The [Building a set from scratch](../guides/building-a-set.md) guide walks through the same set step by step in
Rekordbox, and links the [preview it produces](../demo/preview/index.html).

## Install (macOS)

auto-dj is a single Go binary. It needs `ffmpeg` on `PATH` to decode audio. The repository pins both through
[mise](https://mise.jdx.dev):

```sh
brew install mise
git clone https://github.com/bitwise-media-group/auto-dj.git
cd auto-dj
git submodule update --init   # the shared toolchain, mounted at .mise/
mise trust --all              # once per clone
mise install                  # Go, govulncheck and ffmpeg at the pinned versions
mise run build                # -> ./auto-dj (or: go install ./cmd/auto-dj)
```

Every command is also a mise task that builds the checkout and runs it (`mise run set "My Playlist"`), so you can skip
the build step. See [Commands](../commands/index.md).

## Prepare Rekordbox

- **Turn on phrase analysis** (Preferences › Analysis › Phrase) and analyse your tracks. The rules place almost every
  cue on a Rekordbox phrase start, so tracks without phrase analysis are skipped.
- **Check the beat grid** on anything that looks off. A grid whose bar 1 is on the wrong beat shifts every cue; `set`
  warns when a track's phrases don't start on its downbeats.
- auto-dj knows Rekordbox's `master.db` key. Set `REKORDBOX_DB_KEY` only if a future Rekordbox changes it.

Reading works with Rekordbox open. **Writing needs Rekordbox fully quit**; auto-dj refuses otherwise.

## Next

- [Cueing your library](cueing.md): the `features` → `plan` → `review` → `apply` loop.
- [Building a set from scratch](../guides/building-a-set.md): `set`, the key check, previews and writing set cues.
- [The cue layout](../cues/hot-cues.md): what every pad and memory cue means.
