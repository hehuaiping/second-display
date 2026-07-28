#!/usr/bin/env python3
"""分析 P3PoCHost 与 HarmonyOS RenderService 的真机证据。"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


HOST_PATTERN = re.compile(
    r"Streaming (?P<width>\d+)×(?P<height>\d+) \S+ at (?P<target>\d+) fps"
    r" · drops C/E/S (?P<capture_drop>\d+)/(?P<encode_drop>\d+)/(?P<send_drop>\d+)"
    r" · p95 cap (?P<capture_p95>[\d.]+) q (?P<queue_p95>[\d.]+)"
    r" VT (?P<vt_p95>[\d.]+) pack (?P<pack_p95>[\d.]+)"
    r" enc (?P<encode_p95>[\d.]+) send (?P<send_p95>[\d.]+) ms"
    r" · src (?P<source_fps>[\d.]+)/cap (?P<capture_fps>[\d.]+)/enc (?P<encode_fps>[\d.]+)"
    r" · recv (?P<receive_fps>[\d.]+)/display (?P<display_fps>[\d.]+) fps"
    r" decodeP95 (?P<decode_p95>[\d.]+) ms"
)
ENCODED_PATTERN = re.compile(r"\bencoded=(\d+)\b")
RS_PATTERN = re.compile(r"^\s*(\d+):(\d+)\s*$")


@dataclass(frozen=True)
class HostSample:
    width: int
    height: int
    target: int
    capture_drop: int
    encode_drop: int
    send_drop: int
    capture_p95: float
    queue_p95: float
    vt_p95: float
    pack_p95: float
    encode_p95: float
    send_p95: float
    source_fps: float
    capture_fps: float
    encode_fps: float
    receive_fps: float
    display_fps: float
    decode_p95: float
    encoded_frames: int


def percentile(values: Iterable[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("计算百分位数至少需要一个样本")
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def parse_host_log(text: str) -> list[HostSample]:
    samples: list[HostSample] = []
    for line in text.splitlines():
        match = HOST_PATTERN.search(line)
        if not match:
            continue
        encoded_match = ENCODED_PATTERN.search(line)
        values = match.groupdict()
        samples.append(
            HostSample(
                width=int(values["width"]),
                height=int(values["height"]),
                target=int(values["target"]),
                capture_drop=int(values["capture_drop"]),
                encode_drop=int(values["encode_drop"]),
                send_drop=int(values["send_drop"]),
                capture_p95=float(values["capture_p95"]),
                queue_p95=float(values["queue_p95"]),
                vt_p95=float(values["vt_p95"]),
                pack_p95=float(values["pack_p95"]),
                encode_p95=float(values["encode_p95"]),
                send_p95=float(values["send_p95"]),
                source_fps=float(values["source_fps"]),
                capture_fps=float(values["capture_fps"]),
                encode_fps=float(values["encode_fps"]),
                receive_fps=float(values["receive_fps"]),
                display_fps=float(values["display_fps"]),
                decode_p95=float(values["decode_p95"]),
                encoded_frames=int(encoded_match.group(1)) if encoded_match else 0,
            )
        )
    return samples


def parse_render_service(text: str, record_limit: int = 180) -> dict[str, float | int]:
    records = sorted(
        {(int(match.group(1)), int(match.group(2))) for line in text.splitlines()
         if (match := RS_PATTERN.match(line))},
        key=lambda pair: pair[0],
    )
    records = records[-record_limit:]
    intervals = [
        (current[0] - previous[0]) / 1_000_000
        for previous, current in zip(records, records[1:])
        if 0 < current[0] - previous[0] < 1_000_000_000
    ]
    pair_deltas = [(second - first) / 1_000_000 for first, second in records if second >= first]
    if len(intervals) < 2:
        raise ValueError("RenderService 证据中可用记录少于三条")
    elapsed_seconds = (records[-1][0] - records[0][0]) / 1_000_000_000
    frames_per_second = (len(records) - 1) / elapsed_seconds if elapsed_seconds > 0 else 0
    return {
        "record_count": len(records),
        "frames_per_second": frames_per_second,
        "interval_p50_ms": percentile(intervals, 0.50),
        "interval_p95_ms": percentile(intervals, 0.95),
        "interval_p99_ms": percentile(intervals, 0.99),
        "pair_delta_p95_ms": percentile(pair_deltas, 0.95) if pair_deltas else 0,
    }


def validate_connection_metadata(text: str) -> dict[str, int]:
    values = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    required = {
        "connection_ready": 1,
        "measurement_completed": 1,
    }
    for key, expected in required.items():
        if values.get(key) != str(expected):
            raise ValueError(f"连接前置门禁未完成：{key}={values.get(key, 'missing')}")
    try:
        duration = int(values["duration_seconds"])
        measured = int(values["connected_measurement_seconds"])
    except (KeyError, ValueError) as error:
        raise ValueError("连接后采样时长元数据缺失或无效") from error
    if measured < duration:
        raise ValueError(f"真实连接后只采样 {measured} 秒，要求至少 {duration} 秒")
    return {
        "connection_ready": 1,
        "connection_wait_seconds": int(values.get("connection_wait_seconds", "0")),
        "connected_measurement_seconds": measured,
        "ui_automation_enabled": int(values.get("ui_automation_enabled", "0")),
        "ui_connect_click_count": int(values.get("ui_connect_click_count", "0")),
        "ui_scan_clicked": int(values.get("ui_scan_clicked", "0")),
    }


def analyze(host_text: str, render_service_text: str) -> dict[str, object]:
    all_host_samples = parse_host_log(host_text)
    if len(all_host_samples) < 5:
        raise ValueError("主机指标样本少于五个；请连接设备并至少运行 70 秒")
    stable = all_host_samples[2:]
    render = parse_render_service(render_service_text)
    final = stable[-1]
    total_drops = final.capture_drop + final.encode_drop + final.send_drop
    denominator = max(1, final.encoded_frames + total_drops)
    drop_rate = total_drops / denominator

    measurements = {
        "host_sample_count": len(all_host_samples),
        "stable_sample_count": len(stable),
        "width": final.width,
        "height": final.height,
        "target_fps": final.target,
        "source_fps_median": statistics.median(item.source_fps for item in stable),
        "capture_fps_median": statistics.median(item.capture_fps for item in stable),
        "encode_fps_median": statistics.median(item.encode_fps for item in stable),
        "receive_fps_median": statistics.median(item.receive_fps for item in stable),
        "display_callback_fps_median": statistics.median(item.display_fps for item in stable),
        "vt_p95_max_ms": max(item.vt_p95 for item in stable),
        "encode_p95_max_ms": max(item.encode_p95 for item in stable),
        "decode_output_p95_max_ms": max(item.decode_p95 for item in stable),
        "send_p95_max_ms": max(item.send_p95 for item in stable),
        "capture_drops": final.capture_drop,
        "encode_drops": final.encode_drop,
        "send_drops": final.send_drop,
        "encoded_frames": final.encoded_frames,
        "total_drop_rate": drop_rate,
        **{f"render_service_{key}": value for key, value in render.items()},
    }
    checks = [
        ("RenderService 实际 FPS", measurements["render_service_frames_per_second"], ">=", 58.5),
        ("RenderService 帧间隔 P95（ms）", measurements["render_service_interval_p95_ms"], "<=", 25.0),
        ("RenderService 帧间隔 P99（ms）", measurements["render_service_interval_p99_ms"], "<=", 33.3),
        ("源画面 FPS 中位数", measurements["source_fps_median"], ">=", 58.0),
        ("采集 FPS 中位数", measurements["capture_fps_median"], ">=", 57.0),
        ("编码 FPS 中位数", measurements["encode_fps_median"], ">=", 57.0),
        ("接收有效呈现 FPS 中位数", measurements["receive_fps_median"], ">=", 58.5),
        ("显示回调 FPS 中位数", measurements["display_callback_fps_median"], ">=", 58.5),
        ("VideoToolbox P95 最大值（ms）", measurements["vt_p95_max_ms"], "<=", 9.5),
        ("解码输出 P95 最大值（ms）", measurements["decode_output_p95_max_ms"], "<=", 25.0),
        ("发送 P95 最大值（ms）", measurements["send_p95_max_ms"], "<=", 1.0),
        ("主机总丢帧率", measurements["total_drop_rate"], "<", 0.005),
        ("发送丢帧数", float(measurements["send_drops"]), "==", 0.0),
    ]
    evaluated_checks = []
    for name, actual, operator, threshold in checks:
        if operator == ">=":
            passed = actual >= threshold
        elif operator == "<=":
            passed = actual <= threshold
        elif operator == "<":
            passed = actual < threshold
        else:
            passed = actual == threshold
        evaluated_checks.append(
            {
                "name": name,
                "actual": actual,
                "operator": operator,
                "threshold": threshold,
                "passed": passed,
            }
        )
    return {
        "status": "PASS" if all(item["passed"] for item in evaluated_checks) else "FAIL",
        "measurements": measurements,
        "checks": evaluated_checks,
        "native_like_target_gaps": {
            "video_toolbox_p95_target_ms": 8.0,
            "video_toolbox_target_met": measurements["vt_p95_max_ms"] <= 8.0,
            "click_to_photon_p95_target_ms": 60.0,
            "click_to_photon_measured": False,
        },
        "stable_host_samples": [asdict(item) for item in stable],
    }


def render_summary(result: dict[str, object]) -> str:
    measurements = result["measurements"]
    checks = result["checks"]
    assert isinstance(measurements, dict)
    assert isinstance(checks, list)
    lines = [
        "# Second Display 真机指标摘要",
        "",
        f"自动判定：**{result['status']}**",
        "",
        "| 检查 | 实测 | 门槛 | 结果 |",
        "|---|---:|---:|---|",
    ]
    for item in checks:
        actual = item["actual"]
        formatted = f"{actual:.4f}" if isinstance(actual, float) else str(actual)
        lines.append(
            f"| {item['name']} | {formatted} | {item['operator']} {item['threshold']} | "
            f"{'PASS' if item['passed'] else 'FAIL'} |"
        )
    lines.extend(
        [
            "",
            "## 关键上下文",
            "",
            f"- 分辨率：{measurements['width']}×{measurements['height']}",
            f"- 目标帧率：{measurements['target_fps']} FPS",
            f"- 稳态主机样本：{measurements['stable_sample_count']}",
            f"- 编码帧：{measurements['encoded_frames']}",
            f"- RenderService 样本：{measurements['render_service_record_count']}",
            f"- RenderService pair delta P95："
            f"{measurements['render_service_pair_delta_p95_ms']:.2f} ms（仅诊断，不等同 click-to-photon）",
        ]
    )
    validation_context = result.get("validation_context")
    if isinstance(validation_context, dict):
        lines.extend(
            [
                f"- 真实流连接：{'已确认' if validation_context['connection_ready'] == 1 else '未确认'}",
                f"- 连接等待：{validation_context['connection_wait_seconds']} 秒",
                f"- 连接后有效采样：{validation_context['connected_measurement_seconds']} 秒",
                f"- 界面自动化：{'开启' if validation_context['ui_automation_enabled'] == 1 else '关闭'}",
                f"- 自动连接点击：{validation_context['ui_connect_click_count']} 次",
            ]
        )
    lines.extend(
        [
            "",
            "## 尚不能由本脚本证明",
            "",
            "- click-to-photon P95 需要高速摄像机或专用 probe。",
            "- 交互、手势、旋转和恢复必须完成同目录 `operator-checklist.md`。",
            "- VideoToolbox 接近原生目标为 ≤8 ms；非回归硬门槛为 ≤9.5 ms。",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-log", type=Path, required=True)
    parser.add_argument("--render-service", type=Path, required=True)
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--json-output", type=Path, required=True)
    parser.add_argument("--summary-output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        validation_context = (
            validate_connection_metadata(
                arguments.metadata.read_text(encoding="utf-8", errors="replace")
            )
            if arguments.metadata is not None
            else None
        )
        result = analyze(
            arguments.host_log.read_text(encoding="utf-8", errors="replace"),
            arguments.render_service.read_text(encoding="utf-8", errors="replace"),
        )
        if validation_context is not None:
            result["validation_context"] = validation_context
    except (OSError, ValueError) as error:
        result = {"status": "INCOMPLETE", "error": str(error)}
        arguments.json_output.write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        arguments.summary_output.write_text(
            "# Second Display 真机指标摘要\n\n"
            f"自动判定：**INCOMPLETE**\n\n原因：{error}\n",
            encoding="utf-8",
        )
        print(f"DEVICE_VALIDATION_INCOMPLETE: {error}")
        return 2
    arguments.json_output.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    arguments.summary_output.write_text(render_summary(result), encoding="utf-8")
    print(f"真机指标门禁：{result['status']}")
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
