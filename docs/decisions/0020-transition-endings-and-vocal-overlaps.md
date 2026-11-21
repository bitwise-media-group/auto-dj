---
status: accepted
date: 2026-11-15
decision-makers: Deavon
---

# Finish transitions before the last 16 bars and avoid vocal overlaps

## Context and Problem Statement

[0008](0008-set-transition-placement.md) puts G on the outgoing track's OUT hot cue. OUT usually sits at the start of
the outro, and with the bass swap and fade after it, many transitions only finish in the outgoing track's last bars, so
sets keep running tracks to their very end. Transitions also ignore vocals: two vocals playing at once clash. How should
the planner choose E and G so transitions finish earlier and vocals don't overlap, and what should it do when they can't
be avoided?

## Decision Drivers

- Ending in the outgoing track's last 16 bars is acceptable when it's the only workable point, but should be the
  exception.
- Vocal overlaps are worse than an early mix-out.
- Hand-placed E and G are never moved ([0008](0008-set-transition-placement.md)); problems are flagged instead.
- The analysis must run on the Mac, without new dependencies.

## Considered Options

- Detect vocals with Apple's on-device sound classifier (SoundAnalysis) and score candidate E/G pairs
- Use Rekordbox's phrase labels (Verse, Chorus) as a proxy for vocals
- Leave transition placement as is and only warn

## Decision Outcome

Chosen option: "Detect vocals with SoundAnalysis and score candidate E/G pairs", because phrase labels don't say whether
anyone sings (instrumental "Chorus" phrases are common in dance music), and the built-in classifier recognises singing,
rapping and speech well enough in mixes (checked on Jolene (Destructo Remix): vocals in ~30% of bars; Tenebre: none;
Levels: only its vocal sample).

**Vocal analysis.** `Vocals` runs `SNClassifySoundRequest(.version1)` over the audio in 1.5 s windows every 0.75 s and
keeps each window's strongest voice label (singing, rapping, speech, choir, …). It's cached beside the features as
`<key>.vox` and computed by the same analysis step (`features`, the app's Analyse button); a track counts as analysed
when it has both. Per beat, the confidence is averaged over the bar around it; a beat has vocals at 0.3 or more.

**Where a transition finishes.** The outgoing track A leaves the mix where the previews take it out
([0012](0012-set-previews.md)): its FILTER exit plus the sweep and fade (12 beats), its CUT, else 8 beats after the bass
swap, else 40 beats after G.

**Choosing E and G.** When G isn't hand-placed (or restored from the transition cache; a G named after the next track
that sits exactly on the OUT hot cue counts as generated, since that's what the earlier rule wrote), the planner also
tries G 1 to 8 phrases before OUT (same phrase position, not before A's DROP hot cue + 8 bars, nor its first half). For
each G, E is chosen as before (IN, or an earlier beat with G's phrase position where a bass swap fits) but among those
candidates by the same cost. The pair with the lowest cost wins:

- 2 per beat where both tracks have vocals between G and where A leaves,
- 48 if A leaves within its last 16 bars (64 beats before its last audible beat),
- 6 per phrase G moves before OUT, 4 per phrase E moves before IN.

So an overlap of a bar outweighs moving G a phrase, and finishing in the last 16 bars is accepted only when nothing
within ~8 phrases avoids it. A moved G is noted on the incoming track ("G moved N bars before OUT: finishes before the
last 16 bars, no vocal overlap").

**Bass swaps need bass in both tracks (2026-11-15).** A bass swap, generated or an existing BASS SWAP memory cue, is
only used where the outgoing track has bass over the 16 beats before it and the incoming one over the 16 beats after it
(normalised level 0.45, the level `bassEndBeat` treats as bass). An existing one that fails is skipped with a warning
("BASS SWAP at beat N not used: both tracks need bass there"); with none left the transition has no bass swap. Found on
It's Alright → New Religion: an old BASS SWAP IN marker sat in New Religion's bassless breakdown, so after the swap
neither track had bass.

**Warnings.** A remaining overlap of 2 bars or more is a warning on the incoming track ("vocal overlap: … both have
vocals for N bar(s) …"), like a key clash, with `vocal_overlap` set; `set` counts them. It suggests a vocal-free 16, 8
or 4-bar loop in A, on a phrase start, ending before A's vocals begin, to hold A while B's vocals play (`vocal_loop`).

**Loops are suggested, not written (yet).** Writing the loop as an active memory loop would need, per the DJ
(2026-11-15), the EMERGENCY loop demoted to a plain loop when the set's loop is a workable mix-out (EMERGENCY is a
nice-to-have when the track has no other active loop). It's held back because active loops written to `master.db` don't
activate when played (seen in a practice set on 2026-11-15): auto-dj doesn't update Rekordbox's second copy of the cues
in `contentCue`, which the players appear to read; see [0005](0005-write-master-db-directly.md). Once it does, the loop
can be written.

### Consequences

- Good, because transitions mostly finish before the outgoing track's last 16 bars, and vocals rarely overlap.
- Good, because overlaps that remain are flagged with a loop to fix them by hand.
- Bad, because every track needs analysing again for its vocals (a few seconds each), and the classifier can miss
  heavily processed vocals or mistake lead synths for singing.
- Bad, because G now often differs from OUT, which the DJ may have to get used to.
