# Renderer design — cosine-power directional panning v1.0.0

Each non-LFE source channel is aimed in its real-world direction and spread across the nearest dome speakers by angular proximity, then loudness-normalized with a per-speaker cap so the image is even and enveloping. LFE goes to the sub.

## Formula

```
w_i = max(0, d · ŝ_i)^p over the 30 dome speakers; iteratively clip any w_i to a_max = sqrt(cap) and renormalize to unit L2 power (sum w_i^2 = 1); LFE channels map to the sub at unity.
```

## Adjustable parameters

- **`cosineSharpness`** = `3.0` — Focus of each channel's spread. Higher = tighter (a channel drives fewer, closer dome speakers); lower = broader and more diffuse. At 3.0 each channel lights ~4-6 nearest speakers.
- **`perSpeakerPowerCap`** = `0.22` — No single dome speaker may carry more than this share of a channel's power. It forces every channel to spread across several speakers, so images feel enveloping instead of pin-point, and no one speaker dominates.
- **`normalization`** = `unitL2Power` — Each channel's gains are scaled so its total power sums to 1. Spreading a channel across many speakers is therefore neither louder nor quieter than putting it on one speaker — loudness stays constant as geometry changes.
- **`capIterations`** = `6` — How many clip-then-renormalize passes enforce the per-speaker cap. 6 is plenty for the cap to settle.
- **`lfeRouting`** = `31` — LFE / direct-out channels skip the dome panning entirely and go straight to the sub (output 31) at unity gain.

## Coordinate convention

```json
{
  "x": "listener-right",
  "y": "front",
  "z": "up",
  "azimuth": "degrees from front, positive to the right",
  "radius": "unit (LFE excluded)"
}
```

The dome target (30 speakers + sub) is in [`sphere-fey-30.1.json`](./sphere-fey-30.1.json) (sha256 `0aec319a8dd0431e32191332ebd53f247a91b30a7ef54be7a3df4429893d9393`).

## Special: the Stereo renderer

`stereo_2_0` is **parametric** — its only control is `angleBetweenLRDegrees` (0–180°, default 90°), the angle between L and R. L is placed at −angle/2 and R at +angle/2, then panned by the engine above. 0° = mono collapse, 60° = classic stereo, 90° = wide, 180° = hard-sides/enveloping. It codegens to a function of the angle rather than a static table.
