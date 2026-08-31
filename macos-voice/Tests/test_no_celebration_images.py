from pathlib import Path
import unittest


class CelebrationAssetPolicyTests(unittest.TestCase):
    def test_repository_has_no_raster_celebration_assets_or_downloaders(self):
        root = Path(__file__).resolve().parents[2]

        self.assertFalse((root / "macos-voice/Sources/CodexVoiceHotkey/Resources/celebration-packs").exists())
        self.assertFalse((root / "memes").exists())
