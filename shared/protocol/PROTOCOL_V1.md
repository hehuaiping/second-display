# Second Display Protocol v1

Protocol v1 always uses an authenticated reliable control connection. Legacy peers use a second
authenticated TCP video connection; peers that mutually advertise `quicDatagram` may use an
authenticated QUIC datagram video channel. Control messages are UTF-8 JSON
prefixed by a network-order `uint32` byte length (maximum 64 KiB). Video frames use the fixed
network-order header below. Receivers ignore unknown control `type` values.

## Control messages

- `clientHello`: receiver capabilities and stable device identity.
- `serverReady`: selected display, H.264/HEVC codec, and video transport configuration.
- `error`: stable project error code with optional user-safe detail.
- `inputEvent`: session-scoped, sequenced pointer or scroll input in logical normalized coordinates.
- `gestureEvent`: session-scoped 3–5 finger swipe or pinch recognized by the receiver. Swipe
  directions are `up/down/left/right`; pinch directions are `in/out`. Unknown implementations can
  safely ignore this additive message type.
- `requestKeyFrame`: session-scoped request for a new IDR.
- `heartbeat` / `heartbeatAck`: session-scoped liveness and RTT sampling.
- `receiverFeedback`: receiver decoder queue, cumulative drops, render FPS, and current network type.

The normative shape is `shared/schemas/control-message-v1.schema.json`. Defaults omitted on the wire:

| Message | Field | Default |
|---|---|---|
| `clientHello` | `deviceName` | `Unknown Device` |
| `clientHello` | `deviceScale` | `2.0` |
| `clientHello` | `maxFps` | `60` |
| `clientHello` | `codecs` | `["h264"]` |
| `clientHello` | `maxDecodeWidth/Height` | native width/height |
| `clientHello` | `orientation` | `landscape` |
| `clientHello` | `features` | `[]` |
| `clientHello` | `videoTransports` | `["tlsTcp"]` |
| `serverReady.stream` | `transport` | `tlsTcp` |
| `error` | `protocolVersion` | `1` |
| `error` | `message` | empty string |
| `error` | `generation` | `0` |
| `inputEvent` | `protocolVersion` | `1` |
| `inputEvent` | `deltaX/deltaY` | `0` |
| `requestKeyFrame` | `protocolVersion` | `1` |
| `requestKeyFrame` | `reason` | `decoderRecovery` |

`clientHello.maxFps` advertises the lower of the receiver display refresh capability and every
advertised hardware-decoder capability. Implementations normalize negotiation to 60, 90, or 120 fps. The host
selects the highest standard rate no greater than both the receiver capability and the configured
host preference; 60 fps remains the stable default, while 90/120 fps require explicit opt-in.

### macOS gesture mapping

The receiver uses ArkUI's exact-finger-count `SwipeGesture` and `PinchGesture` recognizers. The host
maps the resulting gesture to the closest public keyboard or application action exposed by macOS:

| Fingers | Gesture | macOS action |
|---:|---|---|
| 3–5 | swipe up | Mission Control (`Control-Up`) |
| 3–5 | swipe down | App Exposé (`Control-Down`) |
| 3–5 | swipe left/right | previous/next Space (`Control-Left/Right`) |
| 3 | pinch in/out | application zoom out/in (`Command-Minus/Equal`) |
| 4–5 | pinch in | Apps/Launchpad |
| 4–5 | pinch out | Show Desktop (`Fn-F11`) |

macOS allows three- or four-finger system navigation depending on Trackpad settings. Five-finger
swipes deliberately use the same navigation actions because macOS defines no separate five-finger
swipe behavior. The four- and five-finger pinch mapping follows Apple's Apps/Launchpad and Show
Desktop gestures.

## Video frame header

The 32-byte header is followed immediately by the negotiated Annex B H.264 or HEVC payload.

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | ASCII `SDS1` |
| 4 | 1 | version (`1`) |
| 5 | 1 | frame type (`1` video, `2` codec config) |
| 6 | 2 | flags (bit 0 keyframe, bit 1 discontinuity) |
| 8 | 4 | sequence |
| 12 | 8 | PTS in monotonic microseconds |
| 20 | 8 | capture time in monotonic microseconds |
| 28 | 4 | payload byte length (maximum 16 MiB) |

Malformed magic, versions, types, lengths, truncation, and trailing bytes map to
`NET_PROTOCOL_MISMATCH`.

## QUIC datagram fragment header

The QUIC video transport fragments an encoded 32-byte-header-plus-payload frame into datagrams no
larger than the negotiated path limit (1200 bytes by default). Each datagram starts with a bounded
20-byte header:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | ASCII `SDQ1` |
| 4 | 1 | fragment version (`1`) |
| 5 | 3 | reserved |
| 8 | 4 | frame sequence |
| 12 | 2 | fragment index |
| 14 | 2 | fragment count |
| 16 | 4 | total framed byte length |

The receiver keeps at most four incomplete frames for 100 ms, accepts out-of-order fragments, drops
expired frames, and requests a new keyframe after a loss. Old-generation fragments are ignored.
