# Track states

Before it plans anything, auto-dj puts every track in one of five states. The state decides whether auto-dj may touch it
([ADR 0004](../decisions/0004-track-states.md)). `auto-dj status` counts them.

| State      | What it is                                                                                      | What happens                                                                        |
| ---------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| **manual** | Rated (1–5 stars), or has your own IN / DROP / OUT cues                                         | Never modified. Used by `evaluate` to score the rules                               |
| **mik**    | Only generated cues: `Energy N` (Mixed In Key), `CUE(Auto)` (Rekordbox), optionally a START pad | Cued by default                                                                     |
| **nohot**  | No hot cues at all                                                                              | Cued by default. Generated memory cues are replaced; memory cues you named are kept |
| **auto**   | Cued by auto-dj and not rated yet                                                               | Re-cued only with `plan --categories auto`. Your E/F/G notes are kept               |
| **other**  | Anything else                                                                                   | Left alone                                                                          |

A track is `auto` because it's in the **ledger**, `~/Library/Pioneer/_cue_work/applied-tracks.json`, which
`apply --write` adds to.

## Rate a track once you've checked it

Rating moves a track from `auto` to `manual`: auto-dj won't touch it again, and your corrections become the yardstick
for the next rule change. A track you fixed but didn't rate is still `auto`, so a later `plan --categories auto` would
re-cue it.

The one exception to "never modified" is [`set --write`](set-cues.md), which by design writes E/G and transition
markers, recolours and renames memory cues, and renames `JUMP <label>` pads on the set's tracks, rated or not.
