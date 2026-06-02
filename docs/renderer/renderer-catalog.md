# Sonic Sphere Renderer Catalog

The current renderer set is the **data-driven geometry-engine** catalog below — **19 layouts**, including the full **Dolby family**. Each renderer is a reproducible spec bundle (source geometry + the design math + the resulting kernel + a SpatGRIS speaker-setup XML) under [`renderers/`](../../renderers/) — see [`renderers/README.md`](../../renderers/README.md) and [`renderers/DESIGN.md`](../../renderers/DESIGN.md).

> **Sub feed:** every renderer feeds the sub(s) a **mono bass sum** for the dancefloor (music / club). 13 layouts fold a discrete LFE into that mono sum; the other 6 derive it. *(mono sub-bass: PR #17; SpatGRIS XML per folder: PR #15.)*

## Core

| Renderer | layout id | ch | LFE | Sub feed | Special | Spec |
|---|---|--:|:--:|---|---|---|
| Mono 1.0 | `mono_1_0` | 1 | — | derived mono bass |  | [json](../../renderers/mono_1_0/mono_1_0.renderer.json) · [md](../../renderers/mono_1_0/mono_1_0.renderer.md) |
| Stereo (parametric) | `stereo_2_0` | 2 | — | derived mono bass | ⭐ parametric L↔R angle 0–180° | [json](../../renderers/stereo_2_0/stereo_2_0.renderer.json) · [md](../../renderers/stereo_2_0/stereo_2_0.renderer.md) |
| Binaural 2.0 (narrow) | `binaural_2_0_narrow` | 2 | — | derived mono bass |  | [json](../../renderers/binaural_2_0_narrow/binaural_2_0_narrow.renderer.json) · [md](../../renderers/binaural_2_0_narrow/binaural_2_0_narrow.renderer.md) |
| Quad 4.0 | `quad_4_0` | 4 | — | derived mono bass |  | [json](../../renderers/quad_4_0/quad_4_0.renderer.json) · [md](../../renderers/quad_4_0/quad_4_0.renderer.md) |

## Dolby family

| Renderer | layout id | ch | LFE | Sub feed | Special | Spec |
|---|---|--:|:--:|---|---|---|
| 5.1 | `5_1` | 6 | ✓ | LFE + mono bass |  | [json](../../renderers/5_1/5_1.renderer.json) · [md](../../renderers/5_1/5_1.renderer.md) |
| Dolby 5.1.2 | `5_1_2` | 8 | ✓ | LFE + mono bass |  | [json](../../renderers/5_1_2/5_1_2.renderer.json) · [md](../../renderers/5_1_2/5_1_2.renderer.md) |
| Dolby 5.1.4 | `5_1_4` | 10 | ✓ | LFE + mono bass |  | [json](../../renderers/5_1_4/5_1_4.renderer.json) · [md](../../renderers/5_1_4/5_1_4.renderer.md) |
| Dolby 7.1 | `7_1` | 8 | ✓ | LFE + mono bass |  | [json](../../renderers/7_1/7_1.renderer.json) · [md](../../renderers/7_1/7_1.renderer.md) |
| Dolby 7.1.2 | `7_1_2` | 10 | ✓ | LFE + mono bass |  | [json](../../renderers/7_1_2/7_1_2.renderer.json) · [md](../../renderers/7_1_2/7_1_2.renderer.md) |
| Dolby 7.1.4 | `7_1_4` | 12 | ✓ | LFE + mono bass |  | [json](../../renderers/7_1_4/7_1_4.renderer.json) · [md](../../renderers/7_1_4/7_1_4.renderer.md) |
| Dolby 9.1.4 | `9_1_4` | 14 | ✓ | LFE + mono bass |  | [json](../../renderers/9_1_4/9_1_4.renderer.json) · [md](../../renderers/9_1_4/9_1_4.renderer.md) |
| Dolby 9.1.6 | `9_1_6` | 16 | ✓ | LFE + mono bass |  | [json](../../renderers/9_1_6/9_1_6.renderer.json) · [md](../../renderers/9_1_6/9_1_6.renderer.md) |

## Auro-3D

| Renderer | layout id | ch | LFE | Sub feed | Special | Spec |
|---|---|--:|:--:|---|---|---|
| Auro 8.0 | `auro_8_0` | 8 | — | derived mono bass |  | [json](../../renderers/auro_8_0/auro_8_0.renderer.json) · [md](../../renderers/auro_8_0/auro_8_0.renderer.md) |
| Auro 9.1 | `auro_9_1` | 10 | ✓ | LFE + mono bass |  | [json](../../renderers/auro_9_1/auro_9_1.renderer.json) · [md](../../renderers/auro_9_1/auro_9_1.renderer.md) |
| Auro 10.1 | `auro_10_1` | 11 | ✓ | LFE + mono bass |  | [json](../../renderers/auro_10_1/auro_10_1.renderer.json) · [md](../../renderers/auro_10_1/auro_10_1.renderer.md) |
| Auro 11.1 (7+4H) | `auro_11_1_7_1_4h` | 12 | ✓ | LFE + mono bass |  | [json](../../renderers/auro_11_1_7_1_4h/auro_11_1_7_1_4h.renderer.json) · [md](../../renderers/auro_11_1_7_1_4h/auro_11_1_7_1_4h.renderer.md) |
| Auro 11.1 (5+5H+T) | `auro_11_1_5_1_5h_t` | 12 | ✓ | LFE + mono bass |  | [json](../../renderers/auro_11_1_5_1_5h_t/auro_11_1_5_1_5h_t.renderer.json) · [md](../../renderers/auro_11_1_5_1_5h_t/auro_11_1_5_1_5h_t.renderer.md) |
| Auro 13.1 | `auro_13_1` | 14 | ✓ | LFE + mono bass |  | [json](../../renderers/auro_13_1/auro_13_1.renderer.json) · [md](../../renderers/auro_13_1/auro_13_1.renderer.md) |

## Custom

| Renderer | layout id | ch | LFE | Sub feed | Special | Spec |
|---|---|--:|:--:|---|---|---|
| Harmony Bloom (8ch) | `harmony_bloom_8ch` | 8 | — | derived mono bass |  | [json](../../renderers/harmony_bloom_8ch/harmony_bloom_8ch.renderer.json) · [md](../../renderers/harmony_bloom_8ch/harmony_bloom_8ch.renderer.md) |

## How a layout becomes a renderer

Each source channel is panned onto the 30-speaker dome by **direction** (cosine-power weighting + a per-speaker power cap), so the kernel is derived from geometry, not hand-tuned. Dolby vs Auro channel-order differences are handled by reading each channel's role/position. Full math: [`renderers/DESIGN.md`](../../renderers/DESIGN.md).

## Legacy Swift enum (`RendererRenderMode`)

The shipping Swift code still routes 2-channel/multichannel sources via the `RendererRenderMode` enum (IDs 0–15) in `Sources/Orbisonic/RendererModule.swift`. The geometry-engine renderers above **supersede** it — notably the enum has **no dedicated 6.1 / 7.1 / 7.1.2 beds** (8-/10-channel sources fall back to Auro by count), which is exactly the gap the Dolby family here closes. Wiring the geometry engine into Swift is tracked separately.

