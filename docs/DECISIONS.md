# Cue layout and design decisions

This file records how the cue layout was worked out from Deavon's own library on 2026-10-14, what the rules do, how well
they scored, and the Rekordbox details needed to write cues safely. The tool was written in Python as `rekordbox-cue`
and ported to Go as `adj` on 2026-10-30 (§9).

## 1. The cue template (learned from 34 rated tracks + 17 hand-named unrated tracks)

Every hand-cued track uses the same layout. "Rated" (1–5 stars) means Deavon cued the track by hand.

### Hot cues

| Slot | Name             | Meaning                                                                                   | Where it usually sits                                                                                      |
| ---- | ---------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| A    | **IN**           | A good place to start mixing the track in                                                 | Start of the first phrase after the intro: beat 33 or 65, sometimes 1, 97 or 129                           |
| B    | **BRIDGE**       | The breakdown: little or no drums/bass; used for mashups                                  | Start of the main mid-track breakdown (Rekordbox "Down" phrase)                                            |
| C    | **DROP**         | The first drop after the bridge                                                           | First "Chorus" phrase after the breakdown                                                                  |
| D    | **OUT**          | A good place to start mixing out                                                          | A Chorus phrase about 64 beats (32–128) before EMERGENCY                                                   |
| H    | **EMERGENCY**    | Active loop that can run forever to buy mixing time                                       | 32-beat loop (sometimes 64) in the outro, ending before the bass runs out, usually ~15–30 s before the end |
| E    | _track name_     | Reserved IN point: where to bring this track in when the named track is playing before it | First half of the track                                                                                    |
| F    | jumps / specials | In-song jumps and tricks: JUMP, JUMP TO DROP, ROLL 145, CROSS-MIX, EXIT LOOP…             | Anywhere                                                                                                   |
| G    | _track name_     | Reserved OUT point: where to start mixing out into the named next track                   | Second half of the track                                                                                   |

