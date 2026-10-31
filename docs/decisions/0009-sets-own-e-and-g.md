---
status: accepted
date: 2026-10-14
decision-makers: Deavon
---

# Sets own the E and G pads, backed by a transition cache

## Context and Problem Statement

E and G are the DJ's pads ([0001](0001-cue-template.md)), but `set` has to write a transition's E/G pair. A track has
only one E and one G, while it can appear in many sets. Who owns those pads, and how is an older set's pair kept?

## Considered Options

- A set owns E and G on its tracks, and every pair is kept in a transition cache
- Never overwrite an existing E/G

## Decision Outcome

Chosen option: "A set owns E and G", because the set being prepared is the one about to be played, and the cache means
no pair is ever lost.

- A set overwrites E/G that belong to other sets, fixes misaligned pairs by moving E onto the phrase, and clears the
  last track's G. It never touches F, which holds jumps.
- Existing E/G cues for the same neighbours are kept, even with typos like `DIALOG` or `RAJ`, unless they're misaligned.
- Every pair is kept in a **transition cache** (`~/Library/Pioneer/_cue_work/transitions.json`). It's filled from the
  library before each run and from every write, with old values kept in `history`. Pairs found there are restored when
  the same two tracks meet again.

### Consequences

- Good, because preparing one set never loses another set's transitions for good.
- Bad, because Rekordbox only shows the latest set's E/G on a track; switching sets means re-running `set --write`.
