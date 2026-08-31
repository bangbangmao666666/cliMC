"""Small, version-isolated client for Codex app-server JSON-RPC."""

from __future__ import annotations

import json
import os
import queue
import subprocess
import threading
from collections.abc import Callable
from typing import Any, Protocol


class Transport(Protocol):
    def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]: ...


class CodexBridge:
    def __init__(self, transport: Transport, cwd: str | None = None) -> None:
        self.transport = transport
        self.cwd = cwd or os.getcwd()
        self.thread_id: str | None = None

    def start(self) -> str:
        response = self.transport.request("thread/start", {"cwd": self.cwd})
        thread = response.get("thread", {})
        thread_id = thread.get("id") or response.get("threadId")
        if not isinstance(thread_id, str) or not thread_id:
            raise RuntimeError("Codex app-server did not return a thread id")
        self.thread_id = thread_id
        return thread_id

    def new_task(self) -> str:
        return self.start()

    def submit(self, text: str) -> None:
        self.transport.request("turn/start", {"threadId": self._thread(), "input": [{"type": "text", "text": text}]})

    def compact(self) -> None:
        self.transport.request("thread/compact/start", {"threadId": self._thread()})

    def set_goal(self, objective: str) -> None:
        self.transport.request(
            "thread/goal/set",
            {"threadId": self._thread(), "objective": objective, "status": "active"},
        )

    def set_goal_status(self, status: str) -> None:
        if status not in {"active", "paused"}:
            raise ValueError("goal status must be active or paused")
        self.transport.request("thread/goal/set", {"threadId": self._thread(), "status": status})

    def clear_goal(self) -> None:
        self.transport.request("thread/goal/clear", {"threadId": self._thread()})

    def _thread(self) -> str:
        if not self.thread_id:
            return self.start()
        return self.thread_id


class AppServerTransport:
    """Line-oriented JSON-RPC transport with a callback for approval requests."""

    def __init__(self, codex_bin: str | None = None, on_server_request: Callable[[dict[str, Any]], None] | None = None) -> None:
        self.codex_bin = codex_bin or os.environ.get("CODEX_BIN", "codex")
        self.on_server_request = on_server_request
        self.process: subprocess.Popen[str] | None = None
        self._next_id = 1
        self._waiters: dict[int, queue.Queue[dict[str, Any]]] = {}
        self._lock = threading.Lock()

    def start(self) -> None:
        if self.process and self.process.poll() is None:
            return
        self.process = subprocess.Popen(
            [self.codex_bin, "app-server", "--listen", "stdio://"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._drain_stderr, daemon=True).start()
        self.request("initialize", {"clientInfo": {"name": "codex-voice-control", "version": "0.1.0"}, "capabilities": {}})

    def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        self.start()
        with self._lock:
            request_id = self._next_id
            self._next_id += 1
            waiter: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=1)
            self._waiters[request_id] = waiter
            self._write({"id": request_id, "method": method, "params": params})
        try:
            response = waiter.get(timeout=120)
        except queue.Empty as error:
            raise RuntimeError(f"Codex app-server timed out while handling {method}") from error
        finally:
            self._waiters.pop(request_id, None)
        if "error" in response:
            raise RuntimeError(f"Codex app-server error for {method}: {response['error']}")
        return response.get("result", {})

    def respond(self, request_id: int | str, result: dict[str, Any]) -> None:
        self._write({"id": request_id, "result": result})

    def close(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()

    def _write(self, payload: dict[str, Any]) -> None:
        if not self.process or not self.process.stdin:
            raise RuntimeError("Codex app-server is not running")
        self.process.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
        self.process.stdin.flush()

    def _read_stdout(self) -> None:
        if not self.process or not self.process.stdout:
            return
        for line in self.process.stdout:
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            message_id = payload.get("id")
            if isinstance(message_id, int) and message_id in self._waiters:
                self._waiters[message_id].put(payload)
            elif "method" in payload and self.on_server_request:
                self.on_server_request(payload)

    def _drain_stderr(self) -> None:
        if not self.process or not self.process.stderr:
            return
        for _line in self.process.stderr:
            pass
