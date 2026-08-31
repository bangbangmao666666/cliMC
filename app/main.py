"""Run the local Codex voice-control server."""

from __future__ import annotations

import os

from app.codex_bridge import AppServerTransport, CodexBridge
from app.controller import VoiceController
from app.server import create_server
from app.siliconflow import SiliconFlowTranscriber


def main() -> None:
    transport = AppServerTransport()
    bridge = CodexBridge(transport, cwd=os.environ.get("CODEX_CWD") or os.getcwd())
    controller = VoiceController(bridge)
    transport.on_server_request = controller.capture_server_request
    try:
        transcriber = SiliconFlowTranscriber()
    except ValueError as error:
        transcriber = None
        print(f"语音转写未配置：{error}")
    server = create_server("127.0.0.1", int(os.environ.get("PORT", "8787")), controller, transcriber)
    print("Codex Voice Control: http://127.0.0.1:%s" % server.server_port)
    try:
        server.serve_forever()
    finally:
        transport.close()


if __name__ == "__main__":
    main()
