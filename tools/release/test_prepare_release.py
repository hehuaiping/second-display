import json
import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).parent))

from prepare_release import parse_tag, prepare_metadata  # noqa: E402


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class ReleaseMetadataTests(unittest.TestCase):
    def test_stable_tag(self) -> None:
        self.assertEqual(parse_tag("v1.2.3"), ("1.2.3", "1.2.3", False))

    def test_prerelease_tag(self) -> None:
        self.assertEqual(
            parse_tag("v2.0.0-beta.1"),
            ("2.0.0", "2.0.0-beta.1", True),
        )

    def test_uppercase_prefix_is_accepted(self) -> None:
        self.assertEqual(parse_tag("V1.2.3"), ("1.2.3", "1.2.3", False))

    def test_rejects_non_semantic_tag(self) -> None:
        with self.assertRaises(ValueError):
            parse_tag("release-1.2")

    def test_requires_harmony_version_to_match(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / "app.json5"
            profile.write_text(
                '{"app":{"versionCode":1002003,"versionName":"1.2.3"}}',
                encoding="utf-8",
            )
            metadata = prepare_metadata("v1.2.3", profile)
            self.assertEqual(metadata.harmony_version_code, 1002003)
            with self.assertRaises(ValueError):
                prepare_metadata("v1.2.4", profile)


class HarmonyCIBuildProfileTests(unittest.TestCase):
    def test_profile_is_valid_and_contains_no_signing_material(self) -> None:
        profile_path = REPOSITORY_ROOT / "harmony" / "build-profile.ci.json5"
        profile = json.loads(profile_path.read_text(encoding="utf-8"))
        forbidden_keys = {
            "signingconfig",
            "signingconfigs",
            "material",
            "certpath",
            "keyalias",
            "keypassword",
            "profile",
            "storefile",
            "storepassword",
        }

        def visit(value: object) -> None:
            if isinstance(value, dict):
                self.assertTrue(forbidden_keys.isdisjoint(key.lower() for key in value))
                for child in value.values():
                    visit(child)
            elif isinstance(value, list):
                for child in value:
                    visit(child)

        visit(profile)
        self.assertEqual(profile["app"]["products"][0]["name"], "default")
        self.assertEqual(profile["modules"][0]["name"], "entry")


if __name__ == "__main__":
    unittest.main()
