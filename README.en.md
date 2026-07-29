# Second Display

[中文](README.md) · [English](README.en.md)

Second Display is an experimental project that turns a HarmonyOS NEXT phone or tablet into a real
macOS extended display. The Mac creates an independent desktop, captures and hardware-encodes it,
while the HarmonyOS app hardware-decodes the stream and sends touch gestures back to macOS.

> This project relies on the private macOS `CGVirtualDisplay` capability. It is suitable for
> research, personal use, and controlled environments, but OS updates may break compatibility and
> Apple notarization is not guaranteed for distributions that use private APIs.

## V1.2.1 highlights

- The HarmonyOS parser now shares bounded frame backing instead of copying each payload into a
  `VideoFrame`; only one unavoidable bounded copy remains before AVCodec input.
- Decoder-output P95, XComponent display-callback FPS, and display-interval P95 now feed the host's
  refresh-rate decisions. Surface teardown and generation changes unregister stale callbacks.
- Release sessions preserve the receiver's negotiated native resolution. Dynamic resolution is
  available only when explicitly enabled, while network and media pressure use separate hysteresis
  to prevent an incorrect bitrate reduction from locking high-motion content near 30 FPS.
- High-motion desktops use a more realistic ScreenCaptureKit delivery deadline and 2× bounded
  bitrate burst headroom. Drop metrics now distinguish staleness, queue replacement, encoder
  rejection, recovery gating, and failures for long-run diagnosis.

## What it can do

- **Create a real extended desktop** rather than mirroring the Mac screen.
- **Match the receiver's native resolution** instead of forcing 1920×1200.
- **Switch between landscape and portrait** with generation-safe virtual-display rebuilding.
- **Experiment safely with high refresh rates** while keeping 60 FPS as the release default.
  Explicitly enabled sessions may promote to 90/120 FPS from end-to-end health data and quickly
  downshift under encoder, queue, thermal, or network pressure.
- **Hardware-encode and decode H.264 or HEVC** with VideoToolbox on macOS and AVCodec plus an
  XComponent Surface on HarmonyOS. Low-latency desktop sessions currently prefer H.264 and retain
  HEVC as a supported fallback.
- **Prioritize low latency** with ScreenCaptureKit, latest-frame queues, no B-frames, IDR recovery,
  direct Surface rendering, and stale-frame dropping.
- **Adapt to network conditions** using RTT, sender and decoder queues, drop counts, and receiver
  render FPS to adjust bitrate and resolution.
- **Reduce static-desktop work** with ScreenCaptureKit `dirtyRects` and idle delivery while
  preventing a low source frame rate from being misclassified as network congestion.
- **Control the Mac with touch**, including pointer movement, click, drag, two-finger scroll, and
  three-, four-, or five-finger swipe and pinch gestures.
- **Recover safely** from network changes, brief disconnects, Surface recreation, sleep/wake, and
  orientation changes. Old asynchronous callbacks cannot revive a stopped generation.
- **Run as an installable Mac app** with Start/Stop Service controls, IP, pairing, connection state,
  negotiated codec, resolution, FPS, bitrate, RTT, queues, drops, and staged P95 diagnostics.
- **Discover hosts on the LAN** from the HarmonyOS app, select a discovered Mac, and connect with
  one tap while retaining a manual-address fallback.

## How it works

```text
macOS virtual display
  → ScreenCaptureKit / IOSurface
  → VideoToolbox H.264 or HEVC
  → authenticated video transport
  → HarmonyOS AVCodec
  → XComponent native Surface

HarmonyOS touch and gestures
  → TLS 1.3 control channel
  → public macOS input-event APIs
```

Control and video use independent connections so video congestion cannot block input. The current
HarmonyOS API 21 runtime uses TLS/TCP for video. QUIC capability negotiation, fragmentation,
out-of-order reassembly, and loss recovery are implemented in the repository, but QUIC is enabled
only when both peers expose a usable runtime API.

## Current status and limitations

- macOS 14 or later; Apple Silicon is the primary validation platform.
- The HarmonyOS NEXT project currently targets 6.0.1 (API 21).
- The DMG UI manages one active receiver at a time. The lower layers already provide persistent
  device identity, orientation isolation, and process-wide serial collision detection.
- The receiver actively discovers services on the LAN. Guest Wi-Fi, AP isolation, or networks that
  block mDNS may prevent discovery; use the manual-address fallback in that case.
- 90/120 FPS remains an explicitly enabled experiment. Current native-resolution encoder P95 does
  not yet justify enabling it by default.
