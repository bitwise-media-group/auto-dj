---
status: accepted
date: 2026-11-01
decision-makers: Deavon
---

# Build sets from intelligent playlists by evaluating their conditions

## Context and Problem Statement

`set` only read normal playlists: their tracks and order are rows in `djmdSongPlaylist`. Intelligent playlists
(`djmdPlaylist.Attribute` 4) have no rows there. Rekordbox matches the collection against conditions stored as XML in
`djmdPlaylist.SmartList` each time the playlist is shown:

```xml
<NODE Id="-185693195" LogicalOperator="1" AutomaticUpdate="0">
  <CONDITION PropertyName="counter" Operator="1" ValueUnit="" ValueLeft="" ValueRight=""/>
</NODE>
```

How should `set` get an intelligent playlist's tracks, and in what order?

## Decision Drivers

- The same tracks Rekordbox shows, or a clear error, never a silently different set.
- `set` reads master.db only, with Rekordbox open or not.

## Considered Options

- Evaluate the conditions as SQL over `djmdContent`
- Ask the user to copy the tracks into a normal playlist first

## Decision Outcome

Chosen option: "Evaluate the conditions as SQL", because it needs nothing from Rekordbox and the format is small: a list
of conditions joined by all (`LogicalOperator` 1) or any (2), each a property, an operator (1 is, 2 is not, 3 greater, 4
less, 5 in range, 6 / 7 in / not in the last N days or months, 8 / 9 contains / doesn't, 10 starts with, 11 ends with)
and one or two values. `db.smartWhere` compiles them (`internal/db/smartlist.go`):

- Text properties (title, artist, album, album artist, original artist, remixer, producer, genre, label, key, comments,
  file name, mix name) match case-insensitively, as Rekordbox does.
- Numbers: BPM, duration (seconds), rating (stars), play count and year. Dates (added, created, released) compare as
  `YYYY-MM-DD`; "in the last N" counts back from today. Colour (`grouping`) compares `ColorID`. My Tag checks
  `djmdSongMyTag`, with the tag ID stored as a signed 32-bit integer.
- An empty value means none: 0, no text, no date or no colour. Rekordbox's own "Never Played" and "Unrated" lists are
  `counter` and `rating` is ''.
- Anything else (an unknown property, operator, unit or value) is an error naming the condition.

The tracks are numbered in the order they were added to the collection (`created_at`), which is what `--order 1,3,2`
refers to. `--order suggested` is the usual way to use one.

### Consequences

- Good, because a set can be built from a filter ("Deep House, 120–124 BPM, rated") without keeping a playlist in sync.
- Bad, because Rekordbox orders an intelligent playlist itself, so `--reorder` is refused for one: the order is kept in
  the set plan, the preview and the cues only. Copy the tracks to a normal playlist to save it.
- Bad, because the conditions are re-implemented, so a Rekordbox change to the format or to a property's meaning shows
  up as an error or a different track list until it is followed here.
- Neutral, because the case folding is ASCII only (SQLite's `lower` and `like`), so "É" and "é" don't match each other.

### Confirmation

`internal/db/smartlist_test.go` covers every property and operator on a synthetic library. On the author's library
(2026-11-01), `Never Played`, `Rated`, `Unrated` and `2020s` load 113, 34, 229 and 242 tracks, the counts of the
matching `djmdContent` rows.