E, F and G (and H when it isn't EMERGENCY) hold Deavon's own cues: other track names, JUMP, CUT, ECHO and so on. **The
tool never writes to them**, except `set`: it owns E/G and renames `JUMP <label>` pads to JUMP (§5c). Generic markers
don't belong on pads. BASS SWAP in particular is **always a memory cue** in the incoming track.

"Bridge" is Deavon's word. The usual dance-music term is **breakdown**. Rekordbox's phrase analysis calls it "Down" for
high-mood tracks and "Bridge" for mid/low-mood tracks.

### Memory cues

| Name                                                    | Colour (`djmdCue.Color`) | Rule                                                                                                                  |
| ------------------------------------------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| **START**                                               | 1 (red)                  | First beat of the first full bar (first downbeat in the grid)                                                         |
| **DROP**                                                | 4 (green)                | Every drop: bass returning after a breakdown. 1–3 per track                                                           |
| **BASS SWAP**                                           | 2 (orange)               | ≥ 4 bars (16 beats) after IN, where the bassline spikes in on a phrase boundary. Always a memory cue, never a hot cue |
| (set) BASS SWAP IN / OUT, FILTER IN / OUT, CUT IN / OUT | orange / purple / blue   | Transition markers from `set`, one per side (§5c)                                                                     |
| (set) SYNC IN / OUT                                     | 5 (aqua)                 | Instant-mashup markers from `set` on A's G and B's E (§5c)                                                            |
| (hand-only) IN, LATE                                    | 1 (red)                  | Not generated; `set` recolours them                                                                                   |
| (hand-only) FILTER                                      | 7 (purple)               | Not generated; `set` recolours them                                                                                   |
| (hand-only) VOCAL                                       | 3 (yellow)               | Not generated; `set` recolours them                                                                                   |
| (hand-only) JUMP                                        | 0 (pink)                 | Not generated; `set` recolours them. Previews jump to the JUMP hot cue there (§5c)                                    |
| (hand-only) CUT                                         | 6 (blue)                 | Not generated; `set` recolours them                                                                                   |
| (hand-only) SYNC                                        | 1 (red)                  | Not generated; `set` recolours them. On A's G or B's E: an instant mashup (§5c)                                       |
| (hand-only) FILTER DOWN, LOW PASS                       | → FILTER                 | Not generated; `set` renames them FILTER (purple)                                                                     |
| (hand-only) CUT-OUT…, CUT-IN… (e.g. CUT-OUT RES)        | → CUT OUT / CUT IN       | Not generated; `set` renames them (blue)                                                                              |
| (hand-only) JUMP … (e.g. JUMP TO DROP)                  | → JUMP                   | Not generated; `set` renames them, hot cues included                                                                  |
| (hand-only) OUT                                         | → CUT OUT                | Not generated; `set` renames it CUT OUT (blue)                                                                        |
| (hand-only) any other name                              | as set by hand           | Not generated; `set` warns about them                                                                                 |

### Other user rules (stated during the session)

- If the breakdown is **shorter than 16 beats, there is no bridge**. Not every song has one.
- The Mixed In Key tracks (cues named `Energy N`) are the priority. Rekordbox's own `CUE(Auto)` memory cues are poor and
  get replaced too, as do tracks with no hot cues at all. Tracks the user has hand-named or rated are never touched by
  the tool.
- Everything should follow standard house phrasing (8/16/32-bar blocks).

## 2. Inputs

- **Rekordbox beat grid** (`ANLZ0000.DAT`, tag `PQTZ`): beat times and beat-in-bar.
- **Rekordbox phrase analysis** (`ANLZ0000.EXT`, tag `PSSI`): phrase starts and labels. Mid/low-mood labels are
  collapsed: Verse* → Up, Bridge → Down. This was the most useful single signal: almost every hand cue sits exactly on a
  Rekordbox phrase start.
- **Audio features** (`internal/features`): ffmpeg decodes to 11 kHz mono, then FFT band energies per beat. The _sub
  band (30–120 Hz)_ is the bass/kick indicator. Each track is normalised so its loudest 5% ≈ 1.0. "No bass" < 0.35,
  "bass present" ≥ 0.45. Streaming tracks have no local audio, so those get phrase-only rules.
- Mixed In Key's own `Energy N` cue positions are **not used**. They mark section changes, but Rekordbox phrases are
  more precise.

## 3. Rules (`internal/rules`)

All positions snap to a grid: Rekordbox phrase starts plus every 16 beats from the first downbeat.

1. **IN**: start of the first phrase after Rekordbox's Intro, clamped to beats 33–129 (else the first phrase start in
   that range, else beat 33).
2. **EMERGENCY**: find where the bass ends (last 16-beat window with bass ≥ 0.45). Pick the grid point nearest
   `last_beat − 68` (8-beat bonus for real phrase starts) such that the 32-beat loop has bass throughout, ends ≥ 8 beats
   before the end, and ends before the bass does.
3. **BRIDGE**: group consecutive non-intro/outro phrases with low bass into "breakdown runs" (start below 0.35, or a
   Down phrase below 0.6; continue while below 0.45). Keep runs after the first Chorus, starting in the first 75% of the
   track, that are followed by a Chorus before EMERGENCY. Take the **first run ≥ 64 beats**, unless a later run is at
   least twice as long. Fallbacks: a mid-track Rekordbox Down phrase, then the lowest-bass window. **Runs < 16 beats =
   no bridge.**
4. **DROP**: first Chorus phrase at or after the end of the breakdown. With no bridge: the first point after IN where
   bass jumps from < 0.35 to ≥ 0.7, else the first Chorus after IN.
5. **OUT**: grid point with bass present, 32–128 beats before EMERGENCY, closest to 64 before.
6. **Ordering fix for short edits**: if OUT ≤ DROP, move OUT later; if there's no room, move EMERGENCY later.
7. **Memory START**: first downbeat.
8. **BASS SWAP**: the first "bass entry" (≥ 0.7 after 16 beats ≤ 0.4) between IN+16 and the bridge; otherwise the
   biggest sub/low-mid jump ≥ 0.3 in that window; otherwise none.
9. **Memory DROPs**: bass entries after the BASS SWAP, preceded by ≥ 32 low-bass beats, on a Chorus phrase, before OUT;
   plus the hot cue DROP. Drops closer than 32 beats are merged.

