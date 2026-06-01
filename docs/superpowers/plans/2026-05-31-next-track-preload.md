# Next-Track Audio Preload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in Settings toggle that preloads the *next* queued local track's full audio so forward skips / auto-advance are instant for **any** track (multichannel/Atmos included), bounded by an adaptive RAM budget, with the memory impact surfaced in all three UI surfaces.

**Architecture:** Repurpose the existing, already-tested full-PCM adjacent-preload pipeline (candidate selection → budget gate → background decode → store/discard → LRU `LocalPreparedFileCache` → load-path `takeValid`). Convert its two compile-time gates (`enableAdjacentLocalPCMPreload = false`, `maxAdjacentFullPreloadPCMBytes = 0`) into a runtime user setting plus an adaptive RAM budget, scoped to the **next** track only. The cheap metadata preload (next+prev) is unchanged.

**Tech Stack:** Swift 5 / SwiftUI / AVFoundation, macOS app. Builds locally on the Sphere Mac (CommandLineTools — **no XCTest runtime locally**). Network/web mirror via the in-app `OrbisonicWebServer`.

---

## Workflow Preamble (READ FIRST — remote-edit constraints)

All source for this app lives on a **remote Mac**, reached only via `ssh sonicsphere@100.104.46.1` (Tailscale). The repo path on the remote is `~/Documents/Orbisonic`. **Edit/Read/Write tools are LOCAL ONLY** — they cannot touch the remote. The loop for every change is:

1. Write a Python patcher **locally** to `/tmp/<name>.py`. New whole files may instead be written locally and `scp`'d verbatim.
2. `scp /tmp/<name>.py sonicsphere@100.104.46.1:/tmp/` then `ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && python3 /tmp/<name>.py'`.
3. Every patcher MUST `assert src.count(anchor) == 1` before `src.replace(anchor, new)`, and `assert src != orig` after, so a drifted anchor fails loudly instead of silently no-op'ing.

**Testing reality on this Mac:**
- **Pure-logic TDD** (`planNextTrackPreload`, `SystemMemory` math): genuine RED→GREEN via a standalone `swiftc` harness compiled and run locally on the remote. This is the real TDD loop — watch it fail, then pass.
- **Source-invariant harnesses** (`swift harness.swift "$PWD"`): assert that wiring exists in the source (e.g. a binding is present, candidates are next-only). Run locally on the remote.
- **Committed XCTests** (`Tests/OrbisonicTests/*.swift`): these **only run in CI** (no XCTest runtime on the CLT Mac). Write them, build the package to confirm they compile, and rely on CI to execute. Mirror the style of `OutputDeviceApplyPlanTests.swift` / `LocalPlayerStabilizationTests.swift`.

**Build / deploy / verify commands (run on remote):**
- Build the package (confirms everything compiles incl. tests): `cd ~/Documents/Orbisonic && swift build 2>&1 | tail -40`
- Deploy the app: `./scripts/refresh-orbisonic-app.sh`
- Restart: `pkill -x Orbisonic; sleep 1; open ~/Documents/Orbisonic/Orbisonic.app`
- Web smoke test: `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:37943/Orbisonic/control` (expect `200`; wait a few seconds after restart for the listener to bind).

**Git (run on remote):** commit with the project identity and push feature work to the `fork` remote (Sonic-Sphere/Orbisonic), never `origin`:
```bash
git -c user.name="rKalb" -c user.email="3437054+rKalb@users.noreply.github.com" \
  commit -m "$(cat <<'EOF'
<message>

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
git push fork feat/next-track-preload
```
Work happens on branch **`feat/next-track-preload`** (already created; spec committed there as `bc5e92e`).

**Frequent commits:** one commit per task below.

---

## File Map

| File | Status | Responsibility |
|------|--------|----------------|
| `Sources/Orbisonic/NextTrackPreloadPlan.swift` | **create** | Pure adaptive-budget decision (`planNextTrackPreload`) + `NextTrackPreloadStatus` enum. Framework-free, unit-testable. |
| `Sources/Orbisonic/SystemMemory.swift` | **create** | `SystemMemorySnapshot` + `SystemMemoryProviding` protocol + live `HostSystemMemoryProvider` (host_statistics64 + ProcessInfo). Injectable. |
| `Sources/Orbisonic/OrbisonicViewModel.swift` | modify | Add `preloadNextTrackEnabled` setting + lifecycle; rework gating to runtime + adaptive budget, next-only full-audio candidates; status publishing; testing hooks. |
| `Sources/Orbisonic/OrbisonicWebServer.swift` | modify | Add `OrbisonicWebState.Preload` struct + populate in `makeWebState`. |
| `Sources/Orbisonic/OrbisonicWebControlPage.swift` | modify | Render the preload status row from `state.preload`. |
| `Sources/Orbisonic/ContentView.swift` | modify | Settings toggle + caption in the "Sound Settings" panel; player/queue preload chip. |
| `Tests/OrbisonicTests/NextTrackPreloadPlanTests.swift` | **create** | XCTest for the pure decision function (CI). |
| `Tests/OrbisonicTests/LocalPlayerStabilizationTests.swift` | modify | Behavioral: toggle on + budget allows → next prepared; tiny RAM → skipped. |
| `Tests/OrbisonicTests/OrbisonicWebStateTests.swift` | modify | Assert `preload` field shape via `setPreloadStatusForTesting` hook. |
| `Tests/OrbisonicTests/ExistingUIFreezeTests.swift` | modify | Source-invariant: binding present, full-audio candidates next-only. |

---

## Task 1: Pure adaptive-budget decision function + status enum

**Files:**
- Create: `Sources/Orbisonic/NextTrackPreloadPlan.swift`
- Create (local, throwaway): `/tmp/plan_harness.swift` (genuine RED→GREEN swiftc harness)
- Create: `Tests/OrbisonicTests/NextTrackPreloadPlanTests.swift` (CI XCTest)

The decision function is the core safety policy: given the next track's estimated decoded byte size and the machine's available RAM, decide whether to preload. Mirrors `planOutputDeviceApply` / `OutputDeviceApplyPlan` in style (framework-free enum + free function).

- [ ] **Step 1: Write the failing harness (RED)**

Write `/tmp/plan_harness.swift` locally. It inlines the *expected* API so we can compile-fail first, then move the real impl into the package.

```swift
// /tmp/plan_harness.swift — genuine RED→GREEN. Compile+run locally on remote:
//   swiftc /tmp/plan_harness.swift -o /tmp/plan_harness && /tmp/plan_harness
import Foundation

// === BEGIN copy of NextTrackPreloadPlan.swift body (paste real impl in Step 3) ===
// (left empty on purpose for RED)
// === END ===

func expect(_ cond: Bool, _ msg: String) {
    if !cond { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); exit(1) }
}

// allow when estimate is comfortably under the fraction of available RAM
expect(planNextTrackPreload(estimatedBytes: 200_000_000, availableBytes: 8_000_000_000, fraction: 0.5) == .allow,
       "200MB under 50% of 8GB should allow")
// skip low memory when estimate exceeds the fraction
expect(planNextTrackPreload(estimatedBytes: 5_000_000_000, availableBytes: 8_000_000_000, fraction: 0.5) == .skipLowMemory,
       "5GB over 50% of 8GB should skip low memory")
// boundary: exactly at the fraction is allowed (<=)
expect(planNextTrackPreload(estimatedBytes: 4_000_000_000, availableBytes: 8_000_000_000, fraction: 0.5) == .allow,
       "estimate == fraction*available should allow")
// unknown size (nil estimate) -> skipUnknownSize
expect(planNextTrackPreload(estimatedBytes: nil, availableBytes: 8_000_000_000, fraction: 0.5) == .skipUnknownSize,
       "nil estimate should skip unknown size")
// zero/garbage estimate -> skipUnknownSize
expect(planNextTrackPreload(estimatedBytes: 0, availableBytes: 8_000_000_000, fraction: 0.5) == .skipUnknownSize,
       "zero estimate should skip unknown size")
// zero available RAM -> skipLowMemory (never divide-by-zero, never allow)
expect(planNextTrackPreload(estimatedBytes: 100, availableBytes: 0, fraction: 0.5) == .skipLowMemory,
       "zero available should skip low memory")

print("ALL PASS")
```

- [ ] **Step 2: Run harness, verify it fails to compile (RED)**

Run on remote:
```bash
scp /tmp/plan_harness.swift sonicsphere@100.104.46.1:/tmp/
ssh sonicsphere@100.104.46.1 'swiftc /tmp/plan_harness.swift -o /tmp/plan_harness 2>&1 | tail -20'
```
Expected: compile error — `cannot find 'planNextTrackPreload' in scope` and `cannot find '.allow'`. This is the RED state.

- [ ] **Step 3: Write the real implementation (GREEN source)**

Write `Sources/Orbisonic/NextTrackPreloadPlan.swift` locally, then `scp` it to the remote package:

