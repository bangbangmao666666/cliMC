import unittest

from app.siliconflow import SiliconFlowTranscriber


class SiliconFlowTests(unittest.TestCase):
    def test_transcriber_requires_an_api_key(self):
        with self.assertRaisesRegex(ValueError, "SILICONFLOW_API_KEY"):
            SiliconFlowTranscriber(api_key="")
