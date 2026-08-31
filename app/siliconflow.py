"""SiliconFlow OpenAI-compatible audio transcription client."""

import json
import mimetypes
import os
import secrets
import urllib.error
import urllib.request


class SiliconFlowError(RuntimeError):
    pass


class SiliconFlowTranscriber:
    def __init__(
        self,
        api_key: str | None = None,
        base_url: str | None = None,
        model: str | None = None,
    ) -> None:
        self.api_key = api_key if api_key is not None else os.environ.get("SILICONFLOW_API_KEY", "")
        if not self.api_key:
            raise ValueError("SILICONFLOW_API_KEY is required for speech transcription")
        self.base_url = (base_url or os.environ.get("SILICONFLOW_BASE_URL") or "https://api.siliconflow.cn/v1").rstrip("/")
        self.model = model or os.environ.get("SILICONFLOW_ASR_MODEL") or "FunAudioLLM/SenseVoiceSmall"

    def transcribe(self, filename: str, data: bytes, content_type: str | None = None) -> str:
        if not data:
            raise SiliconFlowError("录音为空，请按住按钮后再说话。")
        boundary = "----codexvoice" + secrets.token_hex(12)
        mime_type = content_type or mimetypes.guess_type(filename)[0] or "application/octet-stream"
        body = self._multipart(boundary, filename, data, mime_type)
        request = urllib.request.Request(
            f"{self.base_url}/audio/transcriptions",
            data=body,
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Accept": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise SiliconFlowError(f"SiliconFlow 转写失败（HTTP {error.code}）：{detail}") from error
        except urllib.error.URLError as error:
            raise SiliconFlowError(f"无法连接 SiliconFlow：{error.reason}") from error
        text = payload.get("text")
        if not isinstance(text, str) or not text.strip():
            raise SiliconFlowError("SiliconFlow 没有返回可用文本。")
        return text.strip()

    def _multipart(self, boundary: str, filename: str, data: bytes, mime_type: str) -> bytes:
        prefix = (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="model"\r\n\r\n'
            f"{self.model}\r\n"
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
            f"Content-Type: {mime_type}\r\n\r\n"
        ).encode("utf-8")
        return prefix + data + f"\r\n--{boundary}--\r\n".encode("utf-8")
