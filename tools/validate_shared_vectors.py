#!/usr/bin/env python3
import json
import hashlib
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
REQUIRED = {
    "control/client_hello_full.json": "clientHello",
    "control/client_hello_minimal.json": "clientHello",
    "control/server_ready.json": "serverReady",
    "control/error_minimal.json": "error",
    "control/input_scroll.json": "inputEvent",
    "control/gesture_swipe.json": "gestureEvent",
    "control/cursor_position.json": "cursorPosition",
    "control/request_key_frame.json": "requestKeyFrame",
    "control/heartbeat.json": "heartbeat",
    "control/heartbeat_ack.json": "heartbeatAck",
    "control/unknown.json": "futureMessage",
}


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    vector_root = ROOT / "shared" / "test-vectors"
    for relative_path, expected_type in REQUIRED.items():
        path = vector_root / relative_path
        if not path.is_file():
            fail(f"missing vector {relative_path}")
        payload = json.loads(path.read_text(encoding="utf-8"))
        if payload.get("type") != expected_type:
            fail(f"{relative_path} has unexpected type")

    frame_path = vector_root / "video" / "frame_golden.json"
    frame = json.loads(frame_path.read_text(encoding="utf-8"))
    encoded = bytes.fromhex(frame["encodedHex"])
    payload = bytes.fromhex(frame["payloadHex"])
    if len(encoded) != 32 + len(payload):
        fail("golden frame length does not match its payload")
    if encoded[:4] != b"SDS1" or encoded[4] != 1:
        fail("golden frame magic/version is invalid")
    if int.from_bytes(encoded[28:32], "big") != len(payload):
        fail("golden frame payloadLength is invalid")

    media_manifest_path = vector_root / "media" / "media_vectors.json"
    media_manifest = json.loads(media_manifest_path.read_text(encoding="utf-8"))
    expected_dimensions = {(1280, 800), (1920, 1200)}
    actual_dimensions = {(item["width"], item["height"]) for item in media_manifest}
    if actual_dimensions != expected_dimensions:
        fail("media manifest dimensions are incomplete")
    for item in media_manifest:
        if item["codec"] != "h264" or item["profile"] != "high" or item["fps"] != 60:
            fail(f"{item['path']} has unexpected codec metadata")
        media_path = media_manifest_path.parent / item["path"]
        bitstream = media_path.read_bytes()
        if len(bitstream) != item["bytes"] or len(bitstream) > 512 * 1024:
            fail(f"{item['path']} has an invalid or excessive size")
        if hashlib.sha256(bitstream).hexdigest() != item["sha256"]:
            fail(f"{item['path']} SHA-256 does not match the manifest")
        if not bitstream.startswith(b"\x00\x00\x00\x01"):
            fail(f"{item['path']} is not Annex B")

    schema = ROOT / "shared" / "schemas" / "control-message-v1.schema.json"
    json.loads(schema.read_text(encoding="utf-8"))
    print(f"Validated {len(REQUIRED) + 1} protocol vectors and {len(media_manifest)} media vectors")


if __name__ == "__main__":
    main()