```swift
import Foundation

/// Why the next-track full-audio preload was or was not started, for a single
/// candidate. Drives the user-facing status surfaces and the preload gate.
/// Framework-free so it is unit-testable without AVFoundation/CoreAudio.
enum NextTrackPreloadDecision: Equatable {
    case allow
    case skipLowMemory
    case skipUnknownSize
}

/// Pure adaptive budget: should we spend `estimatedBytes` of resident RAM to
/// fully decode the next track, given `availableBytes` free right now?
///
/// Policy: allow only when the estimate is known (> 0), there is some RAM
/// available, and the estimate fits within `fraction` of the available RAM.
/// `fraction` defaults to 0.5 at the call site (see `OrbisonicViewModel`).
func planNextTrackPreload(
    estimatedBytes: Int?,
    availableBytes: Int,
    fraction: Double
) -> NextTrackPreloadDecision {
    guard let estimatedBytes, estimatedBytes > 0 else { return .skipUnknownSize }
    guard availableBytes > 0 else { return .skipLowMemory }
    let budget = Double(availableBytes) * fraction
    return Double(estimatedBytes) <= budget ? .allow : .skipLowMemory
}

/// User-facing status of the next-track preload feature. `idle` = enabled but
/// nothing to do yet; `noNextTrack` = enabled but the queue has no distinct
/// next track. `skipped` carries the budget reason so the UI can explain it.
enum NextTrackPreloadStatus: Equatable {
    case idle
    case preparing
    case ready
    case skippedLowMemory
    case skippedUnknownSize
    case noNextTrack

    /// Short label for chips / captions.
    var displayLabel: String {
        switch self {
        case .idle: return "Idle"
        case .preparing: return "Preparing…"
        case .ready: return "Ready"
        case .skippedLowMemory: return "Skipped (low memory)"
        case .skippedUnknownSize: return "Skipped (unknown size)"
        case .noNextTrack: return "No next track"
        }
    }

    /// Stable token for the web JSON (lower-camel, parser-friendly).
    var webToken: String {
        switch self {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .skippedLowMemory: return "skippedLowMemory"
        case .skippedUnknownSize: return "skippedUnknownSize"
        case .noNextTrack: return "noNextTrack"
        }
    }

    var isBusy: Bool { self == .preparing }
}
```

Deploy the source file:
```bash
scp /tmp/NextTrackPreloadPlan.swift sonicsphere@100.104.46.1:'~/Documents/Orbisonic/Sources/Orbisonic/NextTrackPreloadPlan.swift'
```

- [ ] **Step 4: Paste impl into harness, run, verify GREEN**

Copy the `enum NextTrackPreloadDecision` + `func planNextTrackPreload` portion into the marked region of `/tmp/plan_harness.swift` (the harness only needs the decision parts, not the status enum). Then:
```bash
scp /tmp/plan_harness.swift sonicsphere@100.104.46.1:/tmp/
ssh sonicsphere@100.104.46.1 'swiftc /tmp/plan_harness.swift -o /tmp/plan_harness && /tmp/plan_harness'
```
Expected: `ALL PASS`.

- [ ] **Step 5: Write the CI XCTest (mirrors OutputDeviceApplyPlanTests)**

Write `Tests/OrbisonicTests/NextTrackPreloadPlanTests.swift` locally and scp it:

```swift
import XCTest
@testable import Orbisonic

final class NextTrackPreloadPlanTests: XCTestCase {
    func testAllowsWhenEstimateFitsWithinFraction() {
        XCTAssertEqual(
            planNextTrackPreload(estimatedBytes: 200_000_000, availableBytes: 8_000_000_000, fraction: 0.5),
            .allow
        )
    }

    func testAllowsAtExactBoundary() {
        XCTAssertEqual(
            planNextTrackPreload(estimatedBytes: 4_000_000_000, availableBytes: 8_000_000_000, fraction: 0.5),
            .allow
        )
    }

    func testSkipsLowMemoryWhenEstimateExceedsFraction() {
        XCTAssertEqual(
            planNextTrackPreload(estimatedBytes: 5_000_000_000, availableBytes: 8_000_000_000, fraction: 0.5),
            .skipLowMemory
        )
    }

    func testSkipsUnknownSizeWhenEstimateMissingOrZero() {
        XCTAssertEqual(planNextTrackPreload(estimatedBytes: nil, availableBytes: 8_000_000_000, fraction: 0.5), .skipUnknownSize)
        XCTAssertEqual(planNextTrackPreload(estimatedBytes: 0, availableBytes: 8_000_000_000, fraction: 0.5), .skipUnknownSize)
    }

    func testSkipsLowMemoryWhenNoRAMAvailable() {
        XCTAssertEqual(planNextTrackPreload(estimatedBytes: 100, availableBytes: 0, fraction: 0.5), .skipLowMemory)
    }

    func testStatusWebTokensAreStable() {
        XCTAssertEqual(NextTrackPreloadStatus.ready.webToken, "ready")
        XCTAssertEqual(NextTrackPreloadStatus.skippedLowMemory.webToken, "skippedLowMemory")
        XCTAssertTrue(NextTrackPreloadStatus.preparing.isBusy)
    }
}
```

- [ ] **Step 6: Build the package to confirm everything compiles**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && swift build 2>&1 | tail -20'
```
Expected: `Build complete!` (or no errors). The XCTest won't *run* locally but must compile.

- [ ] **Step 7: Commit**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && git add Sources/Orbisonic/NextTrackPreloadPlan.swift Tests/OrbisonicTests/NextTrackPreloadPlanTests.swift && git -c user.name="rKalb" -c user.email="3437054+rKalb@users.noreply.github.com" commit -m "$(cat <<'\''EOF'\''
Add pure next-track preload budget decision + status model

planNextTrackPreload gates the full-audio preload on an adaptive RAM
fraction (allow / skipLowMemory / skipUnknownSize). NextTrackPreloadStatus
models the user-facing state for the upcoming Settings toggle and surfaces.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"'
```

---

## Task 2: SystemMemory helper + injectable provider

**Files:**
- Create: `Sources/Orbisonic/SystemMemory.swift`

This provides `availableBytes`/`totalBytes` for the budget gate and the transparency surfaces. The live provider reads Mach `host_statistics64` (free + inactive + purgeable pages) for "available" and `ProcessInfo.physicalMemory` for total. It sits behind a protocol so tests inject deterministic numbers (the budget function itself is already pure and tested in Task 1; this task makes the *source of numbers* swappable).

- [ ] **Step 1: Write the implementation**

Write `Sources/Orbisonic/SystemMemory.swift` locally and scp it:

```swift
import Foundation
import Darwin

/// A point-in-time view of system memory used for the preload budget gate and
/// the transparency surfaces (Settings caption, web state).
struct SystemMemorySnapshot: Equatable {
    /// Bytes considered reclaimable/free right now (free + inactive + purgeable).
    let availableBytes: Int
    /// Total physical RAM.
    let totalBytes: Int
}

/// Injectable source of memory snapshots so tests stay deterministic.
protocol SystemMemoryProviding {
    func snapshot() -> SystemMemorySnapshot
}

/// Live provider backed by Mach `host_statistics64` and `ProcessInfo`.
struct HostSystemMemoryProvider: SystemMemoryProviding {
    func snapshot() -> SystemMemorySnapshot {
        let total = Int(ProcessInfo.processInfo.physicalMemory)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let host = mach_host_self()
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            // Conservative fallback: report no headroom so the gate skips
            // rather than risking an over-commit on a bad reading.
            return SystemMemorySnapshot(availableBytes: 0, totalBytes: total)
        }

        let pageSize = Int(vm_kernel_page_size)
        let freePages = Int(stats.free_count)
        let inactivePages = Int(stats.inactive_count)
        let purgeablePages = Int(stats.purgeable_count)
        let available = (freePages + inactivePages + purgeablePages) * pageSize

        return SystemMemorySnapshot(availableBytes: available, totalBytes: total)
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && swift build 2>&1 | tail -20'
```
Expected: `Build complete!`.

- [ ] **Step 3: Sanity-check the live reading against Activity Monitor**

This is a one-time empirical validation noted as a risk in the spec. Run a tiny program on the remote that prints the snapshot, and eyeball it against Activity Monitor's "Memory" tab (available ≈ Memory Used headroom; total = installed RAM):
```bash
ssh sonicsphere@100.104.46.1 'cat > /tmp/mem_probe.swift <<EOF
import Foundation
import Darwin
// paste HostSystemMemoryProvider here, then:
let s = HostSystemMemoryProvider().snapshot()
print("available=\(s.availableBytes/1_048_576) MiB total=\(s.totalBytes/1_048_576) MiB")
EOF
swiftc /tmp/mem_probe.swift -o /tmp/mem_probe && /tmp/mem_probe'
```
Expected: `total` matches installed RAM; `available` is in a believable multi-GB range on an idle machine. If wildly off, adjust which page classes are summed (drop `purgeable` if it over-reports) — but do NOT change the budget fraction here.

- [ ] **Step 4: Commit**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && git add Sources/Orbisonic/SystemMemory.swift && git -c user.name="rKalb" -c user.email="3437054+rKalb@users.noreply.github.com" commit -m "$(cat <<'\''EOF'\''
Add injectable system-memory provider for preload budget

HostSystemMemoryProvider reads host_statistics64 (free+inactive+purgeable)
and ProcessInfo.physicalMemory; the SystemMemoryProviding protocol lets
tests feed deterministic snapshots into the preload gate.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"'
```

---

## Task 3: Setting, published state, provider, and enable/disable lifecycle

**Files:**
- Modify: `Sources/Orbisonic/OrbisonicViewModel.swift`
- Patchers (local): `/tmp/p3_state.py`

Add the user setting (`preloadNextTrackEnabled`), the published status, the injectable memory provider, the UserDefaults key, and the `didSet` lifecycle. No gating logic yet — that is Task 4.

**Verified anchors (must each appear exactly once):**
- Key constants block contains: `    private static let sphereOutputSafetyLimitKey = "Orbisonic.sphereOutputSafetyLimitPercent"`
- Stored-properties block contains: `    private let adjacentFullPreloadPCMByteLimit: Int`
- The injectable secondary init signature contains the param `        preparedCacheByteLimit: Int? = nil`
- Inside that init body: `        self.adjacentFullPreloadPCMByteLimit = adjacentFullPreloadPCMByteLimit ?? Self.maxAdjacentFullPreloadPCMBytes`

- [ ] **Step 1: Write the patcher**

Write `/tmp/p3_state.py` locally:

```python
#!/usr/bin/env python3
path = "/Users/sonicsphere/Documents/Orbisonic/Sources/Orbisonic/OrbisonicViewModel.swift"
with open(path) as f:
    src = f.read()
