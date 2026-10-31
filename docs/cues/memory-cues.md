# Memory cues

Memory cues mark moments rather than jump points. `plan` places three kinds; `set` adds transition markers; the rest are
yours, and `set` gives them consistent names and colours
([ADR 0010](../decisions/0010-memory-cue-colours-and-renames.md)).

## Placed by `plan`

| Cue           | Colour                                                  | Where                                                                                                                                                           |
| ------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **START**     | <span class="ad-swatch ad-swatch--red"></span>red       | The first downbeat: beat 1 of the first full bar                                                                                                                |
| **DROP**      | <span class="ad-swatch ad-swatch--green"></span>green   | Every drop: the bass returning after at least 32 low-bass beats, on a Chorus phrase, before OUT (plus the C DROP pad). Drops closer than 32 beats are merged    |
| **BASS SWAP** | <span class="ad-swatch ad-swatch--orange"></span>orange | Where the bassline comes in, on a phrase, at least 16 beats after IN and before the bridge. This is where you swap the bass from the outgoing track to this one |

## Placed by `set`

`set` writes transition markers on **both** tracks of a transition, at the same moment, named by side: `… OUT` on the
outgoing track, `… IN` on the incoming one. See [Set cues](set-cues.md).

| Cue                    | Colour                                                  | Meaning                                                            |
| ---------------------- | ------------------------------------------------------- | ------------------------------------------------------------------ |
| **BASS SWAP IN / OUT** | <span class="ad-swatch ad-swatch--orange"></span>orange | The bass moves from the outgoing track to the incoming one         |
| **FILTER IN / OUT**    | <span class="ad-swatch ad-swatch--purple"></span>purple | The outgoing track filters out here                                |
| **CUT IN / OUT**       | <span class="ad-swatch ad-swatch--blue"></span>blue     | The outgoing track is cut here                                     |
| **SYNC IN / OUT**      | <span class="ad-swatch ad-swatch--aqua"></span>aqua     | An instant mashup: the incoming track drops in at full volume on E |

## Yours

Place these by hand; `set` recolours them on the tracks of the set it writes (rated tracks included), so they read the
same on every deck:

| Name     | Colour                                                  | Typical use                                                        |
| -------- | ------------------------------------------------------- | ------------------------------------------------------------------ |
| IN, LATE | <span class="ad-swatch ad-swatch--red"></span>red       | Alternative mix-in points                                          |
| VOCAL    | <span class="ad-swatch ad-swatch--yellow"></span>yellow | A vocal starts                                                     |
| FILTER   | <span class="ad-swatch ad-swatch--purple"></span>purple | Filter this track out from here (becomes FILTER IN / OUT in a set) |
| CUT      | <span class="ad-swatch ad-swatch--blue"></span>blue     | Cut this track here (becomes CUT IN / OUT in a set)                |
| JUMP     | <span class="ad-swatch ad-swatch--pink"></span>pink     | Jump to the JUMP hot cue here (previews follow it)                 |
| SYNC     | <span class="ad-swatch ad-swatch--red"></span>red       | On a transition's E or G: make it an instant mashup                |

Names are matched case-insensitively. `set` also normalises a few spellings first:

| You wrote                                         | It becomes       |
| ------------------------------------------------- | ---------------- |
| FILTER DOWN, LOW PASS                             | FILTER           |
| OUT (a memory cue, not the D pad)                 | CUT OUT          |
| anything with CUT-OUT / CUT-IN (CUT-OUT RES…)     | CUT OUT / CUT IN |
| JUMP TO DROP, JUMP TO BRIDGE… (hot cues included) | JUMP             |

Any other memory cue name is left alone, and the `set` report warns about it so you can spot typos.

## Colour codes

Rekordbox stores a memory cue's colour as `djmdCue.Color`, 0-based: 0
<span class="ad-swatch ad-swatch--pink"></span>pink, 1 <span class="ad-swatch ad-swatch--red"></span>red, 2
<span class="ad-swatch ad-swatch--orange"></span>orange, 3 <span class="ad-swatch ad-swatch--yellow"></span>yellow, 4
<span class="ad-swatch ad-swatch--green"></span>green, 5 <span class="ad-swatch ad-swatch--aqua"></span>aqua, 6
<span class="ad-swatch ad-swatch--blue"></span>blue, 7 <span class="ad-swatch ad-swatch--purple"></span>purple. More
database detail is in [ADR 0005](../decisions/0005-write-master-db-directly.md).
