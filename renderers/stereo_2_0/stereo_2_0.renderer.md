# Stereo (parametric) — Sonic Sphere renderer spec

- **Layout id:** `stereo_2_0`  ·  **Family:** stereo  ·  **Channels:** 2 (0 LFE)
- **Target:** Fey 30.1 dome (30 full-range + sub)  ·  **Algorithm:** cosine-power directional panning v1.0.0
- **Provenance:** `Sonic-Sphere/spat-speaker-layouts/layout_geometry.csv` @ `8d20f7f87d`

## What this renderer does

Parametric stereo — the special one. L and R are placed symmetrically at ∓θ/2 and ±θ/2, and the single control θ is the ANGLE BETWEEN THEM. Sweeping θ continuously reshapes the image: at 0° the two channels collapse to front-center (mono); at 60° you get a conventional loudspeaker pair; at 90° a wide frontal stage; at 180° L and R sit at the hard sides for a fully enveloping image. Each channel is then panned onto the dome by the same geometry engine, so as θ grows the two images glide smoothly apart from the center to the sides.

## ⭐ Adjustable control — the L↔R angle

The single knob is **`angleBetweenLRDegrees`** (range **0–180°**, default **90°**): L sits at **−angle/2**, R at **+angle/2**, then each is panned onto the dome.

| angle | preset | what you hear | L → top dome speakers | R → top dome speakers |
|--:|---|---|---|---|
| 0° | Mono collapse | L and R coincide at front-center — a single mono image. | #12@+0°, #23@+0°, #17@-36° | #12@+0°, #23@+0°, #17@-36° |
| 60° | Classic stereo | conventional loudspeaker pair at ∓30° — natural frontal stage. | #6@-41°, #12@+0°, #17@-36° | #7@+41°, #12@+0°, #18@+36° |
| 90° | Wide (Stereo 90) | broad frontal image at ≃45° — the previous default. | #6@-41°, #11@-72°, #17@-36° | #7@+41°, #13@+72°, #18@+36° |
| 180° | Enveloping (180) | L and R at the hard sides (≃90°) — maximally wide / enveloping. | #11@-72°, #16@-108°, #22@-73° | #13@+72°, #19@+108°, #8@+108° |

At **0°** both columns are identical (mono); as the angle opens, L slides left and R slides right until they reach the hard sides at **180°**.

## Source geometry

| # | label | role | azimuth° | elev° | x | y | z | LFE |
|--:|---|---|--:|--:|--:|--:|--:|:--:|
| 0 | `L` | frontLeft | -45 | 0 | -0.707 | 0.707 | 0.000 |  |
| 1 | `R` | frontRight | 45 | 0 | 0.707 | 0.707 | 0.000 |  |

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
| `L` | frontLeft | #6@-41°:0.47, #11@-72°:0.47, #17@-36°:0.47, #22@-73°:0.33, #12@+0°:0.29 |
| `R` | frontRight | #7@+41°:0.47, #13@+72°:0.47, #18@+36°:0.47, #24@+72°:0.34, #12@+0°:0.29 |

## Reproducibility

- Kernel is fully regenerable from *source geometry + algorithm parameters* above (computed live from the angle for stereo).
- Machine-readable spec: [`stereo_2_0.renderer.json`](./stereo_2_0.renderer.json)
- `kernelSha256`: `005e7758f2bdf99aa33681c72405693568f62683c00392b3b71b460b6ab0421f`
