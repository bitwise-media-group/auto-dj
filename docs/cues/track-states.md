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

E and G pads and `set`'s transition markers (BASS SWAP / FILTER / CUT / SYNC IN and OUT) don't count: `set` owns them,
so a track with only those is still `nohot`. Every write that includes tracks (`set --write`, `build-set --write`,
`recording --write`, Save as Playlist in the app) first gives its `mik` and `nohot` tracks the cues `apply --write`
would, and adds them to the ledger, so a newly imported track gets the template the first time auto-dj writes it
([ADR 0022](../decisions/0022-cue-template-on-every-write.md)). Rated tracks never get it.

## Rate a track once you've checked it

Rating moves a track from `auto` to `manual`: auto-dj won't touch it again, and your corrections become the yardstick
for the next rule change. A track you fixed but didn't rate is still `auto`, so a later `plan --categories auto` would
re-cue it.

The one exception to "never modified" is [`set --write`](set-cues.md), which by design writes E/G and transition
markers, recolours and renames memory cues, and renames `JUMP <label>` pads on the set's tracks, rated or not.
