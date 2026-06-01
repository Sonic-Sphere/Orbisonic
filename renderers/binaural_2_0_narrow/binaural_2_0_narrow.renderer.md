# Binaural 2.0 (narrow) — Sonic Sphere renderer spec

- **Layout id:** `binaural_2_0_narrow`  ·  **Family:** binaural  ·  **Channels:** 2 (0 LFE)
- **Target:** Fey 30.1 dome (30 full-range + sub)  ·  **Algorithm:** cosine-power directional panning v1.0.0
- **Provenance:** `Sonic-Sphere/spat-speaker-layouts/layout_geometry.csv` @ `8d20f7f87d`

## What this renderer does

A deliberately narrow ±15° stereo pair for binaural/near-field material, keeping L and R tight to front-center for an intimate, head-locked image. For binaural content meant to wrap around you, prefer the parametric Stereo renderer opened to a wide angle.

## Source geometry

| # | label | role | azimuth° | elev° | x | y | z | LFE |
|--:|---|---|--:|--:|--:|--:|--:|:--:|
| 0 | `LeftEar` | frontLeft | -15 | 0 | -0.259 | 0.966 | 0.000 |  |
| 1 | `RightEar` | frontRight | 15 | 0 | 0.259 | 0.966 | 0.000 |  |

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
| `LeftEar` | frontLeft | #12@+0°:0.47, #17@-36°:0.47, #23@+0°:0.45, #6@-41°:0.41, #28@-36°:0.26 |
| `RightEar` | frontRight | #12@+0°:0.47, #18@+36°:0.47, #23@+0°:0.45, #7@+41°:0.41, #29@+36°:0.26 |

## Reproducibility

- Kernel is fully regenerable from *source geometry + algorithm parameters* above.
- Machine-readable spec: [`binaural_2_0_narrow.renderer.json`](./binaural_2_0_narrow.renderer.json)
- `kernelSha256`: `732676fbcc93ae1fc4b29175fc84cddf56f3c9d13d08bfb8883e548a5c7e0cc0`