## 4. How well it matches the hand-cued tracks (`adj evaluate`)

Scored on the 51 hand-cued tracks, comparing each predicted beat to the hand-placed one:

| Cue       | n   | exact | ≤ 16 beats | ≤ 32 beats |
| --------- | --- | ----- | ---------- | ---------- |
| IN        | 42  | 18    | 21         | 33         |
| BRIDGE    | 41  | 24    | 30         | 31         |
| DROP      | 41  | 25    | 28         | 28         |
| OUT       | 42  | 14    | 20         | 33         |
| EMERGENCY | 36  | 12    | 21         | 29         |

Memory DROP: 33 hit, 14 missed, 29 extra (many of the extras are real drops the user simply didn't mark). BASS SWAP:
only 15 hand examples, which aren't consistent with each other.

Re-scored on 2026-10-30, when the library had 65 hand-cued tracks (the Python and Go versions give identical output): (n
/ exact / ≤ 16 / ≤ 32) IN 65 / 33 / 35 / 51, BRIDGE 57 / 36 / 44 / 45 (2 not placed), DROP 65 / 42 / 45 / 45 (1 not
placed), OUT 65 / 24 / 31 / 44, EMERGENCY 63 / 30 / 40 / 53; memory DROP 71 hit, 34 missed, 37 extra.

Misses are mostly one phrase (16–32 beats) early or late, which is down to taste rather than the wrong section. IN is
the most subjective: the user sometimes uses beat 1 and sometimes 65/97/129.

Things that were tried and rejected:

- EMERGENCY placed purely from "bass end − 64" (exact matches fell from 12 to 6).
- OUT at the point where the mids drop out (the stripped outro). It looks right by eye but scored worse.
- Taking the _longest_ breakdown as BRIDGE. The user usually picks the _first_ big one.

## 5. First run (2026-10-14)

- 192 Mixed In Key tracks cued (189 local AIFF, 3 streaming).
- 1,605 `Energy N` cues removed, 1,630 cues added. 11 tracks have no BRIDGE; 45 have no BASS SWAP.
- Two tracks ("Castles In The Sky", "1998") had a hand START hot cue on A. It was replaced by IN, and START moved to a
  memory cue.
- Backup: `~/Library/Pioneer/_cue_work/master.before-claude-cues.20261014.db`.
- Tool-cued track IDs are recorded in `~/Library/Pioneer/_cue_work/applied-tracks.json` (the ledger).

## 5b. Layout migration (2026-10-14, out of band, by a one-off script since removed)

Older hand-cued tracks used other layouts. The main ones were:

- **Old pad layout:** A START · B IN · C LATE · D BRIDGE · E/F DROP · G OUT · H EMERGENCY.
- **Memory-first layout:** IN/BRIDGE/DROP/OUT as memory cues (plus EARLY/LATE), track names on A, BASS SWAP on B/F,
  EMERGENCY in the hidden Kind 4 slot.
- **Near-standard:** missing H, a stray generic cue on F/G (VOCAL, OUT, BUILD, START), or an unnamed pad.

45 tracks were migrated and checked lossless: every original timestamp and loop still exists on the same track, possibly
moved between pads and memory cues. The rules applied:

1. A–D keep their template cue. An unnamed pad takes the slot's name unless a named one exists elsewhere.
2. Empty template pads are filled from same-named cues (hot first, then memory). C takes the first DROP after the
   bridge; a memory DROP is copied, not moved, because every drop keeps a memory DROP.
3. Track-name cues: first half → E, second half → G. If two want the same pad, the earliest keeps E and the latest keeps
   G; any extra goes to F, then to a memory cue. Names are recognised by matching library titles.
4. Other specific cues (JUMP, CUT, ECHO, BLEND, CROSS-MIX…) stay on E/F/G/H. If they were on A–D they move to F, then
   any free E/G.
5. Generic cues (START, EARLY, LATE, BASS SWAP, VOCAL, BUILD, extra IN/OUT/DROP…) become memory cues. Exact duplicates
   (same name and time) merge. Memory EARLY on the first downbeat → START.
6. Missing IN / DROP / OUT / EMERGENCY are placed by the rules and marked as new: 19 EMERGENCY, 7 DROP, 5 OUT and 2 IN.
   **BRIDGE is never invented** because not every song has one. A track whose H holds the user's own cue (JUMP, ECHO
   OFF) gets no EMERGENCY.

