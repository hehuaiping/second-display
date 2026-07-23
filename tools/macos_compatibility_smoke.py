#!/usr/bin/env python3

import json
import os
import platform
import subprocess
import sys
import time
from pathlib import Path


def run_stage(name: str, command: list[str], environment: dict[str, str]) -> dict[str, object]:
    started = time.monotonic()
    process = subprocess.run(
        command,
        cwd=Path(__file__).resolve().parent.parent,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    return {
        "name": name,
        "result": "passed" if process.returncode == 0 else "failed",
        "durationMilliseconds": round((time.monotonic() - started) * 1000, 1),
        "exitCode": process.returncode,
        "outputTail": process.stdout[-4000:],
    }


def command_output(*command: str) -> str:
    try:
        return subprocess.check_output(command, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def main() -> int:
    environment = os.environ.copy()
    private_smoke = environment.get("RUN_PRIVATE_DISPLAY_SMOKE") == "1"
    stages = [
        run_stage(
            "capability",
            ["swift", "test", "--filter", "VirtualDisplayCapabilityTests"],
            environment,
        )
    ]
    if private_smoke:
        integration_environment = environment.copy()
        integration_environment["RUN_VIRTUAL_DISPLAY_INTEGRATION"] = "1"
        integration_environment["RUN_CAPTURE_INTEGRATION"] = "1"
        stages.append(
            run_stage(
                "create-enumerate-destroy",
                [
                    "swift",
                    "test",
                    "--filter",
                    "VirtualDisplayProviderTests.testRealDisplayCreateDestroyWhenExplicitlyEnabled",
                ],
                integration_environment,
            )
        )
        stages.append(
            run_stage(
                "capture-encode",
                [
                    "swift",
                    "test",
                    "--filter",
                    "MediaPipelineTests.testRealVirtualDisplayCaptureProducesNV12Frame",
                ],
                integration_environment,
            )
        )
    else:
        stages.append(
            {
                "name": "create-enumerate-capture-destroy",
                "result": "not_run",
                "durationMilliseconds": 0,
                "exitCode": None,
                "outputTail": "Set RUN_PRIVATE_DISPLAY_SMOKE=1 on a Screen Recording-authorized Mac runner",
            }
        )

    failed = any(stage["result"] == "failed" for stage in stages)
    fully_verified = private_smoke and all(stage["result"] == "passed" for stage in stages)
    candidate_status = "blocked" if failed else "supported" if fully_verified else "experimental"
    build = command_output("sw_vers", "-buildVersion")
    report = {
        "schemaVersion": 1,
        "osVersion": command_output("sw_vers", "-productVersion"),
        "osBuild": build,
        "chip": platform.machine(),
        "stages": stages,
        "suggestedManifestEntry": {
            "osBuild": build,
            "status": candidate_status,
            "reason": "Automated compatibility smoke result; review before merging",
        },
    }
    output_directory = Path(environment.get("COMPATIBILITY_OUTPUT_DIR", ".build/compatibility"))
    output_directory.mkdir(parents=True, exist_ok=True)
    output_path = output_directory / f"macos-{build}.json"
    output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(output_path)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
