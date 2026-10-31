# Building a set from scratch

This guide takes ten tracks that have never seen Rekordbox all the way to a cued, ordered set with a mix you can listen
to. The tracks are the **demo set**: original house tracks that auto-dj generates, free to use for anything (CC0), so
you can follow along exactly.

Want the end result first? [Listen to the finished set](#8-listen-to-it), or run `auto-dj demo` to build it on your
machine.

## 1. Get the tracks

```sh
auto-dj demo ~/Music/auto-dj-demo --no-open
```

This renders ten 24-bit AIFF files into `~/Music/auto-dj-demo/tracks/` (about 560 MB). Rendering is deterministic, so
they're bit-for-bit the tracks this guide was built from:

--8<-- "demo/tracks.md"

They're numbered in the order the playlist is filed, which has a deliberate mistake in it: "Paper Lanterns" is third,
and its key clashes with the track before it.

## 2. Import and analyse them in Rekordbox

1. Drag `~/Music/auto-dj-demo/tracks/` into your Rekordbox collection.
2. Make sure **phrase analysis** is on (Preferences › Analysis › Phrase), then analyse the ten tracks.
3. Create a playlist called **`auto-dj demo`** and add the tracks in file-name order (01 to 10).

Then check auto-dj sees them. Freshly analysed tracks with no hot cues are in the `nohot`
[state](../cues/track-states.md):

```sh
auto-dj status
```

## 3. Decode the audio

```sh
auto-dj features
```

```text
--8<-- "demo/features.txt"
```

## 4. Plan the cues

```sh
auto-dj plan
```

```text
--8<-- "demo/plan.txt"
```

In your own library `plan` also picks up any other uncued tracks; that's fine, you'll write only these ten in step 6.
Every demo track gets the full [hot cue layout](../cues/hot-cues.md) and START, DROP and BASS SWAP memory cues:

--8<-- "demo/plan.md"

All positions are beats. Each track's bassline comes in 32 beats after its IN, which is exactly where BASS SWAP goes.

## 5. Review

```sh
auto-dj review
```

Open `~/.cache/auto-dj/review.html` and look over the ten tracks: the strips show where the bass is, and every marker
should sit on a phrase line.

## 6. Write the cues

Quit Rekordbox, then dry-run and write just the demo tracks:

```sh
auto-dj apply --only "Low Sun" "Glasshouse" "Paper Lanterns" "Night Bus" "Copper Wire" \
  "Slow Orbit" "Tidewater" "Northbound" "Afterglow" "Last Train Home"
auto-dj apply --write --only "Low Sun" "Glasshouse" "Paper Lanterns" "Night Bus" "Copper Wire" \
  "Slow Orbit" "Tidewater" "Northbound" "Afterglow" "Last Train Home"
```

`master.db` is backed up first. Open Rekordbox and load a track or two: pads A–D and H are filled, and START, DROP and
BASS SWAP are in the memory cue list. The tracks are now in the `auto` state.

## 7. Plan the set

```sh
auto-dj set "auto-dj demo"
```

The key check catches the mistake: Glasshouse (Am, 8A) into Paper Lanterns (F#m, 11A) is three steps round the Camelot
wheel. auto-dj suggests an order that keeps the first track, fixes the clash and keeps every other neighbour:

```text
--8<-- "demo/set-check.txt"
```

Take the suggestion and render a preview while you're at it:

```sh
auto-dj set "auto-dj demo" --order suggested --preview-dir ~/Desktop
```

```text
--8<-- "demo/set-suggested.txt"
```

Every transition has the same shape here, because the tracks were built the same way:

- **G** on the outgoing track sits at its OUT (beat 321 on most), and **E** on the incoming one at its IN;
- the incoming bassline arrives 32 beats later, so the planned BASS SWAP memory cue is renamed **BASS SWAP IN**
  (`rename`), and the outgoing track gets **BASS SWAP OUT** at the same moment;
- the first track's E is START and the last track (Paper Lanterns, now) gets no G.

[Set cues](../cues/set-cues.md) explains each of these.

## 8. Listen to it

`set` also wrote a set-list page (in `~/Desktop/auto-dj-demo/`) with every transition and the whole set as one mix,
played at 128 BPM. This is the demo set's, built by the docs:

<div markdown="0">
  <iframe src="../../demo/preview/index.html" title="auto-dj demo set preview" loading="lazy"
    style="width:100%;height:720px;border:1px solid var(--bw-line);border-radius:10px;background:var(--bw-bg)"></iframe>
</div>

[Open the preview on its own page](../demo/preview/index.html){ .md-button }

## 9. Write the set

Happy with it? Quit Rekordbox and write the set cues, saving the suggested order to the playlist:

```sh
auto-dj set "auto-dj demo" --order suggested --write --reorder
```

Open Rekordbox: the playlist is in its new order, every track has its E and G pads named after its neighbours, and the
BASS SWAP IN / OUT markers line up across each transition. Re-export or sync your USB stick, and the set's ready to
play.

!!! note "Why your numbers might differ"

    The outputs on this page come from `auto-dj demo`, which uses the generator's own beat grid and phrases in place of
    Rekordbox's analysis ([ADR 0014](../decisions/0014-generated-demo-set.md)). Rekordbox should find the same
    structure, but if it labels a phrase or spells a key differently, a cue can land a phrase away from what's shown.