- Backup: `~/Library/Pioneer/_cue_work/master.before-migration.20261014.db`.
- The same run cued the 4 tracks that had no hot cues (`CUE(Auto)` or nothing).

## 5c. Sets: playlist-specific cues (`adj set`, `internal/setlist`)

**Keys.** The user asked for keys that match within ±2 semitones. Read literally, comparing tonics, that would reject
fifth moves (F#m → C#m), which are the most harmonic moves and appear throughout the user's own sets. So the check uses
Mixed In Key's harmonic chart: same key, Camelot ±1 and relative major/minor are free; ±2 semitones (Camelot ±2) and ±1
semitone (Camelot ±7) are allowed "energy boost" moves with a small cost; anything else is a clash. On a clash, an order
is suggested. It's the cheapest path (exact search up to 14 tracks, local search above that) that keeps the first track
and as many existing neighbours as possible.

**Mixing model.** Tracks are beat-matched, so everything is in beats. Each track uses its own Rekordbox grid, which is
the same as assuming a common 120 BPM. When A reaches G, B starts at E, so B beat = E + (A beat − G).

**Phrases.** A phrase is 16 beats. Two ways of measuring phrase position are both accepted: the plain grid from the
first downbeat, and Rekordbox phrase starts that fall on a downbeat. The second one handles tracks whose phrasing shifts
by half a phrase mid-track (On My Own: 353 → 521 → 649). Rekordbox phrase starts that aren't on a downbeat are ignored;
Dialogue's are one beat off.

**Placement.**

- G = the outgoing track's OUT.
- E = the incoming track's IN, or the nearest earlier beat with the same phrase position as G for which a bass swap
  fits.
- BASS SWAP = a phrase start in both tracks, at least 16 beats after E, where B's bass rises and/or A's bass falls
  (score ≥ 0.3). It must come before A's bass ends, or failing that before A's audio ends. It's skipped when it would
  land on one of B's drops. An existing BASS SWAP memory cue in B is used as is when it falls in that window (at least
  16 beats after E, before A's audio ends), even off A's phrasing: the user placed it (user decision, 2026-10-17).
- First track: E = START. Last track: no G. Cue names use the title stem in capitals: "The Lost Hawk (Original Mix)" →
  `LOST HAWK`, "Don't Wake Up" → `DONT WAKE UP`.

**Warnings.** An E/G pair is fine if E and G share a phrase position, so every phrase start (and the bass swap) lines
up. It's also fine if B starts a new phrase on A's last audible beat, which covers letting A play to completion. If
neither holds, you get a warning. If E is a hand-placed cue it is kept even then; otherwise E is moved to fix it.

**Off-phrase cues (user decision, 2026-10-17).** `set` and the preview follow the cues the user placed by hand: E, G (or
the OUT hot cue it comes from) and an existing BASS SWAP. Any of them that isn't on a phrase start gets a warning
("off-phrase … kept, check it"), because it may be a mistake.

**Memory cue colours (user decision, 2026-10-16).** On `--write`, a set recolours every memory cue on its tracks that's
named in `config.MEMORY_COLOR`, rated tracks included: START, IN and LATE red, BASS SWAP orange, DROP green, VOCAL
yellow, FILTER purple, JUMP pink, CUT blue, SYNC red (the IN / OUT markers below take their base name's colour, except
SYNC IN / OUT, which are aqua). FILTER DOWN and LOW PASS are renamed FILTER, and OUT is renamed CUT OUT, first
(`config.MEMORY_RENAME`; memory cues only, so the OUT hot cue on D is untouched). CUT OUT and OUT were briefly renamed
CUT; that changed when markers got their IN / OUT side. FILTER was FILTER OUT until 2026-10-17, so its old markers
FILTER OUT OUT / FILTER OUT IN are renamed FILTER OUT / FILTER IN. Since 2026-10-17 (user decision), memory cues with
the word CUT-OUT / CUT-IN anywhere in the name (CUT-OUT, CUT-OUT RES, LONG CUT-OUT RES, CUT-IN DRACUL) become CUT OUT /
CUT IN. Any `JUMP <label>` (JUMP TO DROP, JUMP TO BRIDGE) becomes JUMP, hot cues included: this is the one change `set`
makes to the user's pads, so all of a track's jump pads are called JUMP (`config.rename_to`). The report lists each
rename. Names are matched case-insensitively. The report warns about any other memory cue name, which gets no colour
rule.

**Transition markers on both tracks (user decision, 2026-10-16).** Every marker is written on both tracks at the same
moment (B beat = E + (A beat − G)) and named by side, so a track's OUT markers are easy to find and replace when it goes
into another set. The incoming B gets `BASS SWAP IN` and A gets `BASS SWAP OUT`; when the bass comes in on one of B's
drops there's no BASS SWAP IN, but A still gets BASS SWAP OUT. A leaves the mix at the first FILTER / CUT memory cue at
or after G in A (plain or `... OUT`), or at or after E in B (plain or `... IN`) while A is still playing. That cue
becomes `FILTER OUT` / `CUT OUT` on A and `FILTER IN` / `CUT IN` on B. A plain cue already within a beat of the marker
gets the side added instead of a second cue. A CUT in B beats a CUT in A (user decision, 2026-10-17): when Dracul's
`CUT-OUT RES` and ResuRection's `CUT-IN DRACUL` were 32 beats apart in "Trance Set", the next track's CUT IN set the
cut. Markers from an earlier order otherwise stay until removed by hand, with two exceptions that `set --write` deletes
(`setlist._stale_cues`). One is a CUT OUT memory cue more than a beat from this set's CUT OUT marker: it has no CUT IN
on the next track. That covers every CUT OUT on the last track, but none on a track whose next track has no analysis.
The other is a JUMP memory cue on the same beat as a JUMP hot cue, a duplicate. A SYNC memory cue (plain or `SYNC OUT`)
within a beat of A's G, or (plain or `SYNC IN`) within a beat of B's E, makes the transition an **instant mashup** (user
decision, 2026-10-17): B comes in at E at full volume with no fade-in, and `set` puts `SYNC OUT` on A's G and `SYNC IN`
on B's E. Voicemail → Children in "Trance Set" is one: Children's `SYNC IN` sits on its E (`VOICEMAIL`). On "Melodic
Dark", two exits came from cues in the incoming track (Rej's FILTER DOWN, Heart on Hold's CUT), both 8 to 24 beats
before that track's drop.

**Full-set mix (2026-10-16).** `--preview` also renders `set.mp3`, a dry run of the whole set played from the page.
Playing the original files live in the browser was ruled out: the library is AIFF, which Chrome can't play, and a page
opened from disk can't run local files through Web Audio filters (the output is silenced). The mix follows the preview
rules end to end: each track plays from E (START for the first) until it leaves. The incoming track is stretched to the
playing tempo until the outgoing one has gone, then returns to its own tempo with a 20 ms crossfade. If the outgoing
track leaves before the swap, the incoming bass comes in when it leaves. A track without local audio leaves a 1 s gap,
and the track before it plays to its end. The output is streamed through ffmpeg a track at a time, with a fixed 0.85
gain and a soft knee at 0.8 instead of normalising. "Melodic Dark" (14 tracks) renders to 56 minutes and 67 MB in about
50 s.

**Ownership of E/G (user decision, 2026-10-14).** A set owns E and G on its tracks. It overwrites E/G that belong to
other sets, fixes misaligned pairs by moving E onto the phrase, and clears the last track's G. It never touches F, which
holds jumps. Because a track has only one E and one G, every pair is kept in a **transition cache**
(`_cue_work/transitions.json`). It's filled from the library before each run and from every write, with old values kept
in `history`. Pairs found there are restored when the same two tracks meet again.

**Previews** (`--preview`, `internal/preview`). Since 2026-10-17 each transition clip is the full-set mix of just A and
B, so both follow the same rules. The clip is beat-matched to the outgoing track A:

- A plays from 8 beats before it reaches G (after any jumps from its E).
- B enters at E, stretched by A BPM / B BPM using ffmpeg `atempo`, which keeps the key, and fades in over 8 beats. On a
  SYNC there's no fade-in: B comes in at full volume.
- Until the bass swap, B is low-cut at 180 Hz. At the swap, A is low-cut instead (30 ms crossfade).
- A leaves the mix on its exit (user decision, 2026-10-17). On FILTER it's a log low-pass sweep from 16 kHz to 20 Hz
  (effectively silent) over 8 beats (STFT, 24 dB/oct), then a 4-beat fade out. On CUT it's an immediate cut on the beat
  (5 ms ramp). With neither, A fades out over 8 beats from the bass swap. The clip ends 8 beats after A has gone.
- The swap point is the BASS SWAP cue, else the drop the bass comes in on, else E + 32 beats (marked "estimated").
- **Jumps** (user decision, 2026-10-17): on reaching a JUMP memory cue, a track jumps to its JUMP hot cue (any hot cue
  whose name starts with JUMP: JUMP, JUMP TO DROP, JUMP AGAIN…), with a 10 ms crossfade. The n-th jump goes to the n-th
  of those hot cues in time order, and the last one is reused after that ("Dracul": JUMP, then JUMP AGAIN). Each memory
  cue jumps once, so a jump back ("Kuliki") replays the section once rather than looping. A JUMP memory cue within a
  beat of a JUMP hot cue marks the landing and doesn't jump ("Here In My Arms"; `set --write` deletes it when it's on
  the same beat). If taking the jumps would mean the track never reaches its G, they're ignored for that track. `set`
  still plans E/G, swaps and markers on each track's own grid, as if nothing jumps.

