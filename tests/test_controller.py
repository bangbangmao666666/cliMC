import unittest

from app.controller import VoiceController


class FakeBridge:
    def __init__(self):
        self.calls = []
        self.transport = self

    def new_task(self): self.calls.append(("new_task",))
    def compact(self): self.calls.append(("compact",))
    def set_goal(self, objective): self.calls.append(("set_goal", objective))
    def set_goal_status(self, status): self.calls.append(("set_goal_status", status))
    def clear_goal(self): self.calls.append(("clear_goal",))
    def submit(self, text): self.calls.append(("submit", text))
    def respond(self, request_id, result): self.calls.append(("respond", request_id, result))


class VoiceControllerTests(unittest.TestCase):
    def setUp(self):
        self.bridge = FakeBridge()
        self.controller = VoiceController(self.bridge)

    def test_preview_does_not_execute_a_spoken_command(self):
        preview = self.controller.preview("压缩一下上下文")

        self.assertEqual(preview["kind"], "compact")
        self.assertEqual(self.bridge.calls, [])

    def test_execute_routes_commands_and_prompts(self):
        self.controller.execute("目标是修复登录错误")
        self.controller.execute("帮我解释这个报错")

        self.assertEqual(self.bridge.calls, [("set_goal", "修复登录错误"), ("submit", "帮我解释这个报错")])

    def test_forwards_pending_codex_approval_only_after_user_choice(self):
        self.controller.capture_server_request(
            {"id": 9, "method": "item/commandExecution/requestApproval", "params": {"command": "rm -rf build", "reason": "clean"}}
        )

        self.assertEqual(self.controller.pending_approvals()[0]["params"]["command"], "rm -rf build")
        self.assertEqual(self.bridge.calls, [])

        self.controller.resolve_approval(9, "decline")

        self.assertEqual(self.bridge.calls, [("respond", 9, {"decision": "decline"})])
        self.assertEqual(self.controller.pending_approvals(), [])

    def test_forwards_permission_escalation_with_schema_valid_profile(self):
        self.controller.capture_server_request(
            {"id": 10, "method": "item/permissions/requestApproval", "params": {"permissions": {"network": {"enabled": True}}}}
        )

        self.controller.resolve_approval(10, "accept")

        self.assertEqual(self.bridge.calls, [("respond", 10, {"permissions": {"network": {"enabled": True}}})])
