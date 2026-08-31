import json
import threading
import unittest
import urllib.request

from app.server import create_server


class FakeController:
    def preview(self, text): return {"kind": "compact", "text": text, "objective": None}
    def execute(self, text): return {"kind": "prompt", "text": text, "objective": None}
    def pending_approvals(self): return []
    def resolve_approval(self, request_id, decision): return None


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.server = create_server("127.0.0.1", 0, FakeController(), transcriber=None)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_serves_hold_to_talk_ui(self):
        with urllib.request.urlopen(self.base_url + "/") as response:
            page = response.read().decode()

        self.assertIn("按住说话", page)
        self.assertIn("MediaRecorder", page)
        self.assertIn("pickRecordingMimeType", page)
        self.assertIn("录音过短", page)

    def test_previews_text_without_executing_it(self):
        request = urllib.request.Request(
            self.base_url + "/api/preview",
            data=json.dumps({"text": "压缩一下上下文"}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request) as response:
            payload = json.loads(response.read())

        self.assertEqual(payload["kind"], "compact")