**First run on "Melodic Dark"** (14 tracks, keys all compatible, 10 of 13 transitions already hand-cued): every hand
pair lines up except Therapy → 16x16, where 16x16's E sat 4 beats before a phrase. It was fixed by moving E to beat 49,
which is 16x16's IN. The Lost Hawk's bass swap lands after On My Own's bass has ended (informational).

## 6. Rekordbox database details (rekordbox 6/7 `master.db`, SQLCipher)

- `master.db` is SQLCipher 4 with the default settings: the key is used as a passphrase (PBKDF2-HMAC-SHA512, 256000
  iterations, salt = the file's first 16 bytes), pages are 4096 bytes with 80 reserve bytes (16-byte IV + 64-byte
  HMAC-SHA512 over ciphertext ‖ IV ‖ page number), AES-256-CBC per page, and page 1 carries the salt instead of the
  SQLite header. `internal/sqlcipher` decrypts and encrypts it in pure Go; the plain copy is opened with
  `modernc.org/sqlite`. The key is Rekordbox's own (the one pyrekordbox ships); `REKORDBOX_DB_KEY` overrides it and must
  start with `402fd`.
- Writes re-encrypt the edited copy with the original salt and fresh IVs, decrypt the result again and integrity-check
  it before it replaces `master.db`. Re-encrypting a decrypted file with its original IVs reproduces it byte for byte
  (checked on the real library).
