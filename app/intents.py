"""Deterministic spoken-command recognition for the voice preview."""

from dataclasses import dataclass
from enum import Enum


class CommandKind(str, Enum):
    PROMPT = "prompt"
    NEW_TASK = "new_task"
    COMPACT = "compact"
    SET_GOAL = "set_goal"
    PAUSE_GOAL = "pause_goal"
    RESUME_GOAL = "resume_goal"
    CLEAR_GOAL = "clear_goal"


@dataclass(frozen=True)
class Intent:
    kind: CommandKind
    text: str
    objective: str | None = None


def parse_intent(text: str) -> Intent:
    """Map only deliberate, exact command phrases; everything else is a prompt."""
    normalized = text.strip()
    if normalized in {"新开一个任务", "新任务", "清屏", "清空对话"}:
        return Intent(CommandKind.NEW_TASK, normalized)
    if normalized in {"压缩上下文", "压缩一下上下文", "压缩对话"}:
        return Intent(CommandKind.COMPACT, normalized)
    if normalized in {"暂停目标", "暂停一下目标"}:
        return Intent(CommandKind.PAUSE_GOAL, normalized)
    if normalized in {"继续目标", "恢复目标", "继续一下目标"}:
        return Intent(CommandKind.RESUME_GOAL, normalized)
    if normalized in {"清除目标", "取消目标"}:
        return Intent(CommandKind.CLEAR_GOAL, normalized)
    for prefix in ("目标是", "设置目标为", "目标："):
        if normalized.startswith(prefix) and normalized[len(prefix) :].strip():
            objective = normalized[len(prefix) :].strip()
            return Intent(CommandKind.SET_GOAL, normalized, objective)
    return Intent(CommandKind.PROMPT, normalized)
