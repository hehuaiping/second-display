# P6 implementation status

This note records the P6 overlap audit and the runtime gates that prevent an experimental capability
from silently replacing a stable path. T607 and T608 are intentionally out of scope.

| Task | Existing overlap before P6 | P6 implementation |
|---|---|---|
| T601 | Reliable TLS control/video channels and bounded latest-frame queue | Adds authenticated QUIC datagram parameters, bounded fragmentation/reassembly, timeout/drop/IDR policy, generation cancellation, and transport negotiation. TLS/TCP remains the negotiated runtime fallback because the installed HarmonyOS SDK does not provide the v26 Remote Communication QUIC headers. |
| T602 | `dirtyRects` activity classification, dynamic static-content bitrate, RTT and sender queue metrics | Adds receiver queue/drop/render-FPS feedback, a hysteretic RTT/queue/drop controller, live bitrate ceilings, and safe generation rebuilds at 1.0/0.8/0.667 resolution scales. |
| T603 | Ten-second display-preserving reconnect and interface-independent IP transport | Adds macOS and HarmonyOS Wi-Fi/wired-or-USB/cellular detection. A usable interface change triggers a fast authenticated re-handshake while retaining the display. Native QUIC path migration remains gated with T601. |
| T604 | Orientation identity bit and saved arrangement isolation | Adds actual receiver orientation/resolution advertisement, portrait dimension validation, rotation detection, and safe old-generation cancellation/rebuild. The app starts in landscape but permits sensor-driven landscape/portrait switching. |
| T605 | Hardware H.264 VideoToolbox/AVCodec surface path | Adds HEVC capability negotiation, hardware-only macOS encode selection, HVCC-to-Annex-B VPS/SPS/PPS conversion, HarmonyOS hardware capability probing, and direct-surface HEVC decode. H.264 is retained as the compatibility fallback. |
| T606 | Deterministic serial generation and provider-local collision detection | Adds a process-wide collision registry, persistent receiver UUID, per-device/orientation identity, and tests for simultaneous providers and serial reuse after release. The current DMG UI still exposes one active receiver session at a time. |

## Compatibility and safety gates

- A peer that omits new capability fields decodes as H.264 over TLS/TCP.
- HEVC is selected only when both peers advertise it and the Mac reports a hardware encoder.
- QUIC is selected only when both peers advertise it; the current HarmonyOS build advertises TLS/TCP.
- Rotation, network migration, stream rebuild, stop, and reconnect all advance or check a generation.
- Datagram frames, fragment counts, pending frames, receiver feedback, and control payloads are bounded.
- Failures map to existing project error codes; no `fatalError` or forced unwrap is used.
