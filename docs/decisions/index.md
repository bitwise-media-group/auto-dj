# Decisions

Architecture decision records for auto-dj, in [MADR](https://adr.github.io/madr/) format. Each record says what was
decided, why, and what it was checked against. Read the relevant ones before changing a rule, a threshold or how cues
are written.

| ADR                                               | Decision                                                           | Date       |
| ------------------------------------------------- | ------------------------------------------------------------------ | ---------- |
| [0001](0001-cue-template.md)                      | Use one hot cue and memory cue template on every track             | 2026-10-14 |
| [0002](0002-analysis-inputs.md)                   | Place cues from Rekordbox's grid and phrases plus a bass analysis  | 2026-10-14 |
| [0003](0003-cue-placement-rules.md)               | Place each cue with phrase-grid rules scored against hand cues     | 2026-10-14 |
| [0004](0004-track-states.md)                      | Only cue tracks in a generated state, and never touch rated tracks | 2026-10-14 |
| [0005](0005-write-master-db-directly.md)          | Write cues straight into Rekordbox's encrypted master.db           | 2026-10-14 |
| [0006](0006-migrate-older-cue-layouts.md)         | Migrate older hand-cued layouts onto the template, losslessly      | 2026-10-14 |
| [0007](0007-harmonic-key-check.md)                | Check set keys against Mixed In Key's harmonic chart               | 2026-10-14 |
| [0008](0008-set-transition-placement.md)          | Place set transitions in beats, aligned on phrases                 | 2026-10-14 |
| [0009](0009-sets-own-e-and-g.md)                  | Sets own the E and G pads, backed by a transition cache            | 2026-10-14 |
| [0010](0010-memory-cue-colours-and-renames.md)    | Recolour and normalise memory cue names on set tracks              | 2026-10-16 |
| [0011](0011-transition-markers-on-both-tracks.md) | Write every transition marker on both tracks, named by side        | 2026-10-16 |
| [0012](0012-set-previews.md)                      | Render set previews offline with ffmpeg, at a fixed set tempo      | 2026-10-16 |
| [0013](0013-port-to-go.md)                        | Port rekordbox-cue to Go as auto-dj                                | 2026-10-30 |
| [0014](0014-generated-demo-set.md)                | Generate the demo set in code and build its walkthrough offline    | 2026-10-30 |

## Adding a record

Copy the shape of an existing record: front matter (`status`, `date`, `decision-makers`), then _Context and Problem
Statement_, _Considered Options_, _Decision Outcome_ with its _Consequences_, and optionally _Decision Drivers_,
_Confirmation_, _Pros and Cons of the Options_ and _More Information_. Number it with the next four-digit prefix, add it
to the table above and to the `Decisions` section of `nav` in `zensical.toml`. When a decision changes, amend its record
with a dated note, or supersede it with a new one (`status: superseded by [00NN](…)`).