orig = src

# 1) UserDefaults key constant, placed right after the safety-limit key.
key_anchor = '    private static let sphereOutputSafetyLimitKey = "Orbisonic.sphereOutputSafetyLimitPercent"\n'
key_new = key_anchor + '    private static let preloadNextTrackEnabledKey = "Orbisonic.preloadNextTrackEnabled"\n'
assert src.count(key_anchor) == 1, "key anchor=%d" % src.count(key_anchor)
src = src.replace(key_anchor, key_new)

# 2) Stored properties: injectable memory provider, placed next to the existing
#    preload-related stored properties.
prop_anchor = "    private let adjacentFullPreloadPCMByteLimit: Int\n"
prop_new = prop_anchor + "    private let systemMemoryProvider: SystemMemoryProviding\n"
assert src.count(prop_anchor) == 1, "prop anchor=%d" % src.count(prop_anchor)
src = src.replace(prop_anchor, prop_new)

# 3) Published toggle + status. Insert immediately before the existing
#    `@Published var preset` declaration (a stable, unique published-var anchor).
pub_anchor = "    @Published var preset: SpatialPreset = .defaultPreset {\n"
pub_new = (
    "    @Published var preloadNextTrackEnabled: Bool = OrbisonicViewModel.loadBool(\n"
    "        key: OrbisonicViewModel.preloadNextTrackEnabledKey,\n"
    "        defaultValue: false\n"
    "    ) {\n"
    "        didSet {\n"
    "            guard preloadNextTrackEnabled != oldValue else { return }\n"
    "            UserDefaults.standard.set(preloadNextTrackEnabled, forKey: Self.preloadNextTrackEnabledKey)\n"
    "            if preloadNextTrackEnabled {\n"
    "                scheduleAdjacentLocalFilePreloads(reason: \"next-track preload enabled\")\n"
    "            } else {\n"
    "                cancelLocalPreparedFilePreload(reason: \"next-track preload disabled\")\n"
    "                localPreparedFileCache.removeAll()\n"
    "                nextTrackPreloadStatus = .idle\n"
    "            }\n"
    "        }\n"
    "    }\n"
    "    @Published private(set) var nextTrackPreloadStatus: NextTrackPreloadStatus = .idle\n"
    + pub_anchor
)
assert src.count(pub_anchor) == 1, "pub anchor=%d" % src.count(pub_anchor)
src = src.replace(pub_anchor, pub_new)

# 4) Initialize the provider in BOTH inits. The injectable init gets a new
#    optional param; the convenience init defaults to the live provider.
#    4a) injectable init signature: add param after preparedCacheByteLimit.
sig_anchor = "        preparedCacheByteLimit: Int? = nil\n"
sig_new = "        preparedCacheByteLimit: Int? = nil,\n        systemMemoryProvider: SystemMemoryProviding? = nil\n"
assert src.count(sig_anchor) == 1, "sig anchor=%d" % src.count(sig_anchor)
src = src.replace(sig_anchor, sig_new)

# 4b) injectable init body: assign provider after the byte-limit assignment.
body_anchor = "        self.adjacentFullPreloadPCMByteLimit = adjacentFullPreloadPCMByteLimit ?? Self.maxAdjacentFullPreloadPCMBytes\n"
body_new = body_anchor + "        self.systemMemoryProvider = systemMemoryProvider ?? HostSystemMemoryProvider()\n"
assert src.count(body_anchor) == 2, "body anchor=%d (expected 2: one per init)" % src.count(body_anchor)
src = src.replace(body_anchor, body_new)

assert src != orig, "no change"
with open(path, "w") as f:
    f.write(src)
print("p3_state applied OK")
```

> NOTE on Step 4b: `self.adjacentFullPreloadPCMByteLimit = ...` appears **twice** (once per init — the convenience init at ~line 1009 uses `Self.maxAdjacentFullPreloadPCMBytes`, the injectable init at ~1039 uses the `??`). The assignment line text differs between the two (`Self.maxAdjacentFullPreloadPCMBytes` vs `adjacentFullPreloadPCMByteLimit ?? Self.maxAdjacentFullPreloadPCMBytes`). **Verify counts before running.** If the convenience init's line is `self.adjacentFullPreloadPCMByteLimit = Self.maxAdjacentFullPreloadPCMBytes` (no `??`), the anchor count for the `??` form is 1, not 2 — in that case split into two `replace` calls with the two distinct lines and add `self.systemMemoryProvider = HostSystemMemoryProvider()` to the convenience init. Confirm with:
> ```bash
> ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && grep -n "self.adjacentFullPreloadPCMByteLimit =" Sources/Orbisonic/OrbisonicViewModel.swift'
> ```
> Then adjust the patcher's `body_anchor` assertions to match reality before running.

- [ ] **Step 2: Apply the patcher**

```bash
scp /tmp/p3_state.py sonicsphere@100.104.46.1:/tmp/
ssh sonicsphere@100.104.46.1 'python3 /tmp/p3_state.py'
```
Expected: `p3_state applied OK`.

- [ ] **Step 3: Confirm `loadBool` exists (it does — used by `rendererAlwaysMono`)**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && grep -n "static func loadBool" Sources/Orbisonic/OrbisonicViewModel.swift'
```
Expected: one match. (If absent, add a small static helper that reads `UserDefaults.standard.object(forKey:)` with the default — but it is present per `rendererAlwaysMono`.)

- [ ] **Step 4: Build**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && swift build 2>&1 | tail -30'
```
Expected: `Build complete!`. (`scheduleAdjacentLocalFilePreloads` and `cancelLocalPreparedFilePreload` already exist; `removeAll()` exists on `LocalPreparedFileCache`.)

- [ ] **Step 5: Commit**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && git add Sources/Orbisonic/OrbisonicViewModel.swift && git -c user.name="rKalb" -c user.email="3437054+rKalb@users.noreply.github.com" commit -m "$(cat <<'\''EOF'\''
Add next-track preload setting, status, and lifecycle

preloadNextTrackEnabled (UserDefaults-backed, default off) triggers a
preload pass on enable and cancels + evicts the cached next-track PCM on
disable, freeing RAM immediately. Adds the injectable SystemMemoryProviding
dependency and the published nextTrackPreloadStatus. Gating still inert.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"'
```

---

## Task 4: Gating rework — runtime enablement, next-only candidates, adaptive budget + status

**Files:**
- Modify: `Sources/Orbisonic/OrbisonicViewModel.swift`
- Patcher (local): `/tmp/p4_gating.py`

Convert the static gates to: full-audio preload runs when `preloadNextTrackEnabled` (production) **or** the injected `preloadsAdjacentLocalMusicTracks` (tests); full-audio candidates are **next-only**; the budget is the adaptive `planNextTrackPreload` using a live memory snapshot; and the decision drives `nextTrackPreloadStatus`.

**Verified anchors:**
- In `scheduleAdjacentLocalFilePreloads`: `        let fullPCMPreloadEnabled = Self.enableAdjacentLocalPCMPreload && preloadsAdjacentLocalMusicTracks`
- The call: `        scheduleAdjacentFullLocalPCMPreloads(\n            candidates: candidates,\n            reason: reason,\n            generation: preloadGeneration\n        )`
- The whole `private func adjacentPreloadBudgetDecision(estimatedBytes: Int?) -> (allowed: Bool, reason: String) {` … through its closing — replaced wholesale.
- In the full-PCM scheduler loop: `                guard budgetDecision.allowed else { continue }`
- The store-success log call site marker: `                        storeResult.stored ? "adjacent full PCM preload finished" : "adjacent full PCM preload discarded",`

- [ ] **Step 1: Write the patcher**

Write `/tmp/p4_gating.py` locally:

