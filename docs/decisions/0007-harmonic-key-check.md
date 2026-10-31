---
status: accepted
date: 2026-10-14
decision-makers: Deavon
---

# Check set keys against Mixed In Key's harmonic chart

## Context and Problem Statement

`auto-dj set` checks that consecutive tracks in a playlist are in compatible keys and suggests an order when they clash.
The DJ asked for keys that match within ±2 semitones. What exactly counts as compatible?

## Decision Drivers

- Fifth moves (F#m → C#m) are the most harmonic moves and appear throughout the DJ's own sets.
- The suggested order should disturb the DJ's running order as little as possible.

## Considered Options

- Compare tonics literally, within ±2 semitones
- Mixed In Key's harmonic chart (Camelot), with energy boosts

## Decision Outcome

Chosen option: "Mixed In Key's harmonic chart", because a literal tonic comparison would reject fifth moves.

- Same key, Camelot ±1 and relative major/minor are free.
- ±2 semitones (Camelot ±2) and ±1 semitone (Camelot ±7) are allowed "energy boost" moves with a small cost.
- Anything else is a clash.

On a clash, an order is suggested. It's the cheapest path (exact search up to 14 tracks, local search above that) that
keeps the first track and as many existing neighbours as possible. `--free-start` lets it change the first track.

### Consequences

- Good, because the check agrees with the moves the DJ already makes.
- Neutral, because the suggestion is only applied with `--order suggested`, and only saved to the playlist with
  `--write --reorder`.
