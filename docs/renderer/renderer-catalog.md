# Orbisonic Renderer Catalog

Stable IDs and descriptive names for every renderer in the Sonic Sphere renderer
(`RendererRenderMode` in [`Sources/Orbisonic/RendererModule.swift`](../../Sources/Orbisonic/RendererModule.swift)).
Each renderer maps a source channel layout onto the 30.1 Sonic Sphere via `FeyStaticBedRenderer`.

`rendererId` values are **permanent** identifiers (diagnostics, presets, telemetry): never
renumber an existing renderer — only append new IDs for new renderers.

| ID | Enum case | rawValue | Display name | Descriptive name | Source ch | Family |
|---:|-----------|----------|--------------|------------------|:---------:|--------|
| 0 | `automatic` | `automatic` | Auto | Automatic Source-Matched Selector | any | Selector — resolves to the renderer matching the source channel count |
| 1 | `mono` | `mono` | Mono | Mono Omnifield Bed | 1 | Rendered bed |
| 2 | `stereo` | `stereo` | Stereo 90 | Stereo 90 Frontal Bed | 2 | Rendered bed — **active default for 2-channel sources** |
| 3 | `binaural` | `binaural_180` | Binaural 180 | Binaural 180 Hemisphere Bed | 2 | Rendered bed — opt-in alternative for 2-channel sources |
| 4 | `quad` | `quad` | Quad | Quadraphonic 4.0 Corner Bed | 4 | Rendered bed |
| 5 | `surround51` | `surround51` | 5.1 | Surround 5.1 Cinema Bed | 6 | Rendered bed |
| 6 | `auro80` | `auro_8_0` | Auro 8.0 | Auro 8.0 Height Bed | 8 | Auro bed |
| 7 | `auro91` | `auro_9_1` | Auro 9.1 | Auro 9.1 Height Bed | 10 | Auro bed |
| 8 | `auro101` | `auro_10_1` | Auro 10.1 | Auro 10.1 Top + Height Bed | 11 | Auro bed |
| 9 | `auro111714h` | `auro_11_1_7_1_4h` | Auro 11.1 7+4H | Auro 11.1 (7.1 + 4 Height) Bed | 12 | Auro bed |
| 10 | `auro111515hT` | `auro_11_1_5_1_5h_t` | Auro 11.1 5+5H+T | Auro 11.1 (5.1 + 5 Height + Top) Bed | 12 | Auro bed |
| 11 | `auro121` | `auro_12_1` | Auro 12.1 | Auro 12.1 Height Bed | 13 | Auro bed |
| 12 | `auro131` | `auro_13_1` | Auro 13.1 | Auro 13.1 Height + Top Bed | 14 | Auro bed |
| 13 | `direct30` | `direct30` | Direct 30 | Direct 30 Sphere Passthrough | 30 | Passthrough — identity map to the 30 full-range outputs |
| 14 | `direct31` | `direct31` | Direct 30.1 | Direct 30.1 Sphere Passthrough | 31 | Passthrough — identity map incl. LFE |
| 15 | `directPassthrough` | `direct_passthrough` | Direct Passthrough | Direct N-Channel Passthrough | 1–64 | Passthrough — first min(N, 31) channels 1:1; extras dropped; 31st → LFE |

## Active renderer (as shipped)

At launch the renderer mode is forced to **Auto** — `loadRendererRenderMode()` returns
`.automatic` — and the two-channel preference defaults to **Stereo 90** —
`loadRendererTwoChannelPreference()` returns `.stereo`.

So a **two-channel (stereo) source renders through renderer 2 — Stereo 90 Frontal Bed.**
Binaural 180 (renderer 3) is used only when the user switches the two-channel preference.
Auto otherwise selects the renderer whose source channel count matches the input; channel
counts with no named layout fall back to renderer 15 (Direct N-Channel Passthrough).

The `rendererId` and `descriptiveName` for each mode are defined on `RendererRenderMode`.
