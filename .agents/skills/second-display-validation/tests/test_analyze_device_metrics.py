import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = (
    Path(__file__).parents[1] / "scripts" / "analyze_device_metrics.py"
)
SPEC = importlib.util.spec_from_file_location("analyze_device_metrics", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def host_line(index: int, *, display_fps: float = 60.0, vt_p95: float = 8.8) -> str:
    encoded = (index + 1) * 600
    return (
        "P3 PoC streaming: Streaming 2720×1260 H264 at 60 fps"
        f" · drops C/E/S 4/2/0"
        f" · p95 cap 3.0 q 0.2 VT {vt_p95:.1f} pack 0.1 enc 9.0 send 0.0 ms"
        " · src 60.0/cap 59.8/enc 59.7"
        f" · recv 59.4/display {display_fps:.1f} fps decodeP95 20.0 ms"
        f" · dirty 100.0% active 12.0 Mbps · HW LL on · net wifi encoded={encoded}"
    )


def render_service_records(frame_count: int = 180, interval_ns: int = 16_666_667) -> str:
    base = 10_000_000_000
    records = [
        f"{base + index * interval_ns}:{base + index * interval_ns + 8_000_000}"
        for index in range(frame_count)
    ]
    return "\n".join(reversed(records))


class DeviceMetricAnalyzerTests(unittest.TestCase):
    def test_verified_sixty_fps_sample_passes(self) -> None:
        result = MODULE.analyze(
            "\n".join(host_line(index) for index in range(8)),
            render_service_records(),
        )
        self.assertEqual(result["status"], "PASS")
        self.assertGreaterEqual(
            result["measurements"]["render_service_frames_per_second"], 58.5
        )

    def test_tail_interval_regression_fails(self) -> None:
        current = 10_000_000_000
        ordered = []
        for index in range(180):
            if index > 0:
                current += 50_000_000 if index >= 176 else 16_666_667
            ordered.append(f"{current}:{current + 8_000_000}")
        result = MODULE.analyze(
            "\n".join(host_line(index) for index in range(8)),
            "\n".join(reversed(ordered)),
        )
        failed_names = {
            item["name"] for item in result["checks"] if not item["passed"]
        }
        self.assertEqual(result["status"], "FAIL")
        self.assertIn("RenderService 帧间隔 P99（ms）", failed_names)

    def test_insufficient_host_samples_is_incomplete_input(self) -> None:
        with self.assertRaisesRegex(ValueError, "少于五个"):
            MODULE.analyze(
                "\n".join(host_line(index) for index in range(4)),
                render_service_records(),
            )


if __name__ == "__main__":
    unittest.main()
