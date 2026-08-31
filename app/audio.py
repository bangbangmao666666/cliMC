"""Normalize browser recordings to the WAV format SiliconFlow accepts reliably."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


class AudioConversionError(RuntimeError):
    pass


def normalize_for_transcription(filename: str, data: bytes, content_type: str) -> tuple[str, bytes, str]:
    if content_type in {"audio/wav", "audio/x-wav"} or filename.lower().endswith(".wav"):
        return filename, data, "audio/wav"
    suffix = Path(filename).suffix or ".webm"
    with tempfile.TemporaryDirectory(prefix="codex-voice-") as directory:
        source = Path(directory) / f"recording{suffix}"
        target = Path(directory) / "speech.wav"
        source.write_bytes(data)
        try:
            subprocess.run(
                ["ffmpeg", "-y", "-i", str(source), "-ar", "16000", "-ac", "1", str(target)],
                check=True,
                capture_output=True,
            )
        except FileNotFoundError as error:
            raise AudioConversionError("未找到 ffmpeg。请执行 `brew install ffmpeg` 后重试。") from error
        except subprocess.CalledProcessError as error:
            detail = error.stderr.decode("utf-8", errors="replace").strip()
            raise AudioConversionError(f"录音格式转换失败：{detail or 'ffmpeg 未能读取该录音'}") from error
        return "speech.wav", target.read_bytes(), "audio/wav"
