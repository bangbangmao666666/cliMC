import unittest

from app.codex_bridge import CodexBridge


class FakeTransport:
    def __init__(self):
        self.calls = []

    def request(self, method, params):
        self.calls.append((method, params))
        if method == "thread/start":
            return {"thread": {"id": "thread-123"}}
        return {}


class CodexBridgeTests(unittest.TestCase):
    def setUp(self):
        self.transport = FakeTransport()
        self.bridge = CodexBridge(self.transport, cwd="/tmp/project")

    def test_normal_prompt_is_sent_to_the_active_thread(self):
        self.bridge.start()
        self.bridge.submit("修复登录错误")

        self.assertEqual(
            self.transport.calls[-1],
            ("turn/start", {"threadId": "thread-123", "input": [{"type": "text", "text": "修复登录错误"}]}),
        )

    def test_common_controls_use_structured_app_server_methods(self):
        self.bridge.start()
        self.bridge.compact()
        self.bridge.set_goal("修复登录错误")
        self.bridge.set_goal_status("paused")
        self.bridge.set_goal_status("active")
        self.bridge.clear_goal()

        self.assertEqual(
            self.transport.calls[1:],
            [
                ("thread/compact/start", {"threadId": "thread-123"}),
                ("thread/goal/set", {"threadId": "thread-123", "objective": "修复登录错误", "status": "active"}),
                ("thread/goal/set", {"threadId": "thread-123", "status": "paused"}),
                ("thread/goal/set", {"threadId": "thread-123", "status": "active"}),
                ("thread/goal/clear", {"threadId": "thread-123"}),
            ],
        )

    def test_new_task_replaces_the_active_thread(self):
        self.bridge.start()
        self.bridge.new_task()

        self.assertEqual(self.transport.calls[-1], ("thread/start", {"cwd": "/tmp/project"}))
        self.assertEqual(self.bridge.thread_id, "thread-123")
