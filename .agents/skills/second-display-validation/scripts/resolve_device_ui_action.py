#!/usr/bin/env python3
"""从 HarmonyOS uitest 布局树中选择安全的下一步验证操作。"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator


BOUNDS_PATTERN = re.compile(r"^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$")


@dataclass(frozen=True)
class UiNode:
    text: str
    bounds: tuple[int, int, int, int]
    clickable: bool
    enabled: bool
    visible: bool

    @property
    def center(self) -> tuple[int, int]:
        left, top, right, bottom = self.bounds
        return ((left + right) // 2, (top + bottom) // 2)


@dataclass(frozen=True)
class UiDecision:
    action: str
    x: int = 0
    y: int = 0

    def render(self) -> str:
        return f"{self.action} {self.x} {self.y}"


def _attribute_is_true(value: object, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized == "true":
            return True
        if normalized == "false":
            return False
    return default


def _parse_bounds(value: object) -> tuple[int, int, int, int]:
    if not isinstance(value, str):
        return (0, 0, 0, 0)
    match = BOUNDS_PATTERN.match(value)
    if match is None:
        return (0, 0, 0, 0)
    return tuple(int(item) for item in match.groups())  # type: ignore[return-value]


def walk_nodes(value: object) -> Iterator[UiNode]:
    if not isinstance(value, dict):
        return
    attributes = value.get("attributes")
    if isinstance(attributes, dict):
        original_text = attributes.get("originalText")
        text = original_text if isinstance(original_text, str) and original_text else attributes.get("text", "")
        yield UiNode(
            text=text if isinstance(text, str) else "",
            bounds=_parse_bounds(attributes.get("bounds")),
            clickable=_attribute_is_true(attributes.get("clickable"), False),
            enabled=_attribute_is_true(attributes.get("enabled"), True),
            visible=_attribute_is_true(attributes.get("visible"), True),
        )
    children = value.get("children")
    if isinstance(children, list):
        for child in children:
            yield from walk_nodes(child)


def _click_decision(action: str, node: UiNode) -> UiDecision:
    x, y = node.center
    if x <= 0 or y <= 0:
        return UiDecision("WAIT")
    return UiDecision(action, x, y)


def resolve_action(layout: object) -> UiDecision:
    nodes = list(walk_nodes(layout))
    actionable = [
        node for node in nodes
        if node.clickable and node.enabled and node.visible
    ]

    # 首次安装可能出现隐私说明。验证设备可以接受应用自身提示，但不自动建立新的信任关系。
    privacy = next((node for node in actionable if node.text == "同意并继续"), None)
    if privacy is not None:
        return _click_decision("ACCEPT_PRIVACY", privacy)

    # 只点击服务卡片的精确“连接”文本，避免误触“连接 IP”或处于连接中的禁用按钮。
    connect = next((node for node in actionable if node.text == "连接"), None)
    if connect is not None:
        return _click_decision("CONNECT", connect)

    if any(node.text == "连接中…" or "正在连接 Mac" in node.text for node in nodes):
        return UiDecision("CONNECTING")

    scan = next((node for node in actionable if node.text == "重新扫描"), None)
    if scan is not None:
        return _click_decision("SCAN", scan)

    if any(node.text == "配对" for node in actionable):
        return UiDecision("PAIRING_REQUIRED")

    return UiDecision("WAIT")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--layout", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        layout = json.loads(arguments.layout.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"INVALID_LAYOUT 0 0")
        print(f"无法读取布局树：{error}", file=sys.stderr)
        return 2
    print(resolve_action(layout).render())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
