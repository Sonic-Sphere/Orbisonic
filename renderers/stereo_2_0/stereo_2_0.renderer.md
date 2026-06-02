# Stereo (parametric) — Sonic Sphere renderer spec

- **Layout id:** `stereo_2_0`  ·  **Family:** stereo  ·  **Channels:** 2  ·  **Sub:** derived mono bass downmix
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
dome speakers run full-range; sub gets a gentle ≤400 Hz mono feed (see below)
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
## Sub feed (mono bass for the dancefloor)

This layout has **no discrete LFE** — its sub is a **derived mono bass downmix** (a mono sum of its channels).

This is a **music / club (disco)** system, not cinema. Every renderer feeds the sub(s) (output 31) a **mono bass sum** — mono keeps the dancefloor low end tight, loud and phase-coherent across a big multi-sub rig:

- the sub gets a **generous ≤400 Hz** (gentle 12 dB/oct) **mono sum** of all full-range channels — `L`, `R`;
- the 30 dome speakers **run full-range** — the **club's own sub crossover** sets the final low-pass, so the renderer stays gentle.

**Sub-feed parameters:**

- **`subFeedLowPassHz`** = `400` — Feed the subs everything below ~400 Hz (a generous, gentle band-limit). This is NOT the final crossover — the club's own sub processor/crossover sets the real cutoff, so the renderer stays un-aggressive and just hands the subs a fat low-frequency bus.
- **`subFeedSlopeDbPerOct`** = `12` — Gentle 12 dB/oct low-pass on the sub feed; the club's sub rig provides the steep final roll-off.
- **`monoBass`** = `True` — Bass is summed to MONO before the subs. Mono sub bass is standard for clubs/discos — it keeps the dancefloor low end tight, powerful and phase-coherent across a big multi-sub rig (stereo bass smears and partially cancels on a large system).
- **`mainsHighPass`** = `none` — The renderer does NOT high-pass the 30 dome speakers — run them full-range; the subs add the bottom. Integration is left to the club's sub crossover / system processor.
- **`lfeGainDb`** = `0.0` — Discrete LFE channels (in multichannel music) are summed into the mono sub at UNITY. The cinema +10 dB LFE bump is intentionally NOT applied — this is music; the DJ/system sets sub level.


## Reproducibility

- Kernel is fully regenerable from *source geometry + algorithm parameters* above (computed live from the angle for stereo).
- Machine-readable spec: [`stereo_2_0.renderer.json`](./stereo_2_0.renderer.json)
- `kernelSha256`: `005e7758f2bdf99aa33681c72405693568f62683c00392b3b71b460b6ab0421f`