```python
#!/usr/bin/env python3
path = "/Users/sonicsphere/Documents/Orbisonic/Sources/Orbisonic/OrbisonicViewModel.swift"
with open(path) as f:
    src = f.read()
orig = src

# 1) Enablement: production governed by the user toggle; tests force via the
#    injected preloadsAdjacentLocalMusicTracks param. (Drops the compile-time
#    enableAdjacentLocalPCMPreload=false gate for the full-audio path.)
en_anchor = "        let fullPCMPreloadEnabled = Self.enableAdjacentLocalPCMPreload && preloadsAdjacentLocalMusicTracks\n"
en_new = "        let fullPCMPreloadEnabled = preloadNextTrackEnabled || preloadsAdjacentLocalMusicTracks\n"
assert src.count(en_anchor) == 1, "en anchor=%d" % src.count(en_anchor)
src = src.replace(en_anchor, en_new)

# 2) Full-audio candidates are NEXT-ONLY. candidates[0] is the next track
#    (adjacentLocalFilePreloadCandidates iterates [nextIndex, previousIndex]).
call_anchor = (
    "        scheduleAdjacentFullLocalPCMPreloads(\n"
    "            candidates: candidates,\n"
    "            reason: reason,\n"
    "            generation: preloadGeneration\n"
    "        )\n"
)
call_new = (
    "        scheduleAdjacentFullLocalPCMPreloads(\n"
    "            candidates: Array(candidates.prefix(1)),\n"
    "            reason: reason,\n"
    "            generation: preloadGeneration\n"
    "        )\n"
)
assert src.count(call_anchor) == 1, "call anchor=%d" % src.count(call_anchor)
src = src.replace(call_anchor, call_new)

# 3) Replace the budget decision with the adaptive policy. When the user toggle
#    is on, use planNextTrackPreload against a live memory snapshot. When only
#    the injected test cap is in play (toggle off), keep the legacy byte-cap so
#    existing deterministic tests still pin behavior.
old_decision = (
    "    private func adjacentPreloadBudgetDecision(estimatedBytes: Int?) -> (allowed: Bool, reason: String) {\n"
    "        guard adjacentFullPreloadPCMByteLimit > 0 else {\n"
    "            return (false, \"adjacent full PCM preload cap is zero\")\n"
    "        }\n"
    "\n"
    "        guard let estimatedBytes, estimatedBytes > 0 else {\n"
    "            return (false, \"missing decoded PCM estimate\")\n"
    "        }\n"
    "\n"
    "        guard estimatedBytes <= adjacentFullPreloadPCMByteLimit else {\n"
    "            return (false, \"estimated decoded PCM exceeds adjacent preload cap\")\n"
    "        }\n"
    "\n"
    "        return (true, \"within adjacent preload cap\")\n"
    "    }\n"
)
new_decision = (
    "    private func adjacentPreloadBudgetDecision(estimatedBytes: Int?) -> (allowed: Bool, reason: String) {\n"
    "        if preloadNextTrackEnabled {\n"
    "            let memory = systemMemoryProvider.snapshot()\n"
    "            let decision = planNextTrackPreload(\n"
    "                estimatedBytes: estimatedBytes,\n"
    "                availableBytes: memory.availableBytes,\n"
    "                fraction: Self.nextTrackPreloadAvailableRAMFraction\n"
    "            )\n"
    "            switch decision {\n"
    "            case .allow:\n"
    "                return (true, \"within adaptive RAM budget\")\n"
    "            case .skipLowMemory:\n"
    "                nextTrackPreloadStatus = .skippedLowMemory\n"
    "                return (false, \"estimated decoded PCM exceeds adaptive RAM budget\")\n"
    "            case .skipUnknownSize:\n"
    "                nextTrackPreloadStatus = .skippedUnknownSize\n"
    "                return (false, \"missing decoded PCM estimate\")\n"
    "            }\n"
    "        }\n"
    "\n"
    "        guard adjacentFullPreloadPCMByteLimit > 0 else {\n"
    "            return (false, \"adjacent full PCM preload cap is zero\")\n"
    "        }\n"
    "        guard let estimatedBytes, estimatedBytes > 0 else {\n"
    "            return (false, \"missing decoded PCM estimate\")\n"
    "        }\n"
    "        guard estimatedBytes <= adjacentFullPreloadPCMByteLimit else {\n"
    "            return (false, \"estimated decoded PCM exceeds adjacent preload cap\")\n"
    "        }\n"
    "        return (true, \"within adjacent preload cap\")\n"
    "    }\n"
)
assert src.count(old_decision) == 1, "decision anchor=%d" % src.count(old_decision)
src = src.replace(old_decision, new_decision)

# 4) Add the fraction constant next to the other preload constants.
frac_anchor = "    private static let maxAdjacentFullPreloadPCMBytes = PreparedPCMPolicy.maxAdjacentFullPreloadPCMBytes\n"
frac_new = frac_anchor + "    private static let nextTrackPreloadAvailableRAMFraction = 0.5\n"
assert src.count(frac_anchor) == 1, "frac anchor=%d" % src.count(frac_anchor)
src = src.replace(frac_anchor, frac_new)

# 5) Status: mark .preparing right before the budget guard, .ready on store.
prep_anchor = "                guard budgetDecision.allowed else { continue }\n"
prep_new = (
    "                guard budgetDecision.allowed else { continue }\n"
    "                if self.preloadNextTrackEnabled { self.nextTrackPreloadStatus = .preparing }\n"
)
assert src.count(prep_anchor) == 1, "prep anchor=%d" % src.count(prep_anchor)
src = src.replace(prep_anchor, prep_new)

ready_anchor = '                        storeResult.stored ? "adjacent full PCM preload finished" : "adjacent full PCM preload discarded",\n'
# Set .ready immediately before logging the store outcome.
ready_pre = "                    let storeResult = self.localPreparedFileCache.store(\n"
assert src.count(ready_pre) == 1, "ready_pre anchor=%d" % src.count(ready_pre)
ready_pre_new = ready_pre  # keep; we inject after the store result is known
# Inject status set right after the store call's closing paren+expectedKey line.
store_close = (
    "                    let storeResult = self.localPreparedFileCache.store(\n"
    "                        loaded,\n"
    "                        for: candidate.track.url,\n"
    "                        expectedKey: candidate.key\n"
    "                    )\n"
)
store_close_new = store_close + (
    "                    if self.preloadNextTrackEnabled {\n"
    "                        self.nextTrackPreloadStatus = storeResult.stored ? .ready : .skippedLowMemory\n"
    "                    }\n"
)
assert src.count(store_close) == 1, "store_close anchor=%d" % src.count(store_close)
src = src.replace(store_close, store_close_new)

assert src != orig, "no change"
with open(path, "w") as f:
    f.write(src)
print("p4_gating applied OK")
```

- [ ] **Step 2: Apply + build**

```bash
scp /tmp/p4_gating.py sonicsphere@100.104.46.1:/tmp/
ssh sonicsphere@100.104.46.1 'python3 /tmp/p4_gating.py && cd ~/Documents/Orbisonic && swift build 2>&1 | tail -30'
```
Expected: `p4_gating applied OK` then `Build complete!`.

- [ ] **Step 3: Reset status to idle/noNextTrack when scheduling with no candidates**

When the toggle is on but the queue has no distinct next track, status should read `noNextTrack`; when a pass starts it should reset from a stale `skipped`. Write `/tmp/p4_reset.py`:

```python
#!/usr/bin/env python3
path = "/Users/sonicsphere/Documents/Orbisonic/Sources/Orbisonic/OrbisonicViewModel.swift"
with open(path) as f:
    src = f.read()
orig = src

# In scheduleAdjacentLocalFilePreloads, after computing candidates, set status
# when the user toggle owns the feature.
anchor = (
    "        let candidates = adjacentLocalFilePreloadCandidates()\n"
    "        guard !candidates.isEmpty else { return }\n"
)
new = (
    "        let candidates = adjacentLocalFilePreloadCandidates()\n"
    "        if preloadNextTrackEnabled {\n"
    "            nextTrackPreloadStatus = candidates.isEmpty ? .noNextTrack : .idle\n"
    "        }\n"
    "        guard !candidates.isEmpty else { return }\n"
)
assert src.count(anchor) == 1, "anchor=%d" % src.count(anchor)
src = src.replace(anchor, new)
assert src != orig
with open(path, "w") as f:
    f.write(src)
print("p4_reset applied OK")
```
```bash
scp /tmp/p4_reset.py sonicsphere@100.104.46.1:/tmp/
ssh sonicsphere@100.104.46.1 'python3 /tmp/p4_reset.py && cd ~/Documents/Orbisonic && swift build 2>&1 | tail -20'
```
Expected: `p4_reset applied OK` then `Build complete!`.

- [ ] **Step 4: Commit**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && git add Sources/Orbisonic/OrbisonicViewModel.swift && git -c user.name="rKalb" -c user.email="3437054+rKalb@users.noreply.github.com" commit -m "$(cat <<'\''EOF'\''
Gate next-track full-audio preload on the runtime toggle + adaptive RAM

Full-audio preload now runs when the user toggle is on (tests still force it
via the injected flag), uses next-only candidates, and admits a track only
when planNextTrackPreload approves it against a live memory snapshot. The
decision drives nextTrackPreloadStatus (preparing/ready/skipped/noNextTrack).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"'
```

---

## Task 5: Raise the prepared-cache byte ceiling when the toggle is on

**Files:**
- Modify: `Sources/Orbisonic/OrbisonicViewModel.swift`
- Patcher (local): `/tmp/p5_cache.py`

The cache rejects any store with `byteCount > maxBytes` (default 128 MiB). A multichannel track the adaptive gate *allows* (e.g. 264 MiB) would be wrongly rejected. So when the toggle turns on, raise the ceiling to a generous backstop (total physical RAM); when off, restore the 128 MiB default (and `removeAll`, already done in the didSet). The adaptive `planNextTrackPreload` gate remains the real admission control; the ceiling is only a backstop. When the toggle is off, `maxBytes` is unchanged from today, so the off-path is a no-op.

**Verified anchors:**
- `    private let maxBytes: Int\n`
- `    init(capacity: Int, maxBytes: Int) {\n        self.capacity = max(0, capacity)\n        self.maxBytes = max(0, maxBytes)\n    }\n`
- The toggle `didSet` enable branch line: `                scheduleAdjacentLocalFilePreloads(reason: "next-track preload enabled")\n`
- The disable branch line: `                localPreparedFileCache.removeAll()\n`

- [ ] **Step 1: Write the patcher**

Write `/tmp/p5_cache.py` locally:

```python
#!/usr/bin/env python3
path = "/Users/sonicsphere/Documents/Orbisonic/Sources/Orbisonic/OrbisonicViewModel.swift"
with open(path) as f:
    src = f.read()
orig = src

# 1) Make maxBytes mutable.
mb_anchor = "    private let maxBytes: Int\n"
mb_new = "    private var maxBytes: Int\n"
assert src.count(mb_anchor) == 1, "mb anchor=%d" % src.count(mb_anchor)
src = src.replace(mb_anchor, mb_new)

# 2) Add a runtime updater right after the cache init.
init_anchor = (
    "    init(capacity: Int, maxBytes: Int) {\n"
    "        self.capacity = max(0, capacity)\n"
    "        self.maxBytes = max(0, maxBytes)\n"
    "    }\n"
)
init_new = init_anchor + (
    "\n"
    "    mutating func updateMaxBytes(_ newValue: Int) {\n"
    "        maxBytes = max(0, newValue)\n"
    "        evictIfNeeded()\n"
    "    }\n"
)
assert src.count(init_anchor) == 1, "init anchor=%d" % src.count(init_anchor)
src = src.replace(init_anchor, init_new)

