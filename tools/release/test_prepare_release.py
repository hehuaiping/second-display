import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).parent))

from prepare_release import parse_tag, prepare_metadata  # noqa: E402


class ReleaseMetadataTests(unittest.TestCase):
    def test_stable_tag(self) -> None:
        self.assertEqual(parse_tag("v1.2.3"), ("1.2.3", "1.2.3", False))

    def test_prerelease_tag(self) -> None:
        self.assertEqual(
            parse_tag("v2.0.0-beta.1"),
            ("2.0.0", "2.0.0-beta.1", True),
        )

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


if __name__ == "__main__":
    unittest.main()
