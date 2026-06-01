# Orbisonic

`Orbisonic` is a macOS app prototype for routing, monitoring, and rendering multichannel spatial audio for the Sonic Sphere.

It is intended to be a simple, reliable dashboard and renderer: a way to open multichannel audio files, accept live audio from external music players through a virtual sound card, render those sources for the Sonic Sphere's 3D spatial speaker system, and monitor the whole path from a compact native interface.

## What It Does

- Opens local audio files and playlists, including `.wav`, `.wave`, `.aif`, `.aiff`, `.caf`, `.flac`, `.m4a`, and `.mp3`
- Accepts live input from Roon and other external players through the dedicated Orbisonic virtual loopback inputs
- Controls Roon transport through the optional local Orbisonic Roon Bridge helper
- Routes each source channel into the renderer as a spatial input source
- Supports up to 64 source channels per file or live input route in this prototype build
- Builds a Sonic Sphere renderer scene with a 30.1 output topology by default
- Renders channel-bed and discrete multichannel sources for the Sonic Sphere
- Provides a binaural headphone and monitor path aimed at AirPods and other headphone outputs
- Includes Apple spatial-audio/head-tracking hooks where the output route, OS, and app signing entitlements allow them
- Shows live source, monitor, and renderer activity with compact routing VU meters
- Provides local queue controls, route diagnostics, renderer preset controls, and channel-walk test tones

## Surround And Channel Support

Orbisonic is built around channel beds and discrete multichannel sources. It does not decode Dolby Atmos object metadata, but it can render the channel bed that Core Audio exposes from a supported file or live input route.

Named layout handling currently includes:

- Mono
- Stereo
- Matrix-encoded stereo sources such as Circle Surround or Pro Logic, when decoded upstream or treated as stereo
- Quadraphonic / 4.0
- 5.0
- 5.1, including Dolby Digital/AC-3, E-AC-3, and DTS-style channel beds when Core Audio or an upstream decoder exposes them as channels
- 6.1
- 7.1
- 7.1.2
- 7.1.4
- 9.0
- 9.2
- 9.1.4
- 9.1.6
- Hexagonal, octagonal, and other discrete speaker layouts represented as channel beds
- Arbitrary discrete layouts up to 64 source channels

For channel counts outside the named surround layouts, Orbisonic falls back to an N-channel discrete layout. This prototype intentionally caps source files and live input requests at 64 channels, matching the Orbisonic loopback input driver limit and avoiding accidental allocation of impractically large audio files. Local file playback still depends on what `AVAudioFile` and Core Audio can decode and expose from the source file, along with memory and the selected input/output hardware.

## Sonic Sphere Renderer

The default renderer preset is `Sonic Sphere 30.1 Default`: 30 full-range spatial outputs plus one LFE bus. Source channels are mapped into a 3D scene, then translated into the Sonic Sphere output topology with a power-normalized matrix.

Orbisonic also keeps a binaural headphone/monitor path available for setup, checking, and AirPods-oriented listening. The Sonic Sphere renderer is the primary system target; the headphone path is a monitoring and preview surface.

### How stereo becomes 30.1

The renderer does not simply send Left to one speaker and Right to another. Each input channel is spread across a whole region of the dome using a fixed gain matrix that is built once and then applied with a single multiply-add per sample — no delays, filters, or decorrelation (a *static bed*):

![Stereo to 30.1 signal flow](docs/renderer/images/01_signal_flow.png)

The 30 speakers are grouped into front-left, front-right, rear-left, and rear-right "walls," each power-normalized and tilted slightly upward. Stereo pans `Left = 0.88·FL + 0.12·RL` and `Right = 0.88·FR + 0.12·RR`, so **Left lights up the left side of the dome and Right the right**, with the dead-ahead speakers shared to form a natural phantom centre:

![Stereo 90 dome map](docs/renderer/images/02_dome_map.png)

A two-channel source can also render as **Binaural 180**, where each channel wraps the *entire* hemisphere on its side — front and rear equally — to preserve the front/back and height cues already baked into binaural / HRTF material:

![Binaural 180 dome map](docs/renderer/images/05_binaural_dome.png)

See [`docs/renderer/stereo-to-30-1-renderer.md`](docs/renderer/stereo-to-30-1-renderer.md) for the full breakdown, or [`Sources/Orbisonic/RendererModule.swift`](Sources/Orbisonic/RendererModule.swift) (`FeyStaticBedRenderer`) for the implementation.

## Requirements

- macOS 14 or newer
- Xcode or the Xcode command line tools with Swift 5.10 or newer
- Orbisonic Inputs installed from the suite or virtual loopback inputs package, providing `Orbisonic Roon Input`, `Orbisonic Aux Cable`, and `Orbisonic Spotify Input`
- AirPods or another headphone output for binaural monitoring
- A Core Audio output route for the Sonic Sphere speaker system

## Run It

```bash
cd Orbisonic
./scripts/refresh-orbisonic-app.sh
./scripts/reopen-orbisonic-app.sh
```

Orbisonic is a macOS GUI app. For development launches, open `Orbisonic.app`
through LaunchServices with the reopen script above; do not run
`Orbisonic.app/Contents/MacOS/Orbisonic` directly.

## Installer

The packaged installers are:

- `installer/Orbisonic-1.3.1.pkg` for the app only
- `installer/OrbisonicSuite-1.3.1.pkg` for the app plus Orbisonic virtual input drivers

The app-only installer installs `Orbisonic.app` into `/Applications`. The suite installer also installs the Orbisonic virtual loopback inputs for Roon, Aux Cable, and Spotify live capture. Roon itself is optional and is needed only if you want Roon playback.

The previous `1.3` package assets are deprecated because the suite package payload was malformed. Use `1.3.1` or newer.

For live player capture, route Roon to `Orbisonic Roon Input`, route general app audio to `Orbisonic Aux Cable`, and use `Orbisonic Spotify Input` for the embedded Spotify receiver path. macOS may present this as a microphone permission prompt because app-level audio input devices share the same privacy gate.

## Roon Transport Control

Orbisonic can control Roon play, pause, stop, previous, and next through a local helper that registers as a Roon extension.

Install the helper dependencies once:

```sh
scripts/install-roon-bridge.sh
```

Then open Orbisonic, choose `Roon`, and enable `Orbisonic Roon Bridge` in Roon under Settings > Extensions. Roon gives the helper a local authorization token; no separate Roon API sign-in is required beyond the normal Roon Server account authorization.

## Head Tracking Note

The app enables Apple listener head-tracking hooks through `AVAudioEnvironmentNode`. Sensor-driven head tracking and personalized spatial audio profile access still require the matching entitlements in a properly signed Xcode target.

Use the included entitlement template if you open the package in Xcode:

- [Orbisonic.entitlements](./Orbisonic.entitlements)

Without those entitlements, the app still produces a fixed binaural spatial render.