# 3) Raise the ceiling on enable, restore default on disable.
enable_anchor = '                scheduleAdjacentLocalFilePreloads(reason: "next-track preload enabled")\n'
enable_new = (
    "                localPreparedFileCache.updateMaxBytes(systemMemoryProvider.snapshot().totalBytes)\n"
    + enable_anchor
)
assert src.count(enable_anchor) == 1, "enable anchor=%d" % src.count(enable_anchor)
src = src.replace(enable_anchor, enable_new)

disable_anchor = "                localPreparedFileCache.removeAll()\n"
disable_new = (
    disable_anchor
    + "                localPreparedFileCache.updateMaxBytes(Self.maxPreparedCacheBytes)\n"
)
assert src.count(disable_anchor) == 1, "disable anchor=%d" % src.count(disable_anchor)
src = src.replace(disable_anchor, disable_new)

assert src != orig
with open(path, "w") as f:
    f.write(src)
print("p5_cache applied OK")
```

- [ ] **Step 2: Apply + build**

```bash
scp /tmp/p5_cache.py sonicsphere@100.104.46.1:/tmp/
ssh sonicsphere@100.104.46.1 'python3 /tmp/p5_cache.py && cd ~/Documents/Orbisonic && swift build 2>&1 | tail -20'
```
Expected: `p5_cache applied OK` then `Build complete!`.

- [ ] **Step 3: Commit**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && git add Sources/Orbisonic/OrbisonicViewModel.swift && git -c user.name="rKalb" -c user.email="3437054+rKalb@users.noreply.github.com" commit -m "$(cat <<'\''EOF'\''
Raise prepared-cache ceiling while next-track preload is on

The 128 MiB cap would reject large multichannel tracks the adaptive gate
allows, so enabling the toggle raises the cache ceiling to total RAM (a
backstop; planNextTrackPreload stays the real admission control) and
disabling restores the default. Off-path maxBytes is unchanged.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"'
```

---

## Task 6: Behavioral tests (CI) + await hook + status testing hook

**Files:**
- Modify: `Sources/Orbisonic/OrbisonicViewModel.swift` (add 2 testing hooks)
- Modify: `Tests/OrbisonicTests/LocalPlayerStabilizationTests.swift`
- Patcher (local): `/tmp/p6_hooks.py`

Add `awaitNextTrackPreloadForTesting()` (awaits the in-flight preload task) and `setPreloadStatusForTesting(_:)` (used by the web-state test in Task 7). Then add behavioral tests proving: toggle on + generous RAM → next track prepared + status `.ready`; tiny RAM → status `.skippedLowMemory` + next NOT prepared.

**Verified anchors:**
- `    func hasPreparedLocalFileForTesting(path: String) -> Bool {\n        localPreparedFileCache.containsValid(for: URL(fileURLWithPath: path))\n    }\n`

- [ ] **Step 1: Add the testing hooks (patcher)**

Write `/tmp/p6_hooks.py` locally:

```python
#!/usr/bin/env python3
path = "/Users/sonicsphere/Documents/Orbisonic/Sources/Orbisonic/OrbisonicViewModel.swift"
with open(path) as f:
    src = f.read()
orig = src

anchor = (
    "    func hasPreparedLocalFileForTesting(path: String) -> Bool {\n"
    "        localPreparedFileCache.containsValid(for: URL(fileURLWithPath: path))\n"
    "    }\n"
)
new = anchor + (
    "\n"
    "    func awaitNextTrackPreloadForTesting() async {\n"
    "        await localPreparedFilePreloadTask?.value\n"
    "    }\n"
    "\n"
    "    func setPreloadStatusForTesting(_ status: NextTrackPreloadStatus) {\n"
    "        nextTrackPreloadStatus = status\n"
    "    }\n"
)
assert src.count(anchor) == 1, "anchor=%d" % src.count(anchor)
src = src.replace(anchor, new)
assert src != orig
with open(path, "w") as f:
    f.write(src)
print("p6_hooks applied OK")
```
```bash
scp /tmp/p6_hooks.py sonicsphere@100.104.46.1:/tmp/
ssh sonicsphere@100.104.46.1 'python3 /tmp/p6_hooks.py && cd ~/Documents/Orbisonic && swift build 2>&1 | tail -20'
```
Expected: `p6_hooks applied OK` then `Build complete!`.

- [ ] **Step 2: Write the behavioral tests (patcher appends to the test file)**

These use a `StubMemoryProvider` and the existing `TemporaryLocalMusicFixture` / `writeSilentAudioFile` helpers. Write `/tmp/p6_tests.py` locally. It inserts the stub + two tests before the final closing brace of `LocalPlayerStabilizationTests`.

> Before writing, confirm the exact tail of the test file and the `LocalMusicTrack` initializer fields (id/url/title/duration/sampleRate/channelCount) with:
> ```bash
> ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && grep -n "struct LocalMusicTrack\|LocalMusicTrack(" Sources/Orbisonic/*.swift | head; grep -n "func writeSilentAudioFile\|struct TemporaryLocalMusicFixture\|static func delayedLoader" Tests/OrbisonicTests/*.swift | head'
> ```
> Adjust the track construction in the patcher to match the real initializer. The skeleton below assumes `LocalMusicTrack(id:url:title:artist:album:duration:sampleRate:channelCount:)` — **fix field names/order to match.**

```python
#!/usr/bin/env python3
path = "/Users/sonicsphere/Documents/Orbisonic/Tests/OrbisonicTests/LocalPlayerStabilizationTests.swift"
with open(path) as f:
    src = f.read()
orig = src

# A deterministic memory provider for the budget gate.
stub = '''
private struct StubMemoryProvider: SystemMemoryProviding {
    let availableBytes: Int
    let totalBytes: Int
    func snapshot() -> SystemMemorySnapshot {
        SystemMemorySnapshot(availableBytes: availableBytes, totalBytes: totalBytes)
    }
}
'''

tests = '''
    @MainActor
    func testNextTrackPreloadPreparesNextWhenBudgetAllows() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }
        let firstURL = fixture.directory.appendingPathComponent("first.wav")
        let nextURL = fixture.directory.appendingPathComponent("next.wav")
        try Self.writeSilentAudioFile(to: firstURL, frames: 48_000)
        try Self.writeSilentAudioFile(to: nextURL, frames: 48_000)

        let model = OrbisonicViewModel(
            systemMemoryProvider: StubMemoryProvider(availableBytes: 16_000_000_000, totalBytes: 32_000_000_000)
        )
        model.setSourceModeForTesting(.filePlayback)
        model.replaceLocalMusicQueueForTesting(
            tracks: [Self.localTrack(url: firstURL), Self.localTrack(url: nextURL)],
            currentIndex: 0,
            selectedIndex: 0
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)

        model.preloadNextTrackEnabled = true
        await model.awaitNextTrackPreloadForTesting()

        XCTAssertTrue(model.hasPreparedLocalFileForTesting(path: nextURL.path))
        XCTAssertEqual(model.nextTrackPreloadStatus, .ready)
    }

    @MainActor
    func testNextTrackPreloadSkipsWhenMemoryIsTight() async throws {
        let fixture = try TemporaryLocalMusicFixture()
        defer { fixture.remove() }
        let firstURL = fixture.directory.appendingPathComponent("first.wav")
        let nextURL = fixture.directory.appendingPathComponent("next.wav")
        try Self.writeSilentAudioFile(to: firstURL, frames: 48_000)
        try Self.writeSilentAudioFile(to: nextURL, frames: 48_000)

        let model = OrbisonicViewModel(
            systemMemoryProvider: StubMemoryProvider(availableBytes: 1_024, totalBytes: 32_000_000_000)
        )
        model.setSourceModeForTesting(.filePlayback)
        model.replaceLocalMusicQueueForTesting(
            tracks: [Self.localTrack(url: firstURL), Self.localTrack(url: nextURL)],
            currentIndex: 0,
            selectedIndex: 0
        )
        try await model.loadQueueIndexForTesting(0, isPlaying: true)

        model.preloadNextTrackEnabled = true
        await model.awaitNextTrackPreloadForTesting()

        XCTAssertFalse(model.hasPreparedLocalFileForTesting(path: nextURL.path))
        XCTAssertEqual(model.nextTrackPreloadStatus, .skippedLowMemory)
    }
'''

# Insert the two tests before the final closing brace of the test class.
# The file ends with "}\n" closing the class (and possibly trailing helpers).
# Strategy: append a helper `localTrack` + tests inside the class. Find the
# LAST "}\n" and insert before it; place the StubMemoryProvider after it (top
# level). Verify the tail shape first (see note above) and adjust if helpers
# trail the class.
last_brace_idx = src.rstrip().rfind("\n}")
assert last_brace_idx != -1, "no closing brace found"
# Add a localTrack factory + tests inside the class, before the closing brace.
helper = '''
    static func localTrack(url: URL) -> LocalMusicTrack {
        LocalMusicTrack(
            id: url.path,
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            artist: "",
            album: "",
            duration: 1.0,
            sampleRate: 48_000,
            channelCount: 2
        )
    }
'''
insertion = helper + tests + "\n"
src = src[:last_brace_idx] + "\n" + insertion + src[last_brace_idx:]
# Append the stub provider at the very end (top-level type).
src = src.rstrip() + "\n" + stub
assert src != orig
with open(path, "w") as f:
    f.write(src)
print("p6_tests applied OK")
```
```bash
scp /tmp/p6_tests.py sonicsphere@100.104.46.1:/tmp/
ssh sonicsphere@100.104.46.1 'python3 /tmp/p6_tests.py && cd ~/Documents/Orbisonic && swift build 2>&1 | tail -40'
```
Expected: `p6_tests applied OK` then `Build complete!`. If the build fails on `LocalMusicTrack(...)` field mismatch, fix `localTrack` to the real initializer and re-run.

