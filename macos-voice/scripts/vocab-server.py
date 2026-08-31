#!/usr/bin/env python3
"""cliMC 自定义热词 Web 编辑器

启动一个本地 HTTP 服务器，提供热词编辑页面。
用法: python3 vocab-server.py --port 0 --data /path/to/vocabulary.json
输出: 第一行打印实际绑定的端口号（供 Swift 父进程读取）
"""
from __future__ import annotations

import http.server
import json
import os
import sys
import socket
import argparse
from pathlib import Path
from urllib.parse import urlparse


HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>cliMC 自定义热词</title>
<link rel="icon" type="image/png" href="/icon.png">
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
  background: #0d1117;
  color: #c9d1d9;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  min-height: 100vh;
}
.container { max-width: 720px; margin: 0 auto; padding: 24px 20px; }

.header {
  display: flex; justify-content: space-between; align-items: center;
  margin-bottom: 20px; flex-wrap: wrap; gap: 12px;
}
.header h1 { font-size: 22px; font-weight: 600; color: #f0f6fc; }
.header p { font-size: 13px; color: #8b949e; margin-top: 4px; }
.logo { width: 36px; height: 36px; border-radius: 8px; flex-shrink: 0; }

/* 主列表 */
#list { margin-bottom: 16px; }
.row {
  display: flex; align-items: center; gap: 10px;
  background: #161b22; border: 1px solid #21262d;
  border-radius: 8px; padding: 12px 14px; margin-bottom: 8px;
  transition: border-color 0.15s;
}
.row:hover { border-color: #30363d; }
.row .word {
  flex: 1; min-width: 0;
}
.row .word input {
  width: 100%; padding: 6px 10px; font-size: 14px;
  background: #0d1117; color: #c9d1d9; border: 1px solid #30363d;
  border-radius: 6px; outline: none; font-family: 'SF Mono', 'Menlo', monospace;
}
.row .word input:focus { border-color: #58a6ff; }

.row .wlabel {
  font-size: 12px; color: #8b949e; white-space: nowrap;
}
.row .weight input {
  width: 60px; padding: 6px 8px; font-size: 14px; text-align: center;
  background: #0d1117; color: #c9d1d9; border: 1px solid #30363d;
  border-radius: 6px; outline: none;
}
.row .weight input:focus { border-color: #58a6ff; }

.row .del {
  width: 32px; height: 32px; display: flex; align-items: center; justify-content: center;
  background: transparent; border: 1px solid #30363d; border-radius: 6px;
  color: #f85149; font-size: 18px; cursor: pointer; transition: all 0.15s;
  flex-shrink: 0;
}
.row .del:hover { background: #f85149; color: #fff; border-color: #f85149; }

.empty {
  text-align: center; padding: 40px 0; color: #484f58; font-size: 14px;
}

/* 操作栏 */
.actions {
  display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 20px;
}
.actions button {
  padding: 8px 16px; border-radius: 6px; font-size: 13px;
  cursor: pointer; transition: all 0.15s; border: 1px solid #30363d;
}
.btn-add {
  background: #238636; border-color: #2ea043; color: #fff;
}
.btn-add:hover { background: #2ea043; }
.btn-save {
  background: #21262d; color: #c9d1d9;
}
.btn-save:hover { background: #30363d; }

/* 保存状态 */
#status {
  font-size: 13px; color: #7ee787; margin-top: 8px; text-align: center;
  opacity: 0; transition: opacity 0.3s;
}
#status.show { opacity: 1; }
#status.error { color: #f85149; }

/* 提示 */
.tip {
  font-size: 12px; color: #484f58; text-align: center; margin-top: 24px;
  line-height: 1.6;
}

/* 搜索 */
.search-box {
  margin-bottom: 16px;
}
.search-box input {
  width: 100%; padding: 8px 12px; font-size: 13px;
  background: #161b22; color: #c9d1d9; border: 1px solid #30363d;
  border-radius: 6px; outline: none;
}
.search-box input:focus { border-color: #58a6ff; }
.search-box input::placeholder { color: #484f58; }
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <div style="display:flex;align-items:center;gap:12px;">
      <img src="/icon.png" class="logo">
      <div>
        <h1>自定义热词</h1>
        <p>添加后，火山引擎 ASR 会优先识别这些词汇</p>
      </div>
    </div>
  </div>

  <div class="search-box">
    <input type="text" id="search" placeholder="搜索热词…" oninput="render()">
  </div>

  <div class="actions">
    <button class="btn-add" onclick="addRow()">+ 添加热词</button>
    <button class="btn-save" onclick="save()">💾 保存</button>
  </div>

  <div id="list"></div>
  <div id="status"></div>

  <div class="tip">
    <b>权重</b>（1–10）：数值越高，ASR 越倾向选择该词。<br>
    修改后点击「保存」或按 ⌘S 生效，下次录音即应用。
  </div>
</div>

<script>
let data = { hotwords: {} };
let dirty = false;

function load() {
  fetch('/api/hotwords')
    .then(r => r.json())
    .then(d => { data = d; render(); })
    .catch(err => showStatus('加载失败: ' + err, true));
}

function render() {
  const q = (document.getElementById('search').value || '').toLowerCase();
  const entries = Object.entries(data.hotwords);
  const filtered = q ? entries.filter(([w]) => w.toLowerCase().includes(q)) : entries;

  if (filtered.length === 0) {
    document.getElementById('list').innerHTML =
      '<div class="empty">' + (entries.length === 0 ? '还没有热词，点击上方添加' : '无匹配结果') + '</div>';
    return;
  }

  document.getElementById('list').innerHTML = filtered.map(([word, weight]) =>
    '<div class="row">' +
      '<div class="word"><input type="text" value="' + escAttr(word) + '" oninput="update(\'' + escAttr(word) + '\', this.value, getWeight(this))" onkeydown="onKey(event)"></div>' +
      '<span class="wlabel">权重</span>' +
      '<div class="weight"><input type="number" min="1" max="10" value="' + weight + '" oninput="updateWeight(\'' + escAttr(word) + '\', this.value)" onkeydown="onKey(event)"></div>' +
      '<button class="del" onclick="remove(\'' + escAttr(word) + '\')">✕</button>' +
    '</div>'
  ).join('');
}

function getWeight(input) {
  const row = input.closest('.row');
  return row ? row.querySelector('.weight input').value : 1;
}

function update(oldWord, newWord, weight) {
  if (newWord === oldWord) return;
  delete data.hotwords[oldWord];
  if (newWord) data.hotwords[newWord] = parseInt(weight) || 1;
  dirty = true;
  render();
}

function updateWeight(word, value) {
  const w = parseInt(value);
  if (w > 0 && w <= 10) {
    data.hotwords[word] = w;
    dirty = true;
  }
}

function remove(word) {
  delete data.hotwords[word];
  dirty = true;
  render();
}

function addRow() {
  const base = '新热词';
  let n = 1;
  while (data.hotwords[base + n]) n++;
  data.hotwords[base + n] = 5;
  dirty = true;
  render();
  // 聚焦到新输入框
  const rows = document.querySelectorAll('.row .word input');
  const last = rows[rows.length - 1];
  if (last) { last.focus(); last.select(); }
}

function save() {
  fetch('/api/hotwords', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data)
  })
    .then(r => {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      dirty = false;
      showStatus('✅ 已保存 — 下次录音生效');
    })
    .catch(err => showStatus('❌ 保存失败: ' + err, true));
}

function showStatus(msg, isError) {
  const el = document.getElementById('status');
  el.textContent = msg;
  el.className = 'show' + (isError ? ' error' : '');
  if (!isError) setTimeout(() => { el.className = ''; }, 2500);
}

function escAttr(s) { return s.replace(/&/g,'&amp;').replace(/'/g,'&apos;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

function onKey(e) {
  if (e.key === 'Enter') {
    const rows = [...document.querySelectorAll('.row .word input')];
    const idx = rows.indexOf(e.target);
    const next = rows[idx + 1];
    if (next) next.focus();
  }
}

document.addEventListener('keydown', e => {
  if ((e.metaKey || e.ctrlKey) && e.key === 's') { e.preventDefault(); save(); }
});

window.addEventListener('beforeunload', e => {
  if (dirty) { e.preventDefault(); e.returnValue = ''; }
});

load();
</script>
</body>
</html>"""


class VocabHandler(http.server.BaseHTTPRequestHandler):
    data_path: str = ""
    icon_path: str = ""

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._send_html()
        elif parsed.path in ("/icon.png", "/favicon.ico"):
            self._send_icon()
        elif parsed.path == "/api/hotwords":
            self._send_data()
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/hotwords":
            self._save_data()
        else:
            self.send_response(404)
            self.end_headers()

    def _send_icon(self):
        try:
            with open(self.icon_path, "rb") as f:
                data = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "max-age=3600")
            self.end_headers()
            self.wfile.write(data)
        except (FileNotFoundError, OSError):
            self.send_response(404)
            self.end_headers()

    def _send_html(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(HTML.encode("utf-8"))

    def _send_data(self):
        vocab = self._load()
        body = json.dumps(vocab, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _save_data(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        new_vocab = json.loads(body)
        with open(self.data_path, "w", encoding="utf-8") as f:
            json.dump(new_vocab, f, ensure_ascii=False, indent=2)
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def _load(self) -> dict:
        path = Path(self.data_path)
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
        return {"hotwords": {}}

    def log_message(self, fmt, *args):
        pass


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description="cliMC 自定义热词服务器")
    parser.add_argument("--port", type=int, default=0, help="端口号（0=自动分配）")
    parser.add_argument("--data", type=str, default="", help="vocabulary.json 路径")
    parser.add_argument("--icon", type=str, default="", help="cliMC.png 路径")
    args = parser.parse_args()

    port = args.port or find_free_port()
    data_path = args.data
    icon_path = args.icon
    if not icon_path:
        script_dir = Path(__file__).parent
        candidate = script_dir / "cliMC.png"
        if candidate.exists():
            icon_path = str(candidate)

    if not data_path:
        data_path = str(Path.home() / ".config/codex-voice/vocabulary.json")

    VocabHandler.data_path = data_path
    VocabHandler.icon_path = icon_path

    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), VocabHandler)
    print(port, flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
