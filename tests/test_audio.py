import unittest
from pathlib import Path
from unittest.mock import patch

from app.audio import normalize_for_transcription


class AudioNormalizationTests(unittest.TestCase):
    @patch("app.audio.subprocess.run")
    def test_converts_browser_webm_to_wav_before_transcription(self, run):
        def write_wav(command, **kwargs):
            Path(command[-1]).write_bytes(b"wav-data")

        run.side_effect = write_wav
        filename, data, content_type = normalize_for_transcription("speech.webm", b"webm-data", "audio/webm")

        self.assertEqual((filename, data, content_type), ("speech.wav", b"wav-data", "audio/wav"))
        self.assertIn("ffmpeg", run.call_args.args[0][0])

    @patch("app.audio.subprocess.run")
    def test_keeps_wav_without_conversion(self, run):
        self.assertEqual(
            normalize_for_transcription("speech.wav", b"wav-data", "audio/wav"),
            ("speech.wav", b"wav-data", "audio/wav"),
        )
        run.assert_not_called()
