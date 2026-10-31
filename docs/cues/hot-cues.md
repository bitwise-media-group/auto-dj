# Hot cues

Every track gets the same pads, so A always means "start mixing in here" and D always means "start mixing out", whatever
is loaded. The layout was learned from the library's hand-cued tracks ([ADR 0001](../decisions/0001-cue-template.md)).

<div class="ad-deck" markdown="0">
  <div class="ad-deck__mode"><span>HOT CUE</span></div>
  <div class="ad-pads">
    <div class="ad-pad" style="--pad:#ff2d3d">
      <div class="ad-pad__face"><b>A</b><span>IN</span></div>
      <small>start mixing in</small>
    </div>
    <div class="ad-pad" style="--pad:#19d3e0">
      <div class="ad-pad__face"><b>B</b><span>BRIDGE</span></div>
      <small>the breakdown</small>
    </div>
    <div class="ad-pad" style="--pad:#b5e61d">
      <div class="ad-pad__face"><b>C</b><span>DROP</span></div>
      <small>first drop after it</small>
    </div>
    <div class="ad-pad" style="--pad:#8f5bff">
      <div class="ad-pad__face"><b>D</b><span>OUT</span></div>
      <small>start mixing out</small>
    </div>
    <div class="ad-pad" style="--pad:#1fd46a">
      <div class="ad-pad__face"><b>E</b><span>TRACK</span></div>
      <small>yours · set IN point</small>
    </div>
    <div class="ad-pad" style="--pad:#ff3d9e">
      <div class="ad-pad__face"><b>F</b><span>JUMP</span></div>
      <small>yours · never written</small>
    </div>
    <div class="ad-pad" style="--pad:#2f6bff">
      <div class="ad-pad__face"><b>G</b><span>TRACK</span></div>
      <small>yours · set OUT point</small>
    </div>
    <div class="ad-pad" style="--pad:#ff8a1f">
      <div class="ad-pad__face"><b>H</b><span>EMERGENCY</span></div>
      <small>32-beat active loop</small>
    </div>
  </div>
</div>

## The pads

| Pad   | Name           | What it's for                                                                   | Where auto-dj puts it                                                                                                 |
| ----- | -------------- | ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| **A** | **IN**         | A good place to start mixing the track in                                       | The first phrase after Rekordbox's Intro, between beats 33 and 129                                                    |
| **B** | **BRIDGE**     | The breakdown: little or no drums or bass. Handy for mashups                    | The first long low-bass run (64+ beats) after the first chorus. **No bridge** if every breakdown is under 16 beats    |
| **C** | **DROP**       | The first drop after the bridge                                                 | The first Chorus phrase after the breakdown                                                                           |
| **D** | **OUT**        | A good place to start mixing out                                                | A phrase with bass, 32–128 beats before EMERGENCY (64 if it can)                                                      |
| **H** | **EMERGENCY**  | An active loop that can run forever and buy you time when the next track's late | 32 beats in the outro that have bass throughout, ending at least 8 beats before the end, usually 15–30 s from the end |
| E     | _a track name_ | Where to bring this track in when the named track is playing                    | Never by `plan`. [`set`](set-cues.md) writes it for the set you're preparing                                          |
| F     | jumps, tricks  | JUMP, JUMP TO DROP, ROLL 145, CROSS-MIX, EXIT LOOP…                             | Never. `set` only renames `JUMP <label>` pads to `JUMP`                                                               |
| G     | _a track name_ | Where to start mixing out into the named track                                  | Never by `plan`. `set` writes it for the set you're preparing                                                         |

"Bridge" is the template's word for what's usually called the **breakdown**. Rekordbox's phrase analysis calls it "Down"
in high-mood tracks and "Bridge" in mid- and low-mood ones.

All positions snap to the phrase grid: Rekordbox phrase starts plus every 16 beats from the first downbeat. The exact
rules and how well they match hand-placed cues are in [ADR 0003](../decisions/0003-cue-placement-rules.md).

## On a real track

"Low Sun", the first track of the [demo set](../guides/building-a-set.md), cued by `auto-dj plan`. Hot cues are above
the phrases, memory cues below; the hatched band is the EMERGENCY loop.

<div class="ad-tl" markdown="0">
  <div class="ad-tl__bar">
    <span class="intro" style="width:14.16%">Intro</span>
    <span class="up" style="width:14.16%">Up</span>
    <span class="chorus" style="width:14.16%">Chorus</span>
    <span class="down" style="width:14.16%">Down</span>
    <span class="chorus" style="width:28.32%">Chorus</span>
    <span class="outro" style="width:15.04%">Outro</span>
  </div>
  <div class="ad-tl__loop" style="left:84.96%;width:7.08%"></div>
  <i class="ad-tl__m ad-tl__m--hot" style="left:14.16%">A IN</i>
  <i class="ad-tl__m ad-tl__m--hot" style="left:42.48%">B BRIDGE</i>
  <i class="ad-tl__m ad-tl__m--hot" style="left:56.64%">C DROP</i>
  <i class="ad-tl__m ad-tl__m--hot" style="left:70.80%">D OUT</i>
  <i class="ad-tl__m ad-tl__m--hot" style="left:84.96%">H EMERGENCY</i>
  <i class="ad-tl__m ad-tl__m--mem" style="left:0%">START</i>
  <i class="ad-tl__m ad-tl__m--mem" style="left:21.24%">BASS SWAP</i>
  <i class="ad-tl__m ad-tl__m--mem" style="left:56.64%">DROP</i>
</div>

IN sits where the groove starts (beat 65), the bassline arrives 32 beats later (BASS SWAP, beat 97), the breakdown is B,
the drop C, and the track hands over at D, a phrase before the outro, with the EMERGENCY loop in reserve.

## Rules of thumb

- **A–D and H are auto-dj's; E, F and G are yours.** `plan` and `apply` never write E/F/G. `set` writes E and G for the
  set you're preparing, and keeps every pair it replaces (see [Set cues](set-cues.md)).
- **BASS SWAP is never a hot cue.** It's a memory cue on the incoming track.
- **No bridge is a valid answer.** If a track has no breakdown of at least 16 beats, B stays empty.
- **H can be yours too.** A track whose H holds your own cue (JUMP, ECHO OFF…) gets no EMERGENCY.
- **Your active loop wins.** If the track already has an active loop of yours (a memory cue or an E/F/G pad), EMERGENCY
  is written as a plain loop that only loops when you trigger it.
