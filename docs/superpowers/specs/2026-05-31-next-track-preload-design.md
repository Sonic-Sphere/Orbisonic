# Next-Track Preload — Design

- **Date:** 2026-05-31
- **Branch:** `feat/next-track-preload` (off `feat/local-music-channel-filter`)
- **Status:** Approved design, pending implementation plan

## Problem

Loading a track decodes the whole file into memory, which can take seconds for
large multichannel/Atmos files and makes switching to the next queued track feel
slow. The app already preloads the *next* track's **metadata** but not its
**audio**, so the expensive decode still happens on demand at skip time.

Users want an opt-in setting that preloads the next queued track's audio so
forward skips and auto-advance are instant — and it must work for **any** track
(any channel count, sample rate, or duration), not just small ones, while making
the memory impact transparent so the user can make an informed choice.

## Goals

- A user-facing **toggle in Settings** to enable next-track audio preload.
- Works for **any** track — multichannel/Atmos included — bounded only by an
  adaptive memory policy, never by a track-type-specific heuristic.
- **Transparent**: surface free RAM, the next track's estimated size, and the
  preload status (native Settings, native player chip, and the web `/control`
  page) so the user understands the impact.
- Default **off**; nothing changes silently on update.

## Non-Goals

- Preloading the *previous* track (back-skip). Next-only for now.
- Changing how the **currently playing** track is prepared/streamed.
- The monitor-output device path or any audio-routing changes.

## Approach (chosen: A — repurpose the existing pipeline)

The codebase already has a fully-tested full-PCM adjacent-preload pipeline
(candidate selection, generation/cancellation checks, budget gate, store/discard,
LRU prepared cache). It is currently disabled by a compile-time flag
(`enableAdjacentLocalPCMPreload = false`) and a zero byte budget
(`maxAdjacentFullPreloadPCMBytes = 0`). We convert those static gates into a
runtime user setting plus an adaptive RAM budget, scoped to the next track only.
This reuses proven correctness rather than building a parallel subsystem.

The cheap **metadata** preload (`enableAdjacentLocalMetadataPreload = true`,
next+prev) is left exactly as-is. The new toggle governs only the **full-audio**
preload of the next track.

## Design

### 1. Setting & lifecycle
- `@Published var preloadNextTrackEnabled: Bool` on `OrbisonicViewModel`, backed
  by `UserDefaults` key `Orbisonic.preloadNextTrackEnabled`, default `false`.
- `didSet`:
  - on enable → trigger a preload pass for the current queue position;
  - on disable → cancel any in-flight preload **and evict** the preloaded
    next-track PCM from the cache, freeing RAM immediately.

### 2. Gating rework
- Full-audio preload enablement becomes `preloadNextTrackEnabled && !isRunningUnitTests`
  (tests stay deterministic via existing injectable init params).
- Full-audio preload **candidates are next-only** when governed by the toggle.
  Metadata candidates remain unchanged (next+prev).

### 3. Adaptive RAM budget (core policy)
- Pure decision function:
  `planNextTrackPreload(estimatedBytes:availableBytes:fraction:) -> PreloadBudgetDecision`
  returning `.allow`, `.skipLowMemory`, or `.skipUnknownSize`.
- Default policy: allow if `estimatedBytes <= 0.5 * availableBytes`.
- `availableBytes` from a small `SystemMemory` helper (`host_statistics64`
  free+inactive+purgeable pages; `ProcessInfo.physicalMemory` for total), behind
  an **injectable provider** so tests are deterministic.
- The preload **full-decodes** the next track even if it would normally stream —
  this is what makes "any track" work. The adaptive budget is the safety bound.

### 4. Cache capacity
- Prepared cache must hold current + next: entry capacity 2 (already), byte
  ceiling raised to a generous backstop when the toggle is on.
- The adaptive admit-gate is the real control: it refuses to store a track that
  exceeds the budget, so the cache cap is only a backstop.

### 5. Preload execution
- Reuse the existing reschedule trigger, background decode `Task`,
  generation/cancellation checks, and store/discard.
- On skip/auto-advance, the load path already consumes a valid cached entry
  (`takeValid`) → instant.
- Status model `NextTrackPreloadStatus`:
  `idle / preparing / ready / skipped(lowMemory | unknownSize) / noNextTrack`.

### 6. Transparency (all three surfaces)
- **Web state**: new `preload` struct in `OrbisonicWebState`:
  `{ enabled, status, nextLabel, nextEstimateBytes, freeBytes, totalBytes }`.
- **Settings (native)**: the Toggle plus a caption —
  `Free memory: 22.4 GB · Next ≈ 264 MiB` and the live status
  (Ready / Preparing… / Skipped (low memory)).
- **Player/queue chip (native)**: small `Next: <name> — Ready/Preparing…/Skipped`.
- **Web `/control` mirror**: same status rendered from `state.preload`.
- RAM/size readout computed when web-state is built and refreshed on a
  low-frequency tick — no busy polling.

### 7. Settings placement
- Settings tab (`StageTab.settings`), under a Playback grouping. Exact spot
  confirmed against the Settings view during implementation.

## Testing (TDD)

- **Pure adaptive-budget function** (`planNextTrackPreload`): runnable `swiftc`
  harness, genuine RED→GREEN (mirrors `planOutputDeviceApply`).
- **Behavioral** (`LocalPlayerStabilizationTests`, CI): toggle on + budget allows
  → next track prepared (`hasPreparedLocalFileForTesting` true), skip instant;
  inject tiny available-RAM → status `skipped`, next foreground-decodes.
- **Web-state `preload` field** coverage (`OrbisonicWebStateTests`) via a
  `setPreloadStatusForTesting` hook + `webStateForTesting`.
- **Source-invariant wiring** harness (run locally): settings binding present,
  full-audio candidates next-only.
- Caveat: XCTests are CI-only on this CommandLineTools Mac (no XCTest runtime);
  pure-logic and source-invariant harnesses run locally.

## Risks / Open items

- `SystemMemory` "available" computation should be validated against Activity
  Monitor on the target Mac during implementation.
- Confirm the prepared-cache byte-ceiling change does not perturb current-track
  behavior when the toggle is off (off path must be a no-op vs today).
- Confirm the load path's `takeValid` consumption is hit for the auto-advance
  path as well as manual skip.
