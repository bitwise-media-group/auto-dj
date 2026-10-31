---
status: accepted
date: 2026-10-16
decision-makers: Deavon
---

# Write every transition marker on both tracks, named by side

## Context and Problem Statement

A transition has moments both decks care about: where the bass swaps, and where the outgoing track leaves the mix on a
filter or a cut. With a marker on only one track, the other deck can't see it coming, and when a track moves to another
set its old markers are hard to tell apart from the new ones.

## Considered Options

- One marker on each track, named by side (`… IN` on the incoming B, `… OUT` on the outgoing A)
- A single marker on the incoming track only

## Decision Outcome

Chosen option: "One marker on each track, named by side", because a track's OUT markers are then easy to find and
replace when it goes into another set.

Every marker is written on both tracks at the same moment (B beat = E + (A beat − G), see
[0008](0008-set-transition-placement.md)):

- **Bass swap.** B gets `BASS SWAP IN` and A gets `BASS SWAP OUT`. When the bass comes in on one of B's drops there's no
  BASS SWAP IN, but A still gets BASS SWAP OUT.
- **Exit.** A leaves the mix at the first FILTER / CUT memory cue at or after G in A (plain or `… OUT`), or at or after
  E in B (plain or `… IN`) while A is still playing. That cue becomes `FILTER OUT` / `CUT OUT` on A and `FILTER IN` /
  `CUT IN` on B.
- **CUT precedence (decision 2026-10-17).** A CUT in B beats a CUT in A: when Dracul's `CUT-OUT RES` and ResuRection's
  `CUT-IN DRACUL` were 32 beats apart in "Trance Set", the next track's CUT IN set the cut.
- **Instant mashups (decision 2026-10-17).** A SYNC memory cue (plain or `SYNC OUT`) within a beat of A's G, or (plain
  or `SYNC IN`) within a beat of B's E, makes B come in at E at full volume with no fade-in. `set` puts `SYNC OUT` on
  A's G and `SYNC IN` on B's E. Voicemail → Children in "Trance Set" is one: Children's `SYNC IN` sits on its E
  (`VOICEMAIL`).
- A plain cue already within a beat of the marker gets the side added instead of a second cue.

Markers from an earlier order otherwise stay until removed by hand, with two exceptions that `set --write` deletes
(`setlist.staleCues`):

- A CUT OUT memory cue more than a beat from this set's CUT OUT marker: it has no CUT IN on the next track. That covers
  every CUT OUT on the last track, but none on a track whose next track has no analysis.
- A JUMP memory cue on the same beat as a JUMP hot cue, a duplicate.

### Consequences

- Good, because both decks show the swap and the exit at the same moment.
- Bad, because markers from an earlier running order linger until removed by hand (apart from the two cases above).

## More Information

On "Melodic Dark", two exits came from cues in the incoming track (Rej's FILTER DOWN, Heart on Hold's CUT), both 8 to 24
beats before that track's drop.
