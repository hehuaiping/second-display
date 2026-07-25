#!/usr/bin/env python3
"""Validate a release tag and expose deterministic release metadata."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path


TAG_PATTERN = re.compile(
    r"^[vV](?P<major>0|[1-9]\d*)\."
    r"(?P<minor>0|[1-9]\d*)\."
    r"(?P<patch>0|[1-9]\d*)"
    r"(?:-(?P<prerelease>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
VERSION_NAME_PATTERN = re.compile(r'"versionName"\s*:\s*"([^"]+)"')
VERSION_CODE_PATTERN = re.compile(r'"versionCode"\s*:\s*(\d+)')


@dataclass(frozen=True)
class ReleaseMetadata:
    tag: str
    version: str
    release_label: str
    prerelease: bool
    harmony_version_code: int


def parse_tag(tag: str) -> tuple[str, str, bool]:
    match = TAG_PATTERN.fullmatch(tag)
    if match is None:
        raise ValueError(
            "release tag must use vMAJOR.MINOR.PATCH, "
            "VMAJOR.MINOR.PATCH, or their prerelease form"
        )
    version = ".".join(
        (match.group("major"), match.group("minor"), match.group("patch"))
    )
    prerelease = match.group("prerelease")
    release_label = version if prerelease is None else f"{version}-{prerelease}"
    return version, release_label, prerelease is not None


def read_harmony_version(app_profile: Path) -> tuple[str, int]:
    content = app_profile.read_text(encoding="utf-8")
    version_name_match = VERSION_NAME_PATTERN.search(content)
    version_code_match = VERSION_CODE_PATTERN.search(content)
    if version_name_match is None or version_code_match is None:
        raise ValueError(f"unable to read HarmonyOS version from {app_profile}")
    version_code = int(version_code_match.group(1))
    if version_code <= 0:
        raise ValueError("HarmonyOS versionCode must be positive")
    return version_name_match.group(1), version_code


def prepare_metadata(tag: str, app_profile: Path) -> ReleaseMetadata:
    version, release_label, prerelease = parse_tag(tag)
    harmony_version, harmony_version_code = read_harmony_version(app_profile)
    if harmony_version != version:
        raise ValueError(
            f"tag version {version} does not match HarmonyOS versionName "
            f"{harmony_version}"
        )
    return ReleaseMetadata(
        tag=tag,
        version=version,
        release_label=release_label,
        prerelease=prerelease,
        harmony_version_code=harmony_version_code,
    )


def write_github_output(path: Path, metadata: ReleaseMetadata) -> None:
    values = {
        "tag": metadata.tag,
        "version": metadata.version,
        "release_label": metadata.release_label,
        "prerelease": str(metadata.prerelease).lower(),
        "harmony_version_code": str(metadata.harmony_version_code),
    }
    with path.open("a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument(
        "--app-profile",
        type=Path,
        default=Path("harmony/AppScope/app.json5"),
    )
    parser.add_argument("--github-output", type=Path)
    arguments = parser.parse_args()

    metadata = prepare_metadata(arguments.tag, arguments.app_profile)
    if arguments.github_output is not None:
        write_github_output(arguments.github_output, metadata)
    print(
        f"Validated {metadata.tag}: version={metadata.version}, "
        f"prerelease={str(metadata.prerelease).lower()}, "
        f"HarmonyOS versionCode={metadata.harmony_version_code}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