- Current GitHub Release DMGs use ad-hoc signing and are not Apple-notarized, so they do not pass
  the standard Gatekeeper trust assessment. macOS may also ask for Screen Recording and
  Accessibility permissions again after the binary changes. Download only from this repository
  and verify the checksums and artifact attestation.
- Clipboard, soft-keyboard, and shortcut channels are not implemented. The optional cursor side
  channel remains in the codebase, but the original captured Mac cursor is the default.

See [P6 implementation status](docs/P6_IMPLEMENTATION_STATUS.md) for capability and fallback details.

## Quick start

### 1. Start the macOS host

1. Build or install `Second Display.app`.
2. Allow **Screen Recording** in System Settings → Privacy & Security. Allow **Accessibility** only
   if touch control is required.
3. Open the app and confirm the displayed Mac IP and pairing certificate.
4. Click **Start Service**.

### 2. Connect the HarmonyOS device

1. Install a locally signed HAP with DevEco Studio or `hdc`.
2. Put the receiver and Mac on the same reachable network.
3. Open Second Display, select the Mac from the discovered-host list, and tap **Connect**. Use the
   manual-address entry if discovery is unavailable.
4. After connection, the overlay hides automatically and the device shows the extended desktop.

Stopping the service cancels capture, encode, transport, and recovery work and releases the virtual
display.

## Build and test

### macOS

Xcode, Swift 6.1, and a current macOS SDK are required:

```sh
swift build
swift test
python3 tools/validate_shared_vectors.py
```

Run the opt-in local hardware encoder comparison:

```sh
RUN_ENCODER_BENCHMARK=1 swift test -c release \
  --filter MediaPipelineTests/testHardwareEncoderLatencyBenchmarkWhenExplicitlyEnabled
```

Create and verify a local DMG:

```sh
tools/package_macos_dmg.sh
tools/verify_macos_distribution.sh
```

For a future Developer ID signed and notarized build:

```sh
MACOS_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
NOTARY_KEYCHAIN_PROFILE="second-display-notary" \
tools/package_macos_dmg.sh
```

### HarmonyOS

```sh
cd harmony
hvigorw assembleHap --mode module \
  -p product=default \
  -p module=entry@default \
  -p buildMode=debug \
  --no-daemon
```

Signing configuration is developer-local and must never be committed. See the
[HarmonyOS build guide](harmony/README.md) for additional commands.

### GitHub Release

Production releases are driven by `vMAJOR.MINOR.PATCH` tags. The workflow runs
quality gates, ad-hoc signing, DMG integrity checks, checksums, and artifact
attestation before publishing the macOS DMG; current artifacts do not claim a
Developer ID identity or Apple notarization. HarmonyOS currently receives a
compile-only verification; it is neither signed nor uploaded as a release
asset. See the [Tag-Driven Release process](docs/RELEASE_PROCESS.md) for the
optional HarmonyOS build runner and tagging instructions.

## Repository layout

| Path | Purpose |
|---|---|
| `macos/VirtualDisplayCore` | Private API Shim, identity, mode, and display arrangement |
| `macos/CapturePipeline` | ScreenCaptureKit, VideoToolbox, backpressure, and bitrate control |
| `macos/TransportCore` | TLS/QUIC abstractions, channels, heartbeat, and network adaptation |
| `macos/P3HostCore` | Service lifecycle, session recovery, input, and diagnostics |
| `macos/SecondDisplayMacApp` | SwiftUI host application packaged in the DMG |
| `harmony/entry` | ArkUI page, network worker, and native AVCodec decoder |
| `shared/` | Protocol documentation, JSON Schema, and cross-platform vectors |
| `tools/` | Packaging, certificate, compatibility, and validation tools |
| `docs/` | Technical design, coding tasks, and device-test notes |

## Security and privacy

- The control channel uses TLS 1.3, and video transport is also authenticated and encrypted.
- Pairing private keys and signing material stay on the developer machine and are excluded from
  both the app bundle and Git.
- Control messages, video frames, queues, and fragments all have hard bounds.
- Logs do not contain video frames, keyboard text, private keys, or full device identifiers.
- Failures use project error codes instead of terminating with `fatalError`.

## Further reading

- [Technical design](docs/CGVirtualDisplay_Technical_Design.md)
- [AI coding task list](docs/AI_CODING_TASKS.md)
- [Protocol v1](shared/protocol/PROTOCOL_V1.md)
- [P5 reliability and release](docs/P5_RELIABILITY_AND_RELEASE.md)
- [P6 implementation status](docs/P6_IMPLEMENTATION_STATUS.md)
