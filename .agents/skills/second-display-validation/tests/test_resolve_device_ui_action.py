from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = (
    Path(__file__).parents[1] / "scripts" / "resolve_device_ui_action.py"
)
SPEC = importlib.util.spec_from_file_location("resolve_device_ui_action", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def node(
    text: str = "",
    *,
    bounds: str = "[100,200][300,400]",
    clickable: bool = True,
    enabled: bool = True,
    children: list[dict] | None = None,
) -> dict:
    return {
        "attributes": {
            "originalText": text,
            "text": text,
            "bounds": bounds,
            "clickable": str(clickable).lower(),
            "enabled": str(enabled).lower(),
            "visible": "true",
        },
        "children": children or [],
    }


class ResolveDeviceUiActionTests(unittest.TestCase):
    def test_privacy_prompt_has_priority(self) -> None:
        layout = node(
            clickable=False,
            children=[
                node("连接", bounds="[1000,700][1200,800]"),
                node("同意并继续", bounds="[300,500][700,620]"),
            ],
        )
        decision = MODULE.resolve_action(layout)
        self.assertEqual(decision.action, "ACCEPT_PRIVACY")
        self.assertEqual((decision.x, decision.y), (500, 560))

    def test_exact_connect_avoids_manual_ip_button(self) -> None:
        layout = node(
            clickable=False,
            children=[
                node("连接 IP", bounds="[50,800][350,900]"),
                node("连接", bounds="[1800,700][2200,850]"),
            ],
        )
        decision = MODULE.resolve_action(layout)
        self.assertEqual(decision.action, "CONNECT")
        self.assertEqual((decision.x, decision.y), (2000, 775))

    def test_disabled_connect_waits_for_pending_attempt(self) -> None:
        layout = node(
            clickable=False,
            children=[
                node("连接中…", enabled=False),
                node("正在连接 Mac…", clickable=False),
                node("重新扫描"),
            ],
        )
        self.assertEqual(MODULE.resolve_action(layout).action, "CONNECTING")

    def test_unpaired_service_is_not_automatically_trusted(self) -> None:
        layout = node(
            clickable=False,
            children=[node("配对"), node("连接 IP")],
        )
        self.assertEqual(MODULE.resolve_action(layout).action, "PAIRING_REQUIRED")

    def test_scan_is_selected_when_no_service_is_available(self) -> None:
        layout = node(
            clickable=False,
            children=[node("重新扫描", bounds="[500,100][900,220]")],
        )
        decision = MODULE.resolve_action(layout)
        self.assertEqual(decision.action, "SCAN")
        self.assertEqual((decision.x, decision.y), (700, 160))


if __name__ == "__main__":
    unittest.main()
