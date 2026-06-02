# Quad 4.0 — Sonic Sphere renderer spec

- **Layout id:** `quad_4_0`  ·  **Family:** quad  ·  **Channels:** 4  ·  **Sub:** derived mono bass downmix
- **Target:** Fey 30.1 dome (30 full-range + sub)  ·  **Algorithm:** cosine-power directional panning v1.0.0
- **Provenance:** `Sonic-Sphere/spat-speaker-layouts/layout_geometry.csv` @ `8d20f7f87d`

## What this renderer does

Four corner channels at ±45° (front) and ±135° (rear) — no center, no height. Maps to the four dome quadrants for a classic enveloping square; great for quad music and 4-corner ambience.

## Source geometry

| # | label | role | azimuth° | elev° | x | y | z | LFE |
|--:|---|---|--:|--:|--:|--:|--:|:--:|
| 0 | `FL` | frontLeft | -45 | 0 | -0.707 | 0.707 | 0.000 |  |
| 1 | `FR` | frontRight | 45 | 0 | 0.707 | 0.707 | 0.000 |  |
| 2 | `RL` | rearLeft | -135 | 0 | -0.707 | -0.707 | 0.000 |  |
| 3 | `RR` | rearRight | 135 | 0 | 0.707 | -0.707 | 0.000 |  |

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
| `FL` | frontLeft | #6@-41°:0.47, #11@-72°:0.47, #17@-36°:0.47, #22@-73°:0.33, #12@+0°:0.29 |
| `FR` | frontRight | #7@+41°:0.47, #13@+72°:0.47, #18@+36°:0.47, #24@+72°:0.34, #12@+0°:0.29 |
| `RL` | rearLeft | #15@-144°:0.47, #16@-108°:0.47, #21@-144°:0.47, #10@-108°:0.37, #20@+180°:0.31 |
| `RR` | rearRight | #14@+144°:0.47, #19@+108°:0.47, #25@+144°:0.47, #8@+108°:0.37, #20@+180°:0.31 |
## Sub feed (mono bass for the dancefloor)

This layout has **no discrete LFE** — its sub is a **derived mono bass downmix** (a mono sum of its channels).

This is a **music / club (disco)** system, not cinema. Every renderer feeds the sub(s) (output 31) a **mono bass sum** — mono keeps the dancefloor low end tight, loud and phase-coherent across a big multi-sub rig:

- the sub gets a **generous ≤400 Hz** (gentle 12 dB/oct) **mono sum** of all full-range channels — `FL`, `FR`, `RL`, `RR`;
- the 30 dome speakers **run full-range** — the **club's own sub crossover** sets the final low-pass, so the renderer stays gentle.

**Sub-feed parameters:**

- **`subFeedLowPassHz`** = `400` — Feed the subs everything below ~400 Hz (a generous, gentle band-limit). This is NOT the final crossover — the club's own sub processor/crossover sets the real cutoff, so the renderer stays un-aggressive and just hands the subs a fat low-frequency bus.
- **`subFeedSlopeDbPerOct`** = `12` — Gentle 12 dB/oct low-pass on the sub feed; the club's sub rig provides the steep final roll-off.
- **`monoBass`** = `True` — Bass is summed to MONO before the subs. Mono sub bass is standard for clubs/discos — it keeps the dancefloor low end tight, powerful and phase-coherent across a big multi-sub rig (stereo bass smears and partially cancels on a large system).
- **`mainsHighPass`** = `none` — The renderer does NOT high-pass the 30 dome speakers — run them full-range; the subs add the bottom. Integration is left to the club's sub crossover / system processor.
- **`lfeGainDb`** = `0.0` — Discrete LFE channels (in multichannel music) are summed into the mono sub at UNITY. The cinema +10 dB LFE bump is intentionally NOT applied — this is music; the DJ/system sets sub level.


## Reproducibility

- Kernel is fully regenerable from *source geometry + algorithm parameters* above.
- Machine-readable spec: [`quad_4_0.renderer.json`](./quad_4_0.renderer.json)
- `kernelSha256`: `11996b83c16ea036136574598b08214f8413656a095d972a013d76c7768bb028`