- Cues live in `djmdCue`; Rekordbox reads cues from the DB, not from the ANLZ files. Re-export/sync USB sticks
  afterwards so the device ANLZ files pick them up.
- `Kind`: 0 memory, hot cues A–H = 1, 2, 3, **5**, 6, 7, 8, 9 (4 is unused).
- `InFrame` = `InMsec × 150 / 1000` (150 frames/s). `OutMsec = -1` for plain cues.
- Hot cue colour `-1` (default). Memory cue `Color` is 0-based: 0 pink, 1 red, 2 orange, 3 yellow, 4 green, 5 aqua, 6
  blue, 7 purple. That's one below the `djmdColor` IDs (1 Pink … 8 Purple) used for track colours; reading it as a
  `djmdColor` ID made every cue one colour off (2026-10-16). The template's colours are in `config.MemoryColor` (§1).
- EMERGENCY loop: `Color 255, ColorTableIndex 0, ActiveLoop 1, CueMicrosec 0`, `BeatLoopSize = (beats << 16) + 1`, so 16
  beats → 1048577, 32 → 2097153, 64 → 4194305.
- New rows: random unused 32-bit `ID`, `UUID` uuid4, `ContentUUID` = track UUID, `usn`/`rb_local_usn` NULL (same as cues
  Rekordbox itself creates locally), timestamps `YYYY-MM-DD HH:MM:SS.mmm +00:00`.
