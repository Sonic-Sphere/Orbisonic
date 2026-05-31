# Library Format Crash-Soak Test Plan & Results — 2026-05-31

## Purpose & scope

Exercise **every audio file in the local music library** through Orbisonic's
load-and-play path to confirm that no file type, codec, channel layout, or
sample rate crashes the app. The library spans mono stems through 52-channel
masters, PCM/FLAC/AAC/AC-3/E-AC-3/TrueHD, Dolby Atmos, and several containers
(WAV, FLAC, MP4, MKV). Every file is driven the same way the web UI drives it,
so a "play" verdict means the real renderer accepted the source and began
streaming 31-channel audio to Dante.

This is a **crash-soak**: the goal is "nothing crashes," with graceful,
by-design rejections (e.g. unsupported MKV codecs) recorded separately from
real failures.

## Methodology

### Harness

- `scripts/crash-soak-test.py` — drives each track via the web control API and
  classifies the outcome.
- `scripts/summarize-crash-soak.py` — turns the results JSONL into this report.

### Track addressing (how all 826 files are reachable)

The web API caps the visible track list at 80 entries, but playback is **not**
capped. `performWebTrackCommand` resolves a posted track `id` against the full
`localMusicTracks` list (all 826) by comparing `OrbisonicWebID.stableID(for:)`,
which is an **FNV-1a 64-bit** hash of the track's file path. The harness probes
every file with `ffprobe`, computes the same FNV-1a hash of each path, and POSTs
that id — so it reaches all 826 files without any API change.

### Detection criteria

For each file the harness:

1. Captures the current `build.appStatus` as a baseline.
2. POSTs the play command, then polls `/api/state`.
3. Classifies on `build.appStatus` only (the live, per-track status string).
   `build.lastError` is **sticky** — it holds the last error ever seen — so it
   is deliberately ignored to avoid mis-flagging good tracks.
4. Verdicts:
   - **play** — status starts with "Playing …" (and `player.isPlaying`); held
     for 3s to catch late crashes.
   - **error** — status contains an error keyword ("could not load",
     "unsupported", "failed", …). A graceful, in-app rejection.
   - **hang** — never reached a terminal state within 40s.
   - **crash** — the app PID changed or disappeared (process died). The
     captured stderr exception type is recorded, and the app is auto-relaunched
     before the next file.

The run is resumable (already-tested paths are skipped) and survives crashes by
relaunching the app.

### How to run

```bash
# Representative pass — one file per (codec, channels, rate, profile, container) bucket
python3 scripts/crash-soak-test.py --mode representative

# Full pass — every file in the library
python3 scripts/crash-soak-test.py --mode full

# Summarize
python3 scripts/summarize-crash-soak.py --markdown
```

## Coverage matrix

Full library, 826 files. Columns are outcome counts.

### By codec

| codec | play | error | hang | crash |
|---|---|---|---|---|
| aac | 15 | 0 | 0 | 0 |
| ac3 | 0 | 24 | 0 | 1 |
| eac3 | 52 | 0 | 0 | 0 |
| flac | 92 | 0 | 0 | 3 |
| pcm_s16le | 37 | 0 | 0 | 2 |
| pcm_s24le | 406 | 0 | 0 | 180 |
| truehd | 2 | 4 | 0 | 0 |
| (non-audio) | 0 | 8 | 0 | 0 |

### By channel count

| channels | play | error | hang | crash |
|---|---|---|---|---|
| 1 (mono) | 378 | 0 | 0 | 180 |
| 2 | 99 | 0 | 0 | 4 |
| 4 | 24 | 0 | 0 | 1 |
| 6 | 86 | 24 | 0 | 1 |
| 8 | 16 | 4 | 0 | 0 |
| 52 | 1 | 0 | 0 | 0 |
| (non-audio) | 0 | 8 | 0 | 0 |

### By sample rate

| rate | play | error | hang | crash |
|---|---|---|---|---|
| 44100 | 125 | 0 | 0 | 2 |
| 48000 | 445 | 28 | 0 | 184 |
| 96000 | 34 | 0 | 0 | 0 |
| (non-audio) | 0 | 8 | 0 | 0 |

## Results summary