- [ ] **Step 3: Commit**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && git add Sources/Orbisonic/OrbisonicViewModel.swift Tests/OrbisonicTests/LocalPlayerStabilizationTests.swift && git -c user.name="rKalb" -c user.email="3437054+rKalb@users.noreply.github.com" commit -m "$(cat <<'\''EOF'\''
Add behavioral tests for next-track preload budget gate

Toggle on with generous injected RAM prepares the next track and reports
.ready; a tiny RAM snapshot skips the preload and reports .skippedLowMemory.
Adds awaitNextTrackPreloadForTesting + setPreloadStatusForTesting hooks.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"'
```

---

## Task 7: Web state `preload` struct + population + web-state test

**Files:**
- Modify: `Sources/Orbisonic/OrbisonicWebServer.swift`
- Modify: `Tests/OrbisonicTests/OrbisonicWebStateTests.swift`
- Patchers (local): `/tmp/p7_webstate.py`, `/tmp/p7_test.py`

Add `OrbisonicWebState.Preload { enabled, status, nextLabel, nextEstimateBytes, freeBytes, totalBytes }`, wire it into `makeWebState`, and add a VM helper that computes the readout. Refresh happens whenever web-state is built (already low-frequency; no busy polling added).

**Verified anchors (OrbisonicWebServer.swift):**
- The `Activity` struct block ends with `        let progress: Double?\n    }\n\n    let generatedAt: String`
- `    let controlEnabled: Bool\n    let activity: Activity\n`
- In `makeWebState`: the `activity: OrbisonicWebState.Activity(...)` initializer is followed by `            urls: OrbisonicWebState.URLs(`

- [ ] **Step 1: Add the struct + the `preload` field (patcher)**

Write `/tmp/p7_webstate.py` locally:

```python
#!/usr/bin/env python3
path = "/Users/sonicsphere/Documents/Orbisonic/Sources/Orbisonic/OrbisonicWebServer.swift"
with open(path) as f:
    src = f.read()
orig = src

# 1) Declare the Preload struct right after the Activity struct.
struct_anchor = (
    "    struct Activity: Encodable {\n"
    "        let phase: String\n"
    "        let label: String\n"
    "        let isBusy: Bool\n"
    "        let isIndeterminate: Bool\n"
    "        let progress: Double?\n"
    "    }\n"
)
struct_new = struct_anchor + (
    "\n"
    "    struct Preload: Encodable {\n"
    "        let enabled: Bool\n"
    "        let status: String\n"
    "        let statusLabel: String\n"
    "        let nextLabel: String?\n"
    "        let nextEstimateBytes: Int?\n"
    "        let freeBytes: Int\n"
    "        let totalBytes: Int\n"
    "    }\n"
)
assert src.count(struct_anchor) == 1, "struct anchor=%d" % src.count(struct_anchor)
src = src.replace(struct_anchor, struct_new)

# 2) Add the stored field next to `activity`.
field_anchor = "    let controlEnabled: Bool\n    let activity: Activity\n"
field_new = "    let controlEnabled: Bool\n    let activity: Activity\n    let preload: Preload\n"
assert src.count(field_anchor) == 1, "field anchor=%d" % src.count(field_anchor)
src = src.replace(field_anchor, field_new)

# 3) Populate it in makeWebState, right after the activity initializer.
make_anchor = (
    "            urls: OrbisonicWebState.URLs(\n"
)
make_new = (
    "            preload: makeWebPreloadState(),\n"
    "            urls: OrbisonicWebState.URLs(\n"
)
assert src.count(make_anchor) == 1, "make anchor=%d" % src.count(make_anchor)
src = src.replace(make_anchor, make_new)

# 4) Add the builder in the same `extension OrbisonicViewModel` as makeWebState.
builder_anchor = "    func webStateForTesting(controlEnabled: Bool) -> OrbisonicWebState {\n"
builder_new = (
    "    fileprivate func makeWebPreloadState() -> OrbisonicWebState.Preload {\n"
    "        let summary = nextTrackPreloadWebSummary()\n"
    "        return OrbisonicWebState.Preload(\n"
    "            enabled: preloadNextTrackEnabled,\n"
    "            status: nextTrackPreloadStatus.webToken,\n"
    "            statusLabel: nextTrackPreloadStatus.displayLabel,\n"
    "            nextLabel: summary.nextLabel,\n"
    "            nextEstimateBytes: summary.nextEstimateBytes,\n"
    "            freeBytes: summary.freeBytes,\n"
    "            totalBytes: summary.totalBytes\n"
    "        )\n"
    "    }\n"
    "\n"
    + builder_anchor
)
assert src.count(builder_anchor) == 1, "builder anchor=%d" % src.count(builder_anchor)
src = src.replace(builder_anchor, builder_new)

assert src != orig
with open(path, "w") as f:
    f.write(src)
print("p7_webstate applied OK")
```

- [ ] **Step 2: Add the `nextTrackPreloadWebSummary()` helper to the ViewModel**

Write `/tmp/p7_summary.py` locally. It adds the helper near `adjacentLocalFilePreloadCandidates`. It reads the next candidate (first of the next-only list) for the label/estimate and the memory provider for free/total.

```python
#!/usr/bin/env python3
path = "/Users/sonicsphere/Documents/Orbisonic/Sources/Orbisonic/OrbisonicViewModel.swift"
with open(path) as f:
    src = f.read()
orig = src

anchor = "    private func estimatedPreparedPCMBytes(for track: LocalMusicTrack) -> Int? {\n"
new = (
    "    func nextTrackPreloadWebSummary() -> (nextLabel: String?, nextEstimateBytes: Int?, freeBytes: Int, totalBytes: Int) {\n"
    "        let memory = systemMemoryProvider.snapshot()\n"
    "        let next = adjacentLocalFilePreloadCandidates().first\n"
    "        return (\n"
    "            nextLabel: next?.track.displayTitle,\n"
    "            nextEstimateBytes: next?.estimatedDecodedBytes,\n"
    "            freeBytes: memory.availableBytes,\n"
    "            totalBytes: memory.totalBytes\n"
    "        )\n"
    "    }\n"
    "\n"
    + anchor
)
assert src.count(anchor) == 1, "anchor=%d" % src.count(anchor)
src = src.replace(anchor, new)
assert src != orig
with open(path, "w") as f:
    f.write(src)
print("p7_summary applied OK")
```

> Confirm `LocalMusicTrack` exposes `displayTitle` (used elsewhere in ContentView for visible track titles): `ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && grep -n "displayTitle" Sources/Orbisonic/*.swift | head'`. If the property is named differently, adjust `next?.track.displayTitle`.

- [ ] **Step 3: Apply + build**

```bash
scp /tmp/p7_webstate.py /tmp/p7_summary.py sonicsphere@100.104.46.1:/tmp/
ssh sonicsphere@100.104.46.1 'python3 /tmp/p7_webstate.py && python3 /tmp/p7_summary.py && cd ~/Documents/Orbisonic && swift build 2>&1 | tail -30'
```
Expected: both `applied OK` then `Build complete!`.

- [ ] **Step 4: Add the web-state test (patcher)**

> First read the existing test file head to match its construction pattern (how it builds a VM and calls `webStateForTesting`): `ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && sed -n "1,60p" Tests/OrbisonicTests/OrbisonicWebStateTests.swift'`. Then write `/tmp/p7_test.py` to insert a test before the class's closing brace:

```python
#!/usr/bin/env python3
path = "/Users/sonicsphere/Documents/Orbisonic/Tests/OrbisonicTests/OrbisonicWebStateTests.swift"
with open(path) as f:
    src = f.read()
orig = src

test = '''
    @MainActor
    func testWebStateExposesPreloadStatus() {
        let model = OrbisonicViewModel()
        model.preloadNextTrackEnabled = false
        model.setPreloadStatusForTesting(.ready)

        let state = model.webStateForTesting(controlEnabled: true)

        XCTAssertEqual(state.preload.status, "ready")
        XCTAssertEqual(state.preload.statusLabel, "Ready")
        XCTAssertFalse(state.preload.enabled)
        XCTAssertGreaterThan(state.preload.totalBytes, 0)
    }
'''

idx = src.rstrip().rfind("\n}")
assert idx != -1, "no closing brace"
src = src[:idx] + "\n" + test + src[idx:]
assert src != orig
with open(path, "w") as f:
    f.write(src)
print("p7_test applied OK")
```
```bash
scp /tmp/p7_test.py sonicsphere@100.104.46.1:/tmp/
ssh sonicsphere@100.104.46.1 'python3 /tmp/p7_test.py && cd ~/Documents/Orbisonic && swift build 2>&1 | tail -30'
```
Expected: `p7_test applied OK` then `Build complete!`.

> Note: disabling the toggle in the test triggers the didSet `removeAll()` + `updateMaxBytes` + reads `systemMemoryProvider` — all fine with the live provider in a unit test. Setting `false` when it is already `false` is a no-op (the didSet guards `!= oldValue`), so call `setPreloadStatusForTesting(.ready)` AFTER, as written.

- [ ] **Step 5: Commit**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && git add Sources/Orbisonic/OrbisonicWebServer.swift Sources/Orbisonic/OrbisonicViewModel.swift Tests/OrbisonicTests/OrbisonicWebStateTests.swift && git -c user.name="rKalb" -c user.email="3437054+rKalb@users.noreply.github.com" commit -m "$(cat <<'\''EOF'\''
Surface next-track preload status in web state

Adds OrbisonicWebState.Preload (enabled, status, next label/estimate, free
and total RAM) populated from the live memory snapshot and the next-only
candidate, so /control can mirror the preload readout.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"'
```

---

## Task 8: Native Settings toggle + caption

**Files:**
- Modify: `Sources/Orbisonic/OrbisonicViewModel.swift` (add caption computed property)
- Modify: `Sources/Orbisonic/ContentView.swift`
- Patchers (local): `/tmp/p8_caption.py`, `/tmp/p8_toggle.py`

Place the toggle under the existing **"Sound Settings"** panel (the Playback grouping). The caption shows free RAM, the next track's estimate, and the live status, e.g. `Free memory: 22.4 GB · Next ≈ 264 MB — Ready`.

- [ ] **Step 1: Add the caption computed property (patcher)**

Write `/tmp/p8_caption.py` locally. Insert right after `nextTrackPreloadWebSummary()`:

```python
#!/usr/bin/env python3
path = "/Users/sonicsphere/Documents/Orbisonic/Sources/Orbisonic/OrbisonicViewModel.swift"
with open(path) as f:
    src = f.read()
orig = src

anchor = "    func nextTrackPreloadWebSummary() -> (nextLabel: String?, nextEstimateBytes: Int?, freeBytes: Int, totalBytes: Int) {\n"
# Insert the caption property immediately before the summary function.
prop = (
    "    var nextTrackPreloadCaptionText: String {\n"
    "        let summary = nextTrackPreloadWebSummary()\n"
    "        let formatter = ByteCountFormatter()\n"
    "        formatter.allowedUnits = [.useGB, .useMB]\n"
    "        formatter.countStyle = .memory\n"
    "        var parts: [String] = [\"Free memory: \\(formatter.string(fromByteCount: Int64(summary.freeBytes)))\"]\n"
    "        if let bytes = summary.nextEstimateBytes, bytes > 0 {\n"
    "            parts.append(\"Next \\u{2248} \\(formatter.string(fromByteCount: Int64(bytes)))\")\n"
    "        }\n"
    "        if preloadNextTrackEnabled {\n"
    "            parts.append(nextTrackPreloadStatus.displayLabel)\n"
    "        }\n"
    "        return parts.joined(separator: \" \\u{00B7} \")\n"
    "    }\n"
    "\n"
)
assert src.count(anchor) == 1, "anchor=%d" % src.count(anchor)
src = src.replace(anchor, prop + anchor)
assert src != orig
with open(path, "w") as f:
    f.write(src)
print("p8_caption applied OK")
```

- [ ] **Step 2: Add the toggle to the Sound Settings panel (patcher)**

The "Sound Settings" panel currently ends with the "Compressed trim metadata" toggle row. Append the preload toggle after it. Write `/tmp/p8_toggle.py` locally:

```python
#!/usr/bin/env python3
path = "/Users/sonicsphere/Documents/Orbisonic/Sources/Orbisonic/ContentView.swift"
with open(path) as f:
    src = f.read()
orig = src

anchor = (
    "                    settingsToggleRow(\n"
    "                        title: \"Compressed trim metadata\",\n"
    "                        isOn: $model.isLocalGaplessCompressedTrimEnabled,\n"
    "                        isEnabled: model.isLocalGaplessSchedulerEnabled\n"
    "                    )\n"
)
new = anchor + (
    "\n"
    "                    settingsToggleRow(\n"
    "                        title: \"Preload next track\",\n"
    "                        isOn: $model.preloadNextTrackEnabled,\n"
    "                        helpText: \"Decode the next queued track into memory so skips are instant. Works for any track; skipped automatically when memory is tight.\"\n"
    "                    )\n"
    "\n"
    "                    Text(model.nextTrackPreloadCaptionText)\n"
    "                        .font(.system(size: 11, weight: .medium))\n"
    "                        .foregroundStyle(LabTheme.textSoft)\n"
    "                        .fixedSize(horizontal: false, vertical: true)\n"
)
assert src.count(anchor) == 1, "anchor=%d" % src.count(anchor)
src = src.replace(anchor, new)
assert src != orig
with open(path, "w") as f:
    f.write(src)
print("p8_toggle applied OK")
```

- [ ] **Step 3: Apply + build**

```bash
scp /tmp/p8_caption.py /tmp/p8_toggle.py sonicsphere@100.104.46.1:/tmp/
ssh sonicsphere@100.104.46.1 'python3 /tmp/p8_caption.py && python3 /tmp/p8_toggle.py && cd ~/Documents/Orbisonic && swift build 2>&1 | tail -30'
```
Expected: both `applied OK` then `Build complete!`.

- [ ] **Step 4: Deploy + manual UI check**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && ./scripts/refresh-orbisonic-app.sh && pkill -x Orbisonic; sleep 1; open ~/Documents/Orbisonic/Orbisonic.app'
```
Open Settings → Sound Settings. Confirm: the "Preload next track" toggle appears with its help text and the caption reads a live `Free memory: …` line. Toggle on with a multi-track queue playing → caption status flips to `Preparing…` then `Ready`; toggle off → status text disappears and (per the lifecycle) the cached PCM is evicted.

- [ ] **Step 5: Commit**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && git add Sources/Orbisonic/OrbisonicViewModel.swift Sources/Orbisonic/ContentView.swift && git -c user.name="rKalb" -c user.email="3437054+rKalb@users.noreply.github.com" commit -m "$(cat <<'\''EOF'\''
Add Preload next track toggle + memory caption to Settings

Settings → Sound Settings gains the opt-in toggle and a live caption showing
free RAM, the next track estimate, and the preload status so the choice is
transparent.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"'
```

---

## Task 9: Native player chip, web /control mirror, source-invariant harness

**Files:**
- Modify: `Sources/Orbisonic/ContentView.swift` (player chip)
- Modify: `Sources/Orbisonic/OrbisonicWebControlPage.swift` (web mirror)
- Modify: `Tests/OrbisonicTests/ExistingUIFreezeTests.swift` (source-invariant)
- Patchers (local): `/tmp/p9_chip.py`, `/tmp/p9_web.py`, `/tmp/p9_invariant.py`

- [ ] **Step 1: Native player chip (patcher)**

Show a small `Next: <name> — <status>` chip in the now-playing media block when the toggle is on. Write `/tmp/p9_chip.py`:

```python
#!/usr/bin/env python3
path = "/Users/sonicsphere/Documents/Orbisonic/Sources/Orbisonic/ContentView.swift"
with open(path) as f:
    src = f.read()
orig = src

anchor = "                if let badge = model.pureSphericalLosslessBadgePresentation {\n"
new = (
    "                if model.preloadNextTrackEnabled {\n"
    "                    Text(\"Next: \\(model.nextTrackPreloadWebSummary().nextLabel ?? \"—\") — \\(model.nextTrackPreloadStatus.displayLabel)\")\n"
    "                        .font(.system(size: 11, weight: .semibold))\n"
    "                        .foregroundStyle(LabTheme.textSoft)\n"
    "                        .lineLimit(1)\n"
    "                        .truncationMode(.tail)\n"
    "                }\n"
    "\n"
    + anchor
)
assert src.count(anchor) == 1, "anchor=%d" % src.count(anchor)
src = src.replace(anchor, new)
assert src != orig
with open(path, "w") as f:
    f.write(src)
print("p9_chip applied OK")
```

- [ ] **Step 2: Web /control mirror (patcher)**

Add a chip element after `npSrc` and a `renderPreload` call wired into `render`. Write `/tmp/p9_web.py`:

```python
#!/usr/bin/env python3
path = "/Users/sonicsphere/Documents/Orbisonic/Sources/Orbisonic/OrbisonicWebControlPage.swift"
with open(path) as f:
    src = f.read()
orig = src

# 1) HTML element after the np-src span.
html_anchor = '            <span class="np-src" id="npSrc" hidden></span>\n'
html_new = html_anchor + '            <div class="np-preload" id="preloadChip" hidden></div>\n'
assert src.count(html_anchor) == 1, "html anchor=%d" % src.count(html_anchor)
src = src.replace(html_anchor, html_new)

# 2) Call renderPreload from render().
call_anchor = "  renderActivity(s.activity);\n"
call_new = "  renderActivity(s.activity);\n  renderPreload(s.preload);\n"
assert src.count(call_anchor) == 1, "call anchor=%d" % src.count(call_anchor)
src = src.replace(call_anchor, call_new)

# 3) Define renderPreload after renderActivity's closing brace.
fn_anchor = (
    "  if(indet){fill.style.width='';}\n"
    "  else{const p=Math.max(0,Math.min(1,Number(a.progress)||0));fill.style.width=(p*100)+'%';}\n"
    "}\n"
)
fn_new = fn_anchor + (
    "\n"
    "function renderPreload(p){\n"
    "  const el=$('preloadChip');if(!el)return;\n"
    "  if(!p||!p.enabled){el.hidden=true;return;}\n"
    "  el.hidden=false;\n"
    "  const next=clean(p.nextLabel)||'\\u2014';\n"
    "  el.textContent='Next: '+next+' \\u2014 '+(clean(p.statusLabel)||'Idle');\n"
    "}\n"
)
assert src.count(fn_anchor) == 1, "fn anchor=%d" % src.count(fn_anchor)
src = src.replace(fn_anchor, fn_new)

assert src != orig
with open(path, "w") as f:
    f.write(src)
print("p9_web applied OK")
```

> If the `renderActivity` body text differs slightly from `fn_anchor`, re-grep the two lines and update the anchor before running.

- [ ] **Step 3: Source-invariant harness (patcher into ExistingUIFreezeTests)**

Assert the wiring survives refactors: the Settings binding exists and full-audio candidates are next-only. Write `/tmp/p9_invariant.py` (mirrors the existing `block(named:endingBefore:in:)` style already in this file):

```python
#!/usr/bin/env python3
path = "/Users/sonicsphere/Documents/Orbisonic/Tests/OrbisonicTests/ExistingUIFreezeTests.swift"
with open(path) as f:
    src = f.read()
orig = src

anchor = "    private func block(named startMarker: String, endingBefore endMarker: String, in source: String) throws -> String {\n"
test = (
    "    func testNextTrackPreloadIsWiredAndNextOnly() throws {\n"
    "        let vm = try source(\"Sources/Orbisonic/OrbisonicViewModel.swift\")\n\n"
    "        // The user setting exists and is UserDefaults-backed.\n"
    "        XCTAssertTrue(vm.contains(\"preloadNextTrackEnabled\"))\n"
    "        XCTAssertTrue(vm.contains(\"Orbisonic.preloadNextTrackEnabled\"))\n\n"
    "        // Full-audio preload is governed by the toggle and the adaptive budget.\n"
    "        XCTAssertTrue(vm.contains(\"planNextTrackPreload\"))\n\n"
    "        // Full-audio candidates are next-only (prefix 1); metadata stays next+prev.\n"
    "        let scheduleBlock = try block(\n"
    "            named: \"private func scheduleAdjacentLocalFilePreloads\",\n"
    "            endingBefore: \"private func scheduleAdjacentLocalMetadataPreloads\",\n"
    "            in: vm\n"
    "        )\n"
    "        XCTAssertTrue(scheduleBlock.contains(\"Array(candidates.prefix(1))\"))\n\n"
    "        let cv = try source(\"Sources/Orbisonic/ContentView.swift\")\n"
    "        XCTAssertTrue(cv.contains(\"$model.preloadNextTrackEnabled\"))\n"
    "    }\n\n"
    + anchor
)
assert src.count(anchor) == 1, "anchor=%d" % src.count(anchor)
src = src.replace(anchor, test)
assert src != orig
with open(path, "w") as f:
    f.write(src)
print("p9_invariant applied OK")
```

- [ ] **Step 4: Apply, build, and run the source-invariant harness locally**

```bash
scp /tmp/p9_chip.py /tmp/p9_web.py /tmp/p9_invariant.py sonicsphere@100.104.46.1:/tmp/
ssh sonicsphere@100.104.46.1 'python3 /tmp/p9_chip.py && python3 /tmp/p9_web.py && python3 /tmp/p9_invariant.py && cd ~/Documents/Orbisonic && swift build 2>&1 | tail -30'
```
Expected: three `applied OK` then `Build complete!`. (The committed XCTests run in CI; the source-invariant assertions are plain string checks that CI will execute.)

- [ ] **Step 5: Deploy + verify both surfaces**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && ./scripts/refresh-orbisonic-app.sh && pkill -x Orbisonic; sleep 1; open ~/Documents/Orbisonic/Orbisonic.app; sleep 4; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:37943/Orbisonic/control'
```
Expected: `200`. With the toggle on and a queue playing, the native now-playing card shows the `Next: … — Ready` chip and `/control` shows the matching `Next: …` chip.

- [ ] **Step 6: Commit**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && git add Sources/Orbisonic/ContentView.swift Sources/Orbisonic/OrbisonicWebControlPage.swift Tests/OrbisonicTests/ExistingUIFreezeTests.swift && git -c user.name="rKalb" -c user.email="3437054+rKalb@users.noreply.github.com" commit -m "$(cat <<'\''EOF'\''
Mirror next-track preload status in player chip and /control

Adds a Next: <name> — <status> chip to the native now-playing card and the
web control page, plus a source-invariant test pinning the toggle wiring and
the next-only full-audio candidate selection.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"'
```

---

## Task 10: Off-path regression check + full integration verification + push

**Files:** none modified — verification only.

- [ ] **Step 1: Confirm the toggle-off path is a no-op vs. today**

Spec risk: ensure that with the toggle **off**, current-track behavior is unchanged. Verify by inspection + a targeted check:
- `adjacentPreloadBudgetDecision` with `preloadNextTrackEnabled == false` falls through to the original cap logic (`adjacentFullPreloadPCMByteLimit > 0` → with the production default of 0, returns `false`), so no full-audio preload happens. ✔
- `maxBytes` is only raised inside the enable branch; the disable branch restores `Self.maxPreparedCacheBytes`. A fresh launch with the toggle off never calls `updateMaxBytes`, so the cache ceiling stays 128 MiB. ✔
- Confirm the existing `testAdjacentFullPCMPreloadIsDisabledByDefault` still holds: `adjacentFullLocalPCMPreloadEnabledForTesting` is `Self.enableAdjacentLocalPCMPreload && preloadsAdjacentLocalMusicTracks` — unchanged (still false by default). The new runtime path is separate.

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && grep -n "adjacentFullLocalPCMPreloadEnabledForTesting\|enableAdjacentLocalPCMPreload" Sources/Orbisonic/OrbisonicViewModel.swift'
```
Expected: `enableAdjacentLocalPCMPreload = false` still present; the `…ForTesting` getter unchanged. Both legacy disabled-by-default tests remain valid.

- [ ] **Step 2: Confirm auto-advance consumes the cache (not just manual skip)**

Spec risk: the load path's `takeValid` must be hit on auto-advance too. The load path goes through `preparedLocalFile(for:)` (line ~4311) → `localPreparedFileCache.takeValid(for: request.url)` for **all** local loads, regardless of whether triggered by manual skip or natural advance (`LocalFileQueueCommit(isNaturalAdvance:)`). Verify there is no branch that bypasses `preparedLocalFile` on natural advance:

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && grep -n "preparedLocalFile(for:\|isNaturalAdvance\|takeValid" Sources/Orbisonic/OrbisonicViewModel.swift'
```
Expected: a single `takeValid` consumption site reached by the common load path. If a natural-advance branch is found that skips it, add a behavioral test (mirroring Task 6) that advances naturally and asserts a prepared-cache hit, then fix the branch. Otherwise, note the shared path as sufficient.

- [ ] **Step 3: Full package build (all tests compile)**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && swift build 2>&1 | tail -40'
```
Expected: `Build complete!`.

- [ ] **Step 4: End-to-end manual test (any track, incl. multichannel)**

Deploy, then with the app:
1. Toggle **on** in Settings. Caption shows `Free memory: … · Next ≈ … · Ready/Preparing…`.
2. Queue a large **multichannel/Atmos** file as the next track. Confirm caption status reaches `Ready` (proves "works for any track", not size-limited — the adaptive gate, not a track-type heuristic, governs).
3. Skip forward → playback starts instantly (cache hit).
4. Let a track auto-advance → next starts instantly.
5. Constrain memory (open heavy apps) or use a very large next file on a busy machine → status reads `Skipped (low memory)` and the next track foreground-decodes on skip (still correct, just not instant).
6. Toggle **off** → status text clears; RAM is released (cache evicted).

- [ ] **Step 5: Push the branch to the canonical repo**

```bash
ssh sonicsphere@100.104.46.1 'cd ~/Documents/Orbisonic && git push fork feat/next-track-preload'
```
Then open a PR against `Sonic-Sphere/Orbisonic` (not `origin`). Title: `Add opt-in next-track audio preload with adaptive memory budget`.

---

## Self-Review (run before handing off)

**Spec coverage** (against `docs/superpowers/specs/2026-05-31-next-track-preload-design.md`):
- §1 Setting & lifecycle → Task 3 (toggle + didSet enable/disable, evict). ✔
- §2 Gating rework (runtime enablement, next-only) → Task 4. ✔
- §3 Adaptive RAM budget (pure `planNextTrackPreload`, `SystemMemory` injectable) → Tasks 1, 2, 4. ✔
- §4 Cache capacity (raise ceiling when on; adaptive admit-gate is real control) → Task 5. ✔
- §5 Preload execution + status model → Tasks 1, 4. ✔
- §6 Transparency (web state, Settings caption, player chip, /control mirror) → Tasks 7, 8, 9. ✔
- §7 Settings placement (Playback grouping = Sound Settings panel) → Task 8. ✔
- Testing (pure swiftc harness, behavioral, web-state, source-invariant) → Tasks 1, 6, 7, 9. ✔
- Risks (SystemMemory validation, off-path no-op, auto-advance takeValid) → Tasks 2, 10. ✔

**Type consistency:** `NextTrackPreloadDecision` (.allow/.skipLowMemory/.skipUnknownSize) is the pure-function result; `NextTrackPreloadStatus` (.idle/.preparing/.ready/.skippedLowMemory/.skippedUnknownSize/.noNextTrack) is the published UI state — distinct types, mapped in `adjacentPreloadBudgetDecision`/the scheduler. `webToken`/`displayLabel`/`isBusy` used consistently across web state, caption, and chip. `nextTrackPreloadWebSummary()` tuple field names (`nextLabel`, `nextEstimateBytes`, `freeBytes`, `totalBytes`) match `OrbisonicWebState.Preload`'s fields.

**Anchor risk:** several patchers depend on multi-line anchors that may drift as earlier tasks edit the file. Each patcher asserts its anchor count; if a later task shifts an anchor, the assert fails loudly — re-grep and update before re-running. The one explicitly flagged double-count is Task 3 Step 4b (`self.adjacentFullPreloadPCMByteLimit =` — verify 2 vs 1).

**Placeholder scan:** no TBD/TODO; every code step has full code; every command has expected output.
