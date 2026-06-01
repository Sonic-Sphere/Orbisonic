# Harmony Bloom (8ch) — Sonic Sphere renderer spec

- **Layout id:** `harmony_bloom_8ch`  ·  **Family:** custom  ·  **Channels:** 8 (0 LFE)
- **Target:** Fey 30.1 dome (30 full-range + sub)  ·  **Algorithm:** cosine-power directional panning v1.0.0
- **Provenance:** `Sonic-Sphere/spat-speaker-layouts/layout_geometry.csv` @ `8d20f7f87d`

## What this renderer does

A custom 8-point ring ('Harmony Bloom') whose channels carry NO standard roles — only positions. It works purely from geometry, which is precisely why a data-driven engine is required: each HB-n channel lands wherever its position points on the dome. Hand-tuned, role-based beds cannot express this layout.

## Source geometry

| # | label | role | azimuth° | elev° | x | y | z | LFE |
|--:|---|---|--:|--:|--:|--:|--:|:--:|
| 0 | `HB1` | discrete | 0 | 0 | 0.000 | 1.000 | 0.000 |  |
| 1 | `HB2` | discrete | 45 | 0 | 0.707 | 0.707 | 0.000 |  |
| 2 | `HB3` | discrete | 90 | 0 | 1.000 | 0.000 | 0.000 |  |
| 3 | `HB4` | discrete | 135 | 0 | 0.707 | -0.707 | 0.000 |  |
| 4 | `HB5` | discrete | 180 | 0 | 0.000 | -1.000 | 0.000 |  |
| 5 | `HB6` | discrete | -135 | 0 | -0.707 | -0.707 | 0.000 |  |
| 6 | `HB7` | discrete | -90 | 0 | -1.000 | 0.000 | 0.000 |  |
| 7 | `HB8` | discrete | -45 | 0 | -0.707 | 0.707 | 0.000 |  |

## How it's designed (the math)

Each non-LFE source channel is aimed in its real-world direction and spread across the nearest dome speakers by angular proximity, then loudness-normalized with a per-speaker cap so the image is even and enveloping. LFE goes to the sub.

```
w_i = max(0, d · ŝ_i) ^ p          p (cosineSharpness) = 3.0
clip w_i ≤ √cap, renormalize Σw_i²=1   cap = 0.22 (≤ 0.469 amplitude), 6 iters
LFE channels → sub (output 31) at unity
```

**What the adjustable parameters do:**

- **`cosineSharpness`** = `3.0` — Focus of each channel's spread. Higher = tighter (a channel drives fewer, closer dome speakers); lower = broader and more diffuse. At 3.0 each channel lights ~4-6 nearest speakers.
- **`perSpeakerPowerCap`** = `0.22` — No single dome speaker may carry more than this share of a channel's power. It forces every channel to spread across several speakers, so images feel enveloping instead of pin-point, and no one speaker dominates.
- **`normalization`** = `unitL2Power` — Each channel's gains are scaled so its total power sums to 1. Spreading a channel across many speakers is therefore neither louder nor quieter than putting it on one speaker — loudness stays constant as geometry changes.
- **`capIterations`** = `6` — How many clip-then-renormalize passes enforce the per-speaker cap. 6 is plenty for the cap to settle.
- **`lfeRouting`** = `31` — LFE / direct-out channels skip the dome panning entirely and go straight to the sub (output 31) at unity gain.

Coordinate convention: `+x` listener-right, `+y` front, `+z` up; azimuth 0° = front, + to the right.

## Resulting kernel (per channel → dome speakers)

| channel | role | dome speakers *(id @ azimuth : gain)* |
|---|---|---|
| `HB1` | discrete | #12@+0°:0.47, #23@+0°:0.46, #17@-36°:0.45, #18@+36°:0.45, #6@-41°:0.22 |
| `HB2` | discrete | #7@+41°:0.47, #13@+72°:0.47, #18@+36°:0.47, #24@+72°:0.34, #12@+0°:0.29 |
| `HB3` | discrete | #13@+72°:0.47, #19@+108°:0.47, #8@+108°:0.45, #24@+72°:0.45, #14@+144°:0.19 |
| `HB4` | discrete | #14@+144°:0.47, #19@+108°:0.47, #25@+144°:0.47, #8@+108°:0.37, #20@+180°:0.31 |
| `HB5` | discrete | #20@+180°:0.47, #9@+180°:0.46, #14@+144°:0.44, #15@-144°:0.44, #21@-144°:0.26 |
| `HB6` | discrete | #15@-144°:0.47, #16@-108°:0.47, #21@-144°:0.47, #10@-108°:0.37, #20@+180°:0.31 |
| `HB7` | discrete | #11@-72°:0.47, #16@-108°:0.47, #22@-73°:0.45, #10@-108°:0.45, #15@-144°:0.19 |
| `HB8` | discrete | #6@-41°:0.47, #11@-72°:0.47, #17@-36°:0.47, #22@-73°:0.33, #12@+0°:0.29 |

## Reproducibility

- Kernel is fully regenerable from *source geometry + algorithm parameters* above.
- Machine-readable spec: [`harmony_bloom_8ch.renderer.json`](./harmony_bloom_8ch.renderer.json)
- `kernelSha256`: `1a7e1284235c2b00cfaa5cbd2f04024cdb1e68f43bdd5a87dde2b8a236b15520`
