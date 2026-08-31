"""Application actions shared by HTTP handlers and app-server callbacks."""

from __future__ import annotations

from typing import Any

from app.intents import CommandKind, parse_intent


class VoiceController:
    def __init__(self, bridge: Any) -> None:
        self.bridge = bridge
        self._approvals: dict[int | str, dict[str, Any]] = {}

    def preview(self, text: str) -> dict[str, str | None]:
        intent = parse_intent(text)
        return {"kind": intent.kind.value, "text": intent.text, "objective": intent.objective}

    def execute(self, text: str) -> dict[str, str | None]:
        intent = parse_intent(text)
        if intent.kind is CommandKind.NEW_TASK:
            self.bridge.new_task()
        elif intent.kind is CommandKind.COMPACT:
            self.bridge.compact()
        elif intent.kind is CommandKind.SET_GOAL:
            self.bridge.set_goal(intent.objective or "")
        elif intent.kind is CommandKind.PAUSE_GOAL:
            self.bridge.set_goal_status("paused")
        elif intent.kind is CommandKind.RESUME_GOAL:
            self.bridge.set_goal_status("active")
        elif intent.kind is CommandKind.CLEAR_GOAL:
            self.bridge.clear_goal()
        else:
            self.bridge.submit(intent.text)
        return self.preview(text)

    def capture_server_request(self, request: dict[str, Any]) -> None:
        if request.get("method") in {
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "execCommandApproval",
            "item/permissions/requestApproval",
        }:
            self._approvals[request["id"]] = request

    def pending_approvals(self) -> list[dict[str, Any]]:
        return list(self._approvals.values())

    def resolve_approval(self, request_id: int | str, decision: str) -> None:
        if decision not in {"accept", "decline", "cancel", "acceptForSession"}:
            raise ValueError("unsupported approval decision")
        if request_id not in self._approvals:
            raise KeyError("approval request not found")
        request = self._approvals[request_id]
        if request["method"] == "item/permissions/requestApproval":
            permissions = request["params"].get("permissions", {}) if decision in {"accept", "acceptForSession"} else {}
            result: dict[str, Any] = {"permissions": permissions}
            if decision == "acceptForSession":
                result["scope"] = "session"
            self.bridge.transport.respond(request_id, result)
        else:
            self.bridge.transport.respond(request_id, {"decision": decision})
        del self._approvals[request_id]
