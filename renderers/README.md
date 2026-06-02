# Sonic Sphere Renderer Specs

Each renderer is a reproducible bundle: source geometry + design math + helpful explanations + the resulting kernel, in machine-readable JSON and human-readable Markdown. See [`DESIGN.md`](./DESIGN.md) and the dome target [`sphere-fey-30.1.json`](./sphere-fey-30.1.json). Every renderer also feeds the sub(s) a mono bass sum for the dancefloor (music/club — see DESIGN.md).

| Layout | Name | Family | ch | LFE | Notes | Spec |
|---|---|---|--:|--:|---|---|
| `mono_1_0` | Mono 1.0 | mono | 1 | derived |  | [json](./mono_1_0/mono_1_0.renderer.json) · [md](./mono_1_0/mono_1_0.renderer.md) |
| `stereo_2_0` | Stereo (parametric) | stereo | 2 | derived | ⭐ parametric L↔R angle 0–180° | [json](./stereo_2_0/stereo_2_0.renderer.json) · [md](./stereo_2_0/stereo_2_0.renderer.md) |
| `binaural_2_0_narrow` | Binaural 2.0 (narrow) | binaural | 2 | derived |  | [json](./binaural_2_0_narrow/binaural_2_0_narrow.renderer.json) · [md](./binaural_2_0_narrow/binaural_2_0_narrow.renderer.md) |
| `quad_4_0` | Quad 4.0 | quad | 4 | derived |  | [json](./quad_4_0/quad_4_0.renderer.json) · [md](./quad_4_0/quad_4_0.renderer.md) |
| `5_1` | 5.1 | dolby | 6 | ✓ |  | [json](./5_1/5_1.renderer.json) · [md](./5_1/5_1.renderer.md) |
| `5_1_2` | Dolby 5.1.2 | dolby | 8 | ✓ |  | [json](./5_1_2/5_1_2.renderer.json) · [md](./5_1_2/5_1_2.renderer.md) |
| `5_1_4` | Dolby 5.1.4 | dolby | 10 | ✓ |  | [json](./5_1_4/5_1_4.renderer.json) · [md](./5_1_4/5_1_4.renderer.md) |
| `7_1` | Dolby 7.1 | dolby | 8 | ✓ |  | [json](./7_1/7_1.renderer.json) · [md](./7_1/7_1.renderer.md) |
| `7_1_2` | Dolby 7.1.2 | dolby | 10 | ✓ |  | [json](./7_1_2/7_1_2.renderer.json) · [md](./7_1_2/7_1_2.renderer.md) |
| `7_1_4` | Dolby 7.1.4 | dolby | 12 | ✓ |  | [json](./7_1_4/7_1_4.renderer.json) · [md](./7_1_4/7_1_4.renderer.md) |
| `9_1_4` | Dolby 9.1.4 | dolby | 14 | ✓ |  | [json](./9_1_4/9_1_4.renderer.json) · [md](./9_1_4/9_1_4.renderer.md) |
| `9_1_6` | Dolby 9.1.6 | dolby | 16 | ✓ |  | [json](./9_1_6/9_1_6.renderer.json) · [md](./9_1_6/9_1_6.renderer.md) |
| `harmony_bloom_8ch` | Harmony Bloom (8ch) | custom | 8 | derived |  | [json](./harmony_bloom_8ch/harmony_bloom_8ch.renderer.json) · [md](./harmony_bloom_8ch/harmony_bloom_8ch.renderer.md) |
| `auro_8_0` | Auro 8.0 | auro | 8 | derived |  | [json](./auro_8_0/auro_8_0.renderer.json) · [md](./auro_8_0/auro_8_0.renderer.md) |
| `auro_9_1` | Auro 9.1 | auro | 10 | ✓ |  | [json](./auro_9_1/auro_9_1.renderer.json) · [md](./auro_9_1/auro_9_1.renderer.md) |
| `auro_10_1` | Auro 10.1 | auro | 11 | ✓ |  | [json](./auro_10_1/auro_10_1.renderer.json) · [md](./auro_10_1/auro_10_1.renderer.md) |
| `auro_11_1_5_1_5h_t` | Auro 11.1 (5+5H+T) | auro | 12 | ✓ |  | [json](./auro_11_1_5_1_5h_t/auro_11_1_5_1_5h_t.renderer.json) · [md](./auro_11_1_5_1_5h_t/auro_11_1_5_1_5h_t.renderer.md) |
| `auro_11_1_7_1_4h` | Auro 11.1 (7+4H) | auro | 12 | ✓ |  | [json](./auro_11_1_7_1_4h/auro_11_1_7_1_4h.renderer.json) · [md](./auro_11_1_7_1_4h/auro_11_1_7_1_4h.renderer.md) |
| `auro_13_1` | Auro 13.1 | auro | 14 | ✓ |  | [json](./auro_13_1/auro_13_1.renderer.json) · [md](./auro_13_1/auro_13_1.renderer.md) |
