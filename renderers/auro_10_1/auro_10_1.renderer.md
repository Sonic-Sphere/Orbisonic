# Auro 10.1 — Sonic Sphere renderer spec

- **Layout id:** `auro_10_1`  ·  **Family:** auro  ·  **Channels:** 11  ·  **Sub:** discrete LFE + mono bass downmix
- **Target:** Fey 30.1 dome (30 full-range + sub)  ·  **Algorithm:** cosine-power directional panning v1.0.0
- **Provenance:** `Sonic-Sphere/spat-speaker-layouts/layout_geometry.csv` @ `8d20f7f87d`

## What this renderer does

Auro-3D 10.1: Auro 9.1 plus a single 'Top' (voice-of-god) channel at the dome apex.

## Source geometry

| # | label | role | azimuth° | elev° | x | y | z | LFE |
|--:|---|---|--:|--:|--:|--:|--:|:--:|
| 0 | `L` | frontLeft | -30 | 0 | -0.500 | 0.866 | 0.000 |  |
| 1 | `R` | frontRight | 30 | 0 | 0.500 | 0.866 | 0.000 |  |
| 2 | `C` | center | 0 | 0 | 0.000 | 1.000 | 0.000 |  |
| 3 | `LFE` | lfe | -45 | 0 | -1.000 | 1.000 | 0.000 | ✓ |
| 4 | `Ls` | sideLeft | -110 | 0 | -0.940 | -0.342 | 0.000 |  |
| 5 | `Rs` | sideRight | 110 | 0 | 0.940 | -0.342 | 0.000 |  |
| 6 | `HL` | heightFrontLeft | -30 | 30 | -0.433 | 0.750 | 0.500 |  |
| 7 | `HR` | heightFrontRight | 30 | 30 | 0.433 | 0.750 | 0.500 |  |
| 8 | `HLs` | heightRearLeft | -110 | 30 | -0.814 | -0.296 | 0.500 |  |
| 9 | `HRs` | heightRearRight | 110 | 30 | 0.814 | -0.296 | 0.500 |  |
| 10 | `T` | topCenter | 0 | 90 | 0.000 | 0.000 | 1.000 |  |

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
| `L` | frontLeft | #6@-41°:0.47, #12@+0°:0.47, #17@-36°:0.47, #11@-72°:0.34, #23@+0°:0.29 |
| `R` | frontRight | #7@+41°:0.47, #12@+0°:0.47, #18@+36°:0.47, #13@+72°:0.34, #23@+0°:0.29 |
| `C` | center | #12@+0°:0.47, #23@+0°:0.46, #17@-36°:0.45, #18@+36°:0.45, #6@-41°:0.22 |
| `LFE` | lfe | **→ SUB (output 31)** |
| `Ls` | sideLeft | #10@-108°:0.47, #15@-144°:0.47, #16@-108°:0.47, #11@-72°:0.40, #21@-144°:0.28 |
| `Rs` | sideRight | #8@+108°:0.47, #14@+144°:0.47, #19@+108°:0.47, #13@+72°:0.40, #25@+144°:0.28 |
| `HL` | heightFrontLeft | #17@-36°:0.48, #23@+0°:0.48, #28@-36°:0.48, #22@-73°:0.45, #12@+0°:0.19 |
| `HR` | heightFrontRight | #18@+36°:0.48, #23@+0°:0.48, #29@+36°:0.48, #24@+72°:0.46, #12@+0°:0.19 |
| `HLs` | heightRearLeft | #16@-108°:0.48, #21@-144°:0.48, #22@-73°:0.48, #27@-108°:0.48, #15@-144°:0.18 |
| `HRs` | heightRearRight | #19@+108°:0.48, #24@+72°:0.48, #25@+144°:0.48, #30@+108°:0.48, #14@+144°:0.18 |
| `T` | topCenter | #26@+180°:0.47, #27@-108°:0.46, #30@+108°:0.46, #28@-36°:0.32, #29@+36°:0.32 |
## Sub feed (mono bass for the dancefloor)

This layout has a discrete **`LFE`** channel feeding the sub, **plus** the mono bass sum of the mains.

This is a **music / club (disco)** system, not cinema. Every renderer feeds the sub(s) (output 31) a **mono bass sum** — mono keeps the dancefloor low end tight, loud and phase-coherent across a big multi-sub rig:

- the sub gets a **generous ≤400 Hz** (gentle 12 dB/oct) **mono sum** of all full-range channels — `L`, `R`, `C`, `Ls`, `Rs`, `HL`, `HR`, `HLs`, `HRs`, `T`;
- the discrete LFE is summed in at **unity** (no cinema +10 dB bump);
- the 30 dome speakers **run full-range** — the **club's own sub crossover** sets the final low-pass, so the renderer stays gentle.

**Sub-feed parameters:**

- **`subFeedLowPassHz`** = `400` — Feed the subs everything below ~400 Hz (a generous, gentle band-limit). This is NOT the final crossover — the club's own sub processor/crossover sets the real cutoff, so the renderer stays un-aggressive and just hands the subs a fat low-frequency bus.
- **`subFeedSlopeDbPerOct`** = `12` — Gentle 12 dB/oct low-pass on the sub feed; the club's sub rig provides the steep final roll-off.
- **`monoBass`** = `True` — Bass is summed to MONO before the subs. Mono sub bass is standard for clubs/discos — it keeps the dancefloor low end tight, powerful and phase-coherent across a big multi-sub rig (stereo bass smears and partially cancels on a large system).
- **`mainsHighPass`** = `none` — The renderer does NOT high-pass the 30 dome speakers — run them full-range; the subs add the bottom. Integration is left to the club's sub crossover / system processor.
- **`lfeGainDb`** = `0.0` — Discrete LFE channels (in multichannel music) are summed into the mono sub at UNITY. The cinema +10 dB LFE bump is intentionally NOT applied — this is music; the DJ/system sets sub level.


## Reproducibility

- Kernel is fully regenerable from *source geometry + algorithm parameters* above.
- Machine-readable spec: [`auro_10_1.renderer.json`](./auro_10_1.renderer.json)
- `kernelSha256`: `85c1d710b611a7979e14f9ea5029e69646df5f225b01771f0cd76ed620b8018d`