- **`Kind 4` is not a hot cue pad.** Rekordbox doesn't show it on the pads (a track with an EMERGENCY loop stored as
  Kind 4 shows H as empty). Old layouts parked EMERGENCY loops there; the 2026-10-14 migration moved all of them to H.
  Never write Kind 4.
- The DB runs in WAL mode. Checkpoint (`pragma wal_checkpoint(TRUNCATE)`) before copying it back.
- **Rekordbox must be fully quit while writing.** It keeps the DB open and would overwrite changes on quit.

## 7. Track states (`db.Classify`)

| State  | Meaning                                                                                           | Used for                                                                                                |
| ------ | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| manual | Rated, or has hand-named IN/DROP/OUT                                                              | Training/evaluation; never modified                                                                     |
| mik    | Only generated cues: `Energy N` (Mixed In Key), `CUE(Auto)` (Rekordbox), + optional START hot cue | Default target                                                                                          |
| nohot  | No hot cues at all (no cues, or memory cues only)                                                 | Default target; generated memory cues are replaced, memory cues you named are kept and never duplicated |
| auto   | Unrated and listed in the ledger (cued by this tool)                                              | Can be re-cued (`--categories auto`); cues with other names (E/F/G notes) are kept                      |
| other  | Anything else                                                                                     | Left alone                                                                                              |

**Feedback loop:** once you've checked or fixed a tool-cued track in Rekordbox, give it a star rating. It then counts as
hand-cued, and `evaluate` uses it to judge rule changes.

## 8. Ideas not built yet

- Learn per-cue offsets from the user's corrections. Rated auto tracks give before/after pairs.
- EMERGENCY loop length 64 when the stripped outro is long (the user does this sometimes).
- Use Mixed In Key energy levels as a tie-breaker for which drop is "the" drop.

## 9. Go port (2026-10-30)

`rekordbox-cue` (Python: numpy, pyrekordbox, SQLAlchemy) became `adj`, a single Go binary, to match the other CLIs. The
cue logic is a straight port. Where a cue depends on numpy's arithmetic the port reproduces it (`internal/num`): linear
percentiles, pairwise float32 sums, round-half-even, first-wins argmin/argmax, and audio features computed in float32.

Checked against the Python version on the real library before it was removed:

- `status`, `evaluate -v`, `plan` (all 263 tracks, every category) and the review page data: identical, both on the
  Python feature cache and on features computed by Go (per-column differences below 1e-6 of the column maximum).
- `set` on all four playlists, with and without `--order suggested`: identical reports, `set-plan.json` and transition
  cache.
- `--preview` on Melodic Dark: identical `set.json`; transition clips match the Python renders closely (39–53 dB SNR).
- `apply --write` and `set --write --reorder` on copies of `master.db`: the same `djmdCue` rows and track order as the
  Python writes (ignoring IDs, UUIDs and timestamps), and SQLCipher (`sqlcipher3`) opens the Go-written files.

Deliberate differences:

- The full-set mix no longer drops audio when the next track starts after the buffered audio ends. Python lost the 1 s
  gap after a track without local audio, and one sample at a CUT that ends exactly where the next track starts, so
  `set.mp3` could drift from the page's timeline.
- JSON writes whole numbers without `.0` (`128` rather than `128.0`) and keeps non-ASCII text as UTF-8. Only `adj` and
  its own pages read these files.
- The feature cache is `~/.cache/adj/features/<md5 of the NFC file name>.f32.gz` (gzip: `ADJF`, version, frame count,
  column count, then float32 rows) instead of `.npz`. Run `adj features` once after switching.
- Environment variables: `ADJ_WORK`, `ADJ_PATH_MAP` and `ADJ_CLOUD_DIR` replace the `REKORDBOX_CUE_*` ones.
