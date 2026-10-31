# Set cues

A set is a Rekordbox playlist in running order. For every transition A → B, [`auto-dj set`](../commands/set.md) writes
cues on both tracks so the mix is planned before you play it.

## E, G and the bass swap

- **A gets G**, named after B, at A's OUT: start mixing out here.
- **B gets E**, named after A, at B's IN: start B here when A reaches G. E moves earlier if it must, so the bass swap
  lands before A runs out, and it always sits at the same phrase position as A's G.
- **B gets BASS SWAP IN** and **A gets BASS SWAP OUT** at the same moment: a phrase start in both tracks, at least 16
  beats after E, where B's bass comes in or A's goes. If B's bass comes in on one of its drops, B gets no BASS SWAP IN
  (the DROP already marks it); A still gets its OUT.

Everything is measured in beats, because the decks are beat-matched: when A reaches G, B is at E, so B's beat = E + (A's
beat − G). Two Low Sun → Glasshouse lanes from the [demo set](../guides/building-a-set.md), lined up on that clock:

<div class="ad-tl" style="width:63.84%" markdown="0">
  <div class="ad-tl__bar">
    <span class="intro" style="width:14.16%">Intro</span>
    <span class="up" style="width:14.16%">Up</span>
    <span class="chorus" style="width:14.16%">Chorus</span>
    <span class="down" style="width:14.16%">Down</span>
    <span class="chorus" style="width:28.32%">Chorus</span>
    <span class="outro" style="width:15.04%">Outro</span>
  </div>
  <i class="ad-tl__m ad-tl__m--hot" style="left:0%">Low Sun (A)</i>
  <i class="ad-tl__m ad-tl__m--hot" style="left:70.80%">G GLASSHOUSE</i>
  <i class="ad-tl__m ad-tl__m--mem" style="left:77.88%">BASS SWAP OUT</i>
</div>
<div class="ad-tl" style="width:63.84%;margin-left:36.16%" markdown="0">
  <div class="ad-tl__bar">
    <span class="intro" style="width:14.16%">Intro</span>
    <span class="up" style="width:14.16%">Up</span>
    <span class="chorus" style="width:14.16%">Chorus</span>
    <span class="down" style="width:14.16%">Down</span>
    <span class="chorus" style="width:28.32%">Chorus</span>
    <span class="outro" style="width:15.04%">Outro</span>
  </div>
  <i class="ad-tl__m ad-tl__m--hot ad-tl__m--high" style="left:14.16%">E LOW SUN</i>
  <i class="ad-tl__m ad-tl__m--hot" style="left:21.24%">Glasshouse (B)</i>
  <i class="ad-tl__m ad-tl__m--mem" style="left:21.24%">BASS SWAP IN</i>
</div>

Glasshouse comes in at its IN (beat 65) while Low Sun plays from its OUT (beat 321); 32 beats later Glasshouse's
bassline arrives and Low Sun's bass goes, so both tracks carry the same marker at the same moment.

## How A leaves the mix

auto-dj looks for an exit cue you placed: the first FILTER or CUT memory cue at or after G in A, or at or after E in B
while A is still playing. It becomes **FILTER OUT** / **CUT OUT** on A and **FILTER IN** / **CUT IN** on B. A CUT you
put in B beats one in A. With no exit cue, A fades out over 8 beats from the bass swap (in the previews).

A **SYNC** memory cue on A's G or B's E makes the transition an **instant mashup**: B drops in at full volume, and the
cues become SYNC OUT on A's G and SYNC IN on B's E.

## First and last track

The first track's E is `START` (its first downbeat). The last track's G is cleared.

## Names

E and G are named after the other track's title, in capitals, without the mix name or a leading "The": "The Lost Hawk
(Original Mix)" → `LOST HAWK`, "Don't Wake Up" → `DONT WAKE UP`.

## A track in several sets

A track has one E and one G, but it can be in many sets. The set you're preparing **owns** them: `set --write`
overwrites E/G that belong to another set. Nothing is lost, though: every E/G pair in the library, and every pair a set
writes, is kept in a **transition cache** (`~/Library/Pioneer/_cue_work/transitions.json`). When two tracks meet again
in another playlist, their pair is restored from it. Existing E/G cues for the same neighbours are kept as they are,
typos included, unless they're off the phrase; then E is moved onto it
([ADR 0009](../decisions/0009-sets-own-e-and-g.md)).

## Clean-up on write

`set --write` also tidies the set's tracks:

- recolours and renames memory cues ([Memory cues](memory-cues.md#yours));
- renames `JUMP <label>` hot cues to `JUMP` (the only change it makes to your pads);
- deletes a CUT OUT memory cue that has no matching CUT IN on the next track;
- deletes a JUMP memory cue on the same beat as a JUMP hot cue (a duplicate).

F and every other cue are never touched.

## Warnings

The `set` report flags anything worth a listen:

- an E/G pair that doesn't line up on the phrase, where letting A play out wouldn't start a new phrase in B either;
- a bass swap that only happens after A's bass has ended;
- a track whose bar grid disagrees with Rekordbox's phrases (bar 1 is probably on the wrong beat);
- a hand-placed E, G, OUT or BASS SWAP that's off the phrase. It's **kept** (you placed it), and the preview follows it.

The full reasoning is in ADRs [0008](../decisions/0008-set-transition-placement.md) and
[0011](../decisions/0011-transition-markers-on-both-tracks.md).
