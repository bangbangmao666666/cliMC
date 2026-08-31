"""Dependency-free localhost HTTP server for the voice console."""

from __future__ import annotations

import json
import mimetypes
from email import policy
from email.parser import BytesParser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from app.audio import normalize_for_transcription

STATIC_DIR = Path(__file__).with_name("static")


def create_server(host: str, port: int, controller: Any, transcriber: Any) -> ThreadingHTTPServer:
    class VoiceServer(ThreadingHTTPServer):
        allow_reuse_address = True

    server = VoiceServer((host, port), VoiceHandler)
    server.controller = controller
    server.transcriber = transcriber
    return server


class VoiceHandler(BaseHTTPRequestHandler):
    server: Any

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/":
            return self._file(STATIC_DIR / "index.html", "text/html; charset=utf-8")
        if path == "/api/approvals":
            return self._json(HTTPStatus.OK, {"approvals": self.server.controller.pending_approvals()})
        self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        try:
            if path == "/api/preview":
                return self._json(HTTPStatus.OK, self.server.controller.preview(self._body_json()["text"]))
            if path == "/api/execute":
                return self._json(HTTPStatus.OK, self.server.controller.execute(self._body_json()["text"]))
            if path == "/api/approval":
                body = self._body_json()
                self.server.controller.resolve_approval(body["id"], body["decision"])
                return self._json(HTTPStatus.OK, {"ok": True})
            if path == "/api/transcribe":
                if not self.server.transcriber:
                    raise RuntimeError("语音转写尚未配置。请设置 SILICONFLOW_API_KEY 后重启服务。")
                filename, data, content_type = self._uploaded_file()
                filename, data, content_type = normalize_for_transcription(filename, data, content_type)
                text = self.server.transcriber.transcribe(filename, data, content_type)
                return self._json(HTTPStatus.OK, {"text": text, "preview": self.server.controller.preview(text)})
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        except (KeyError, ValueError) as error:
            self._json(HTTPStatus.BAD_REQUEST, {"error": str(error)})
        except Exception as error:
            self._json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(error)})

    def _body_json(self) -> dict[str, Any]:
        size = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(size).decode("utf-8"))

    def _uploaded_file(self) -> tuple[str, bytes, str]:
        size = int(self.headers.get("Content-Length", "0"))
        content_type = self.headers.get("Content-Type", "")
        message = BytesParser(policy=policy.default).parsebytes(
            f"Content-Type: {content_type}\r\nMIME-Version: 1.0\r\n\r\n".encode() + self.rfile.read(size)
        )
        for part in message.iter_attachments():
            if part.get_filename():
                return part.get_filename(), part.get_payload(decode=True), part.get_content_type()
        raise ValueError("没有收到录音文件")

    def _file(self, path: Path, content_type: str | None = None) -> None:
        if not path.is_file():
            return self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        data = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type or mimetypes.guess_type(path.name)[0] or "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _json(self, status: HTTPStatus, payload: Any) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format: str, *args: Any) -> None:
        return