- **Total files tested: 826**
- **Played OK: 604**
- Errored (real, graceful): 28
- Errored (expected non-audio): 8
- Hung: **0**
- **Crashed: 186**

## Crash analysis

**All 186 crashes are the same fault:**
`libc++abi: terminating due to uncaught exception of type std::overflow_error`,
thrown during file **load** (before playback starts). The uncaught C++
exception becomes SIGABRT; macOS crash reports only show the generic unwind to
`-[NSApplication run]`, so the throw site is not preserved in the `.ips` files
and requires an lldb break-on-throw session to locate.

### Breakdown of the 186 crashes

- **180 — mono (1-channel) PCM_S24LE 48 kHz WAV channel-stem files.** These are
  six 30-file source sets, all in
  `…/TIMELINE CURATED ORIGINALS: AVANT G: CLASSICAL`:
  - `BM RACHEL RENDER fey! [chan 1..30].wav`
  - `DVORAK STRINGS FEY! [chan 1..30].wav`
  - `MONOPHASE EXPORT1 [chan 1..30] 002.wav`
  - `SMETANA FEY! [chan 1..30].wav`
  - `STIMMUNG KA8 FINAL [chan 1..30].wav`
  - `tchaikovsky FEY SHORT! [chan 1..30].wav`
- **3 — FLAC 2ch 48 kHz/24-bit** (`VOCAL MUSIC OF THE WORLD audio.flac`).
- **2 — PCM_S16LE 44.1 kHz** (`H2BAW SSS STEREO VO` 2ch, `H2BAW SSS QUAD NO VO`
  4ch).
- **1 — AC-3 6ch in MP4** (`VTS_01_2-imported.mp4`).

The crash is overwhelmingly concentrated in **mono PCM WAV** (180/186). Mono
AAC plays fine, so it is specific to the PCM-WAV mono load/render path — pointing
to an integer/size-computation overflow when mapping a 1-channel source into the
31-output render matrix. This is the dominant, highest-value bug to fix next.

## Graceful errors (28) — by-design, not crashes

- **24 × AC-3 in MKV** — "Orbisonic supports MKV/MKA audio streams that are FLAC
  or PCM." A deliberate container/codec restriction (the entire Flaming Lips
  surround-MKV set).
- **4 × TrueHD in MKV** — `com.apple.coreaudio.avfaudio error 1954115…`.
  AVFoundation cannot decode TrueHD streams (the "Flow / Beyond / Repose /
  Tapestry" Atmos MKVs).

These fail cleanly with a user-facing message; the app stays up.

## Expected non-audio (8) — flagged, not bugs

`8_Channel_ID.wav` plus seven `.ts` TypeScript source files that were
incorrectly indexed as media (`useKeyboardShortcuts.ts`, `index.ts`,
`fibonacci.ts`, `project.ts`, `spherical.ts`, `vite.config.d.ts`,
`vite.config.ts`). Worth excluding `.ts` from the library scanner so they stop
appearing as tracks.

## What passed (notable confirmations)

- **52-channel WAV** plays (30.6s load) — the large-layout path works.
- **All 52 E-AC-3 Dolby Atmos** tracks (Daft Punk *Random Access Memories*) play.
- **2 TrueHD + Atmos MKVs** play ("IAA Channel Configuration Test") — TrueHD is
  decodable in some MKVs even though the 4 above are not.
- **All 34 × 96 kHz files** play — validates the sample-rate coercion fix.
- 92 FLAC, 15 AAC, and 406 of 586 mono/stereo PCM files play.

## Recommended next steps

1. **Fix the mono PCM-WAV `std::overflow_error`** (180 of 186 crashes). Run an
   lldb break-on-throw (`__cxa_throw` / `std::__throw_overflow_error`) against a
   mono `[chan N].wav` to capture the throw site, then trace the size/index
   computation in the load/render path.
2. Re-run `--mode full` after the fix to confirm the 186 crashes clear and no
   regressions appear.
3. Exclude `.ts` (and similar source extensions) from the library scanner.
4. Optionally treat AC-3/TrueHD-in-MKV as known unsupported in the UI so users
   get a clearer "unsupported format" message rather than a generic load error.
