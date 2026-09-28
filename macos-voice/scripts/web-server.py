#!/usr/bin/env python3
"""cliMC 统一 Web 服务器

提供使用统计仪表盘和自定义热词编辑器。
用法: python3 web-server.py --port 0 --stats-data /path/to/usage-events.jsonl --vocab-data /path/to/vocabulary.json --icon /path/to/cliMC.png
输出: 第一行打印实际绑定的端口号（供 Swift 父进程读取）
"""
from __future__ import annotations

import http.server
import json
import os
import sys
import socket
import argparse
from datetime import datetime, timezone, timedelta
from collections import defaultdict
from pathlib import Path
from urllib.parse import urlparse, parse_qs


# ═══════════════════════════════════════════════════════
# 共享 HTML 片段
# ═══════════════════════════════════════════════════════

LANDING_HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>cliMC</title>
<link rel="icon" type="image/png" href="/icon.png">
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
  background: #0d1117;
  color: #c9d1d9;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  min-height: 100vh; display: flex; align-items: center; justify-content: center;
}
.card {
  background: #161b22; border: 1px solid #21262d; border-radius: 12px;
  padding: 40px; text-align: center; max-width: 360px;
}
.logo { width: 64px; height: 64px; border-radius: 12px; margin-bottom: 16px; }
h1 { font-size: 20px; font-weight: 600; color: #f0f6fc; margin-bottom: 4px; }
p { font-size: 13px; color: #8b949e; margin-bottom: 24px; }
.btn {
  display: block; width: 100%; padding: 10px 0; border-radius: 8px;
  font-size: 14px; cursor: pointer; transition: background 0.15s;
  text-decoration: none; margin-bottom: 10px;
}
.btn-primary { background: #238636; border: 1px solid #2ea043; color: #fff; }
.btn-primary:hover { background: #2ea043; }
.btn-secondary { background: #21262d; border: 1px solid #30363d; color: #c9d1d9; }
.btn-secondary:hover { background: #30363d; }
</style>
</head>
<body>
<div class="card">
  <img src="/icon.png" class="logo">
  <h1>cliMC</h1>
  <p>语音输入助手</p>
  <a href="/stats/" class="btn btn-primary">📊 使用统计</a>
  <a href="/vocab/" class="btn btn-secondary">📝 自定义热词</a>
</div>
</body>
</html>"""


# ═══════════════════════════════════════════════════════
# 热词编辑器 HTML
# ═══════════════════════════════════════════════════════

DEFAULT_PROMPT_TEMPLATE = """你是中文语音识别纠错助手。请结合上下文，只修正明确的识别错误。
保留原句的表达、语气和格式，不要补充、改写或解释内容。
已知标准术语：
{{known_terms}}

最终识别文本：
{{recognized_text}}

只返回 JSON：{\"corrections\":[{\"source\":\"识别文本中连续出现且仅出现一次的原文片段\",\"replacement\":\"正确文本\"}]}。
只提供局部替换，不确定时返回空数组，最多 5 项。"""

VOCAB_HTML = r"""<!DOCTYPE html>
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
.header { display: flex; align-items: center; gap: 12px; margin-bottom: 20px; flex-wrap: wrap; }
.header h1 { font-size: 22px; font-weight: 600; color: #f0f6fc; }
.header p { font-size: 13px; color: #8b949e; margin-top: 2px; }
.logo { width: 36px; height: 36px; border-radius: 8px; flex-shrink: 0; }

.back { font-size: 13px; color: #58a6ff; text-decoration: none; display: inline-block; margin-bottom: 12px; }
.back:hover { text-decoration: underline; }

#list { margin-bottom: 16px; }
.row {
  display: flex; align-items: center; gap: 10px;
  background: #161b22; border: 1px solid #21262d;
  border-radius: 8px; padding: 12px 14px; margin-bottom: 8px;
  transition: border-color 0.15s;
}
.row:hover { border-color: #30363d; }
.row .word { flex: 1; min-width: 0; }
.row .word input {
  width: 100%; padding: 6px 10px; font-size: 14px;
  background: #0d1117; color: #c9d1d9; border: 1px solid #30363d;
  border-radius: 6px; outline: none; font-family: 'SF Mono', 'Menlo', monospace;
}
.row .word input:focus { border-color: #58a6ff; }
.row .wlabel { font-size: 12px; color: #8b949e; white-space: nowrap; }
.row .weight input {
  width: 60px; padding: 6px 8px; font-size: 14px; text-align: center;
  background: #0d1117; color: #c9d1d9; border: 1px solid #30363d;
  border-radius: 6px; outline: none;
}
.row .weight input:focus { border-color: #58a6ff; }
.row .del {
  width: 32px; height: 32px; display: flex; align-items: center; justify-content: center;
  background: transparent; border: 1px solid #30363d; border-radius: 6px;
  color: #f85149; font-size: 18px; cursor: pointer; transition: all 0.15s; flex-shrink: 0;
}
.row .del:hover { background: #f85149; color: #fff; border-color: #f85149; }
.empty { text-align: center; padding: 40px 0; color: #484f58; font-size: 14px; }
.actions { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 20px; }
.actions button {
  padding: 8px 16px; border-radius: 6px; font-size: 13px;
  cursor: pointer; transition: all 0.15s; border: 1px solid #30363d;
}
.btn-add { background: #238636; border-color: #2ea043; color: #fff; }
.btn-add:hover { background: #2ea043; }
.btn-save { background: #21262d; color: #c9d1d9; }
.btn-save:hover { background: #30363d; }
#status { font-size: 13px; color: #7ee787; margin-top: 8px; text-align: center; opacity: 0; transition: opacity 0.3s; }
#status.show { opacity: 1; }
#status.error { color: #f85149; }
.tip { font-size: 12px; color: #484f58; text-align: center; margin-top: 24px; line-height: 1.6; }
.search-box { margin-bottom: 16px; }
.search-box input {
  width: 100%; padding: 8px 12px; font-size: 13px;
  background: #161b22; color: #c9d1d9; border: 1px solid #30363d;
  border-radius: 6px; outline: none;
}
.search-box input:focus { border-color: #58a6ff; }
.search-box input::placeholder { color: #484f58; }
.section-tabs { display: flex; gap: 8px; border-bottom: 1px solid #21262d; margin-bottom: 20px; }
.section-tabs button { color: #8b949e; background: transparent; border: 0; border-bottom: 2px solid transparent; padding: 10px 12px; cursor: pointer; font-size: 14px; }
.section-tabs button.active { color: #f0f6fc; border-bottom-color: #58a6ff; }
.panel { display: none; }
.panel.active { display: block; }
.panel h2 { color: #f0f6fc; font-size: 18px; margin-bottom: 6px; }
.panel > p { color: #8b949e; font-size: 12px; line-height: 1.6; margin: 6px 0 14px; }
.field-label { display: block; color: #c9d1d9; font-size: 13px; margin: 14px 0 6px; }
.editor { width: 100%; min-height: 220px; resize: vertical; padding: 12px; background: #0d1117; color: #c9d1d9; border: 1px solid #30363d; border-radius: 6px; font: 13px/1.6 'SF Mono', Menlo, monospace; }
.editor:focus, .correction-input:focus { outline: none; border-color: #58a6ff; }
.section-status { color: #7ee787; font-size: 13px; min-height: 20px; margin: 10px 0; }
.section-status.error { color: #f85149; }
.correction-list { margin: 14px 0; }
.correction-item { display: grid; grid-template-columns: 1fr 24px 1fr 32px; align-items: center; gap: 8px; padding: 10px; margin-bottom: 8px; background: #161b22; border: 1px solid #21262d; border-radius: 8px; }
.correction-input { min-width: 0; width: 100%; padding: 8px 10px; background: #0d1117; color: #c9d1d9; border: 1px solid #30363d; border-radius: 6px; font-size: 13px; }
.recent-results { max-height: 240px; overflow-y: auto; margin: 12px 0; }
.recent-result { width: 100%; text-align: left; color: #c9d1d9; background: #161b22; border: 1px solid #21262d; border-radius: 6px; padding: 10px 12px; margin-bottom: 6px; cursor: pointer; }
.recent-result:hover { border-color: #58a6ff; }
.subtle { color: #8b949e; font-size: 12px; line-height: 1.6; }
@media (max-width: 600px) { .correction-item { grid-template-columns: 1fr 20px 1fr 32px; gap: 5px; padding: 8px; } .section-tabs button { padding: 10px 6px; font-size: 12px; } }
</style>
</head>
<body>
<div class="container">
  <a href="/" class="back">← 返回首页</a>
   <div class="header">
    <img src="/icon.png" class="logo">
    <div>
      <h1>自定义热词</h1>
      <p>管理提示词模板、火山引擎热词和识别纠错规则</p>
     </div>
   </div>
   <nav class="section-tabs" aria-label="热词管理">
     <button class="active" type="button" data-panel="panel-prompt">提示词管理</button>
     <button type="button" data-panel="panel-hotwords">热词管理</button>
     <button type="button" data-panel="panel-corrections">识别纠错</button>
   </nav>
   <section class="panel active" id="panel-prompt">
     <h2>提示词管理</h2>
     <p>查看和编辑本机保存的提示词模板。模板用于 ASR 最终文本的 DeepSeek 上下文纠错；火山引擎 ASR 本身使用热词表，不读取通用 Prompt。可使用 {{known_terms}} 和 {{recognized_text}} 占位符。</p>
     <label class="field-label" for="promptTemplate">提示词模板</label>
     <textarea class="editor" id="promptTemplate" spellcheck="false" aria-label="提示词模板"></textarea>
     <div class="actions"><button class="btn-save" type="button" onclick="savePrompt()">💾 保存模板</button></div>
     <div id="promptStatus" class="section-status" aria-live="polite"></div>
   </section>
   <section class="panel" id="panel-hotwords">
     <h2>热词管理</h2>
     <p>添加后，火山引擎 ASR 会优先识别这些词汇。</p>
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
   </section>
   <section class="panel" id="panel-corrections">
     <h2>识别纠错</h2>
     <p>从最近的最终识别文本中选择原文，编辑“识别为”中的错误片段，再填写正确文本。保存后会自动修正后续识别结果。</p>
     <div class="actions"><button class="btn-save" type="button" onclick="loadRecentResults()">↻ 刷新识别记录</button><button class="btn-add" type="button" onclick="addCorrection()">+ 添加纠错规则</button><button class="btn-save" type="button" onclick="saveCorrections()">💾 保存纠错</button></div>
     <div class="subtle">最近识别结果（点击一条可带入“识别为”）：</div>
     <div id="recentResults" class="recent-results"><div class="empty">正在读取最近记录…</div></div>
     <div class="correction-list" id="correctionList"></div>
     <div id="correctionStatus" class="section-status" aria-live="polite"></div>
   </section>
</div>
<script>
let data = { hotwords: {} };
let dirty = false;
let correctionData = { corrections: {} };
let promptDirty = false;
let correctionsDirty = false;
function setSectionStatus(id, message, isError) {
  const status = document.getElementById(id); status.textContent = message || '';
  status.className = 'section-status' + (isError ? ' error' : '');
}
document.querySelectorAll('.section-tabs button').forEach(button => button.addEventListener('click', () => {
  document.querySelectorAll('.section-tabs button').forEach(item => item.classList.toggle('active', item === button));
  document.querySelectorAll('.panel').forEach(panel => panel.classList.toggle('active', panel.id === button.dataset.panel));
}));
document.getElementById('promptTemplate').addEventListener('input', () => { promptDirty = true; });
document.getElementById('correctionList').addEventListener('input', () => { correctionsDirty = true; });
function loadPrompt() {
  fetch('/vocab/api/prompt').then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
    .then(result => { document.getElementById('promptTemplate').value = result.template || ''; promptDirty = false; })
    .catch(err => setSectionStatus('promptStatus', '模板加载失败：' + err, true));
}
function savePrompt() {
  fetch('/vocab/api/prompt', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ template: document.getElementById('promptTemplate').value }) })
    .then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); promptDirty = false; setSectionStatus('promptStatus', '✅ 模板已保存到本机'); })
    .catch(err => setSectionStatus('promptStatus', '❌ 保存失败：' + err, true));
}
function renderCorrections() {
  const list = document.getElementById('correctionList'); list.replaceChildren();
  Object.entries(correctionData.corrections).forEach(([source, target]) => addCorrectionRow(source, target));
}
function addCorrectionRow(source = '', target = '') {
  const row = document.createElement('div'); row.className = 'correction-item';
  const wrong = document.createElement('input'); wrong.className = 'correction-input'; wrong.value = source; wrong.placeholder = '识别为'; wrong.setAttribute('aria-label', '识别为');
  const arrow = document.createElement('span'); arrow.textContent = '→'; arrow.className = 'subtle';
  const right = document.createElement('input'); right.className = 'correction-input'; right.value = target; right.placeholder = '正确文本'; right.setAttribute('aria-label', '正确文本');
  const remove = document.createElement('button'); remove.type = 'button'; remove.className = 'del'; remove.textContent = '×'; remove.setAttribute('aria-label', '删除纠错规则');
  remove.addEventListener('click', () => { row.remove(); correctionsDirty = true; }); row.append(wrong, arrow, right, remove); document.getElementById('correctionList').appendChild(row);
  return wrong;
}
function addCorrection() { addCorrectionRow().focus(); correctionsDirty = true; }
function loadCorrections() {
  fetch('/vocab/api/corrections').then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
    .then(result => { correctionData.corrections = result.corrections || {}; correctionsDirty = false; renderCorrections(); })
    .catch(err => setSectionStatus('correctionStatus', '纠错规则加载失败：' + err, true));
}
function saveCorrections() {
  const corrections = {};
  document.querySelectorAll('.correction-item').forEach(row => {
    const inputs = row.querySelectorAll('input'); const source = inputs[0].value.trim(); const target = inputs[1].value.trim();
    if (source && target) corrections[source] = target;
  });
  fetch('/vocab/api/corrections', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ corrections }) })
    .then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); correctionData.corrections = corrections; correctionsDirty = false; renderCorrections(); setSectionStatus('correctionStatus', '✅ 纠错规则已保存，后续识别会自动应用'); })
    .catch(err => setSectionStatus('correctionStatus', '❌ 保存失败：' + err, true));
}
function loadRecentResults() {
  fetch('/vocab/api/recent-results').then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
    .then(result => {
      const list = document.getElementById('recentResults'); list.replaceChildren();
      if (!result.results.length) { list.innerHTML = '<div class="empty">暂无最终识别记录</div>'; return; }
      result.results.forEach(text => { const button = document.createElement('button'); button.type = 'button'; button.className = 'recent-result'; button.textContent = text; button.addEventListener('click', () => { const source = addCorrectionRow(text); source.parentElement.querySelectorAll('input')[1].focus(); correctionsDirty = true; }); list.appendChild(button); });
    }).catch(err => { const list = document.getElementById('recentResults'); list.textContent = '识别记录读取失败：' + err; });
}
function load() {
  fetch('/vocab/api/hotwords')
    .then(r => r.json())
    .then(d => { data = d; render(); })
    .catch(err => showStatus('加载失败: ' + err, true));
}
function render() {
  const q = (document.getElementById('search').value || '').toLowerCase();
  const entries = Object.entries(data.hotwords).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  const filtered = q ? entries.filter(([w]) => w.toLowerCase().includes(q)) : entries;
  const list = document.getElementById('list'); list.replaceChildren();
  if (filtered.length === 0) {
    const empty = document.createElement('div'); empty.className = 'empty';
    empty.textContent = entries.length === 0 ? '还没有热词，点击上方添加' : '无匹配结果'; list.appendChild(empty);
    return;
  }
  filtered.forEach(([word, weight]) => {
    const row = document.createElement('div'); row.className = 'row';
    const wordCell = document.createElement('div'); wordCell.className = 'word';
    const wordInput = document.createElement("input"); wordInput.type = 'text'; wordInput.value = word;
    wordInput.dataset.word = word;
    wordInput.addEventListener("input", () => update(wordInput, getWeight(wordInput)));
    wordInput.addEventListener('keydown', onKey); wordCell.appendChild(wordInput);
    const label = document.createElement('span'); label.className = 'wlabel'; label.textContent = '权重';
    const weightCell = document.createElement('div'); weightCell.className = 'weight';
    const weightInput = document.createElement('input'); weightInput.type = 'number'; weightInput.min = 1; weightInput.max = 10; weightInput.value = weight;
    weightInput.addEventListener("input", () => updateWeight(wordInput.dataset.word, weightInput.value)); weightInput.addEventListener('keydown', onKey); weightCell.appendChild(weightInput);
    const deleteButton = document.createElement('button'); deleteButton.className = 'del'; deleteButton.type = 'button'; deleteButton.textContent = '✕';
    deleteButton.addEventListener("click", () => remove(wordInput.dataset.word)); row.append(wordCell, label, weightCell, deleteButton); list.appendChild(row);
  });
}
function getWeight(input) {
  const row = input.closest('.row');
  return row ? row.querySelector('.weight input').value : 1;
}
function update(input, weight) {
  const oldWord = input.dataset.word;
  const newWord = input.value;
  if (newWord === oldWord) return;
  delete data.hotwords[oldWord];
  if (newWord) data.hotwords[newWord] = parseInt(weight) || 1;
  input.dataset.word = newWord;
  dirty = true;
}
function updateWeight(word, value) {
  const w = parseInt(value);
  if (w > 0 && w <= 10) { data.hotwords[word] = w; dirty = true; }
}
function remove(word) { delete data.hotwords[word]; dirty = true; render(); }
function addRow() {
  const base = '新热词'; let n = 1;
  while (data.hotwords[base + n]) n++;
  data.hotwords[base + n] = 5; dirty = true; render();
  const rows = document.querySelectorAll('.row .word input');
  const last = rows[rows.length - 1];
  if (last) { last.focus(); last.select(); }
}
function save() {
  fetch('/vocab/api/hotwords', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data)
  }).then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); dirty = false; render(); showStatus('✅ 已保存 — 下次录音生效'); })
    .catch(err => showStatus('❌ 保存失败: ' + err, true));
}
function showStatus(msg, isError) {
  const el = document.getElementById('status');
  el.textContent = msg; el.className = 'show' + (isError ? ' error' : '');
  if (!isError) setTimeout(() => { el.className = ''; }, 2500);
}
function onKey(e) {
  if (e.key === 'Enter') {
    const rows = [...document.querySelectorAll('.row .word input')];
    const idx = rows.indexOf(e.target);
    const next = rows[idx + 1];
    if (next) next.focus();
  }
}
document.addEventListener('keydown', e => {
  if ((e.metaKey || e.ctrlKey) && e.key === 's') {
    e.preventDefault();
    if (e.target.closest('#panel-prompt')) savePrompt();
    else if (e.target.closest('#panel-corrections')) saveCorrections();
    else save();
  }
});
window.addEventListener('beforeunload', e => { if (dirty || promptDirty || correctionsDirty) { e.preventDefault(); e.returnValue = ''; } });
load(); loadPrompt(); loadCorrections(); loadRecentResults();
</script>
</body>
</html>"""


# ═══════════════════════════════════════════════════════
# 统计仪表盘 HTML
# ═══════════════════════════════════════════════════════

STATS_HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>cliMC 使用统计</title>
<link rel="icon" type="image/png" href="/icon.png">
<script src="https://cdn.jsdelivr.net/npm/echarts@5/dist/echarts.min.js"></script>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
  background: #0d1117;
  color: #c9d1d9;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  min-height: 100vh;
}
.container { max-width: 1100px; margin: 0 auto; padding: 24px 20px; }
.back { font-size: 13px; color: #58a6ff; text-decoration: none; display: inline-block; margin-bottom: 12px; }
.back:hover { text-decoration: underline; }
.header {
  display: flex; justify-content: space-between; align-items: center;
  margin-bottom: 20px; flex-wrap: wrap; gap: 12px;
}
.header-left { display: flex; align-items: center; gap: 12px; }
.header h1 { font-size: 22px; font-weight: 600; color: #f0f6fc; }
.header p { font-size: 13px; color: #8b949e; }
.logo { width: 36px; height: 36px; border-radius: 8px; flex-shrink: 0; }
.controls { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.controls label { font-size: 13px; color: #8b949e; }
.controls input[type=date] { background: #161b22; color: #c9d1d9; border: 1px solid #30363d; padding: 6px 10px; border-radius: 6px; font-size: 13px; outline: none; }
.controls input[type=date]:focus { border-color: #58a6ff; }
.controls select { background: #161b22; color: #c9d1d9; border: 1px solid #30363d; padding: 6px 10px; border-radius: 6px; font-size: 13px; outline: none; }
.controls select:focus { border-color: #58a6ff; }
.controls button { background: #21262d; color: #c9d1d9; border: 1px solid #30363d; padding: 6px 14px; border-radius: 6px; font-size: 13px; cursor: pointer; transition: background 0.15s; }
.controls button:hover { background: #30363d; }
.controls button.primary { background: #238636; border-color: #2ea043; color: #fff; }
.controls button.primary:hover { background: #2ea043; }
.sep { color: #30363d; font-size: 13px; }
.cards-header { font-size: 13px; color: #8b949e; margin-bottom: 10px; }
.cards { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-bottom: 20px; }
.deepseek-cards { grid-template-columns: repeat(4, 1fr); }
@media (max-width: 600px) { .cards { grid-template-columns: repeat(1, 1fr); } .deepseek-cards { grid-template-columns: repeat(2, 1fr); } }
.card { background: #161b22; border-radius: 10px; padding: 16px; text-align: center; border: 1px solid #21262d; }
.card .val { font-size: 28px; font-weight: 700; line-height: 1.2; }
.card .lbl { font-size: 12px; color: #8b949e; margin-top: 4px; }
.c0 .val { color: #79c0ff; }
.c1 .val { color: #7ee787; }
.c2 .val { color: #d2a8ff; }
#chart { width: 100%; height: 480px; background: #161b22; border-radius: 10px; border: 1px solid #21262d; }
#heatmap { width: 100%; height: 220px; background: #161b22; border-radius: 10px; border: 1px solid #21262d; margin-top: 16px; }
.footer { text-align: center; margin-top: 12px; color: #484f58; font-size: 12px; }
</style>
</head>
<body>
<div class="container">
  <a href="/" class="back">← 返回首页</a>
  <div class="header">
    <div class="header-left">
      <img src="/icon.png" class="logo">
      <div>
        <h1>cliMC 使用统计</h1>
        <p>下方卡片为所选日期范围的合计</p>
      </div>
    </div>
    <div class="controls">
      <label>从</label><input type="date" id="startDate">
      <span class="sep">—</span>
      <label>到</label><input type="date" id="endDate">
      <button onclick="quick(1)">今天</button>
      <button onclick="quick(7)">7 天</button>
      <button onclick="quick(30)">30 天</button>
      <button class="primary" onclick="fetchData()">刷新</button>
    </div>
  </div>
  <div class="cards-header">所选范围合计</div>
  <div class="cards" id="cards"></div>
  <div class="cards-header">DeepSeek 上下文纠错（只保存计数，不保存识别文本）</div>
  <div class="cards deepseek-cards" id="deepSeekCards"></div>
  <div id="chart"></div>
  <div style="font-size:13px;color:#8b949e;margin:20px 0 10px 0;font-weight:500;">📝 全年生成字数热力图</div>
  <div id="heatmap"></div>
  <div class="footer" id="footer"></div>
</div>
<script>
const chart = echarts.init(document.getElementById('chart'), 'dark');
const heatmap = echarts.init(document.getElementById('heatmap'), 'dark');
(function initDates() {
  const now = new Date();
  const end = now.toISOString().split('T')[0];
  const start = new Date(now.getTime() - 29 * 86400000).toISOString().split('T')[0];
  document.getElementById('startDate').value = start;
  document.getElementById('endDate').value = end;
  fetchData(); fetchHeatmap();
})();
function todayStr() { return new Date().toISOString().split('T')[0]; }
function quick(days) {
  const end = todayStr();
  const d = new Date(); d.setDate(d.getDate() - days + 1);
  document.getElementById('startDate').value = d.toISOString().split('T')[0];
  document.getElementById('endDate').value = end;
  fetchData();
}
function fetchData() {
  const start = document.getElementById('startDate').value;
  const end = document.getElementById('endDate').value;
  fetch('/stats/api/data?start=' + start + '&end=' + end)
    .then(r => r.json()).then(data => {
      updateCards(data.summary); updateChart(data.daily, start, end);
      updateDeepSeekCards(data.summary);
      const activeDays = data.daily.filter(d => d.voiceInputCount || d.characterCount || d.autoSubmitCount || d.deepSeekRequestCount).length;
      document.getElementById('footer').textContent = '数据范围: ' + start + ' ~ ' + end + ' | ' + activeDays + ' 天有活动';
    }).catch(err => { document.getElementById('footer').textContent = '加载失败: ' + err; });
}
function fetchHeatmap() {
  const year = new Date().getFullYear();
  fetch('/stats/api/heatmap?year=' + year)
    .then(r => r.json()).then(data => updateHeatmap(data, year)).catch(() => {});
}
function updateCards(summary) {
  const labels = ['语音输入', '生成字数', '自动提交'];
  const keys = ['voiceInputCount', 'characterCount', 'autoSubmitCount'];
  const html = keys.map((k, i) => '<div class="card c' + i + '"><div class="val">' + (summary[k] || 0).toLocaleString() + '</div><div class="lbl">' + labels[i] + '</div></div>').join('');
  document.getElementById('cards').innerHTML = html;
}
function updateDeepSeekCards(summary) {
  const labels = ['请求次数', '成功响应', '发生改写的转写', '改写片段'];
  const keys = ['deepSeekRequestCount', 'deepSeekSuccessCount', 'deepSeekRewriteCount', 'deepSeekRewriteItemCount'];
  const html = keys.map((k, i) => '<div class="card c' + (i % 3) + '"><div class="val">' + (summary[k] || 0).toLocaleString() + '</div><div class="lbl">' + labels[i] + '</div></div>').join('');
  document.getElementById('deepSeekCards').innerHTML = html;
}
function trendDaily(daily) {
  return daily.filter(row => {
    const date = new Date(row.date + 'T00:00:00');
    const day = date.getDay();
    const isWeekday = day !== 0 && day !== 6;
    return isWeekday || (row.voiceInputCount || 0) > 10;
  });
}
function updateChart(daily, start, end) {
  const trend = trendDaily(daily);
  if (!trend.length) {
    chart.clear();
    chart.setOption({
      title: {
        text: '周末不展示趋势数据',
        left: 'center',
        top: 'middle',
        textStyle: { color: '#8b949e', fontSize: 13, fontWeight: 'normal' }
      }
    }, true);
    chart.resize();
    return;
  }
  const dates = trend.map(d => d.date.slice(5));
  const voiceInput = trend.map(d => d.voiceInputCount || 0);
  const characterCount = trend.map(d => d.characterCount || 0);
  const autoSubmit = trend.map(d => d.autoSubmitCount || 0);
  const deepSeekSuccess = trend.map(d => d.deepSeekSuccessCount || 0);
  const deepSeekRewrite = trend.map(d => d.deepSeekRewriteCount || 0);
  chart.setOption({
    tooltip: { trigger: 'axis', backgroundColor: '#1c2128', borderColor: '#30363d', textStyle: { color: '#c9d1d9', fontSize: 13 } },
    legend: { data: ['语音输入', '生成字数', '自动提交', 'DeepSeek 成功', 'DeepSeek 改写'], textStyle: { color: '#8b949e' }, top: 8 },
    grid: { left: 50, right: 70, top: 50, bottom: 30 },
    xAxis: { type: 'category', data: dates, axisLine: { lineStyle: { color: '#21262d' } }, axisLabel: { color: '#8b949e', fontSize: 11 }, splitLine: { show: false } },
    yAxis: [{ type: 'value', name: '次数', position: 'left', axisLine: { show: false }, axisLabel: { color: '#8b949e', fontSize: 11 }, splitLine: { lineStyle: { color: '#21262d', type: 'dashed' } } }, { type: 'value', name: '字数', position: 'right', axisLine: { show: false }, axisLabel: { color: '#8b949e', fontSize: 11 }, splitLine: { show: false } }],
    series: [{ name: '语音输入', type: 'line', yAxisIndex: 0, smooth: true, data: voiceInput, itemStyle: { color: '#79c0ff' }, lineStyle: { width: 3 }, symbol: 'circle', symbolSize: 6, areaStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: 'rgba(121, 192, 255, 0.3)' }, { offset: 1, color: 'rgba(121, 192, 255, 0.02)' }]) }, animationDuration: 400, animationEasing: 'cubicOut' }, { name: '生成字数', type: 'line', yAxisIndex: 1, smooth: true, data: characterCount, itemStyle: { color: '#7ee787' }, lineStyle: { width: 3 }, symbol: 'circle', symbolSize: 6, areaStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: 'rgba(126, 231, 135, 0.25)' }, { offset: 1, color: 'rgba(126, 231, 135, 0.01)' }]) }, animationDuration: 400 }, { name: '自动提交', type: 'line', yAxisIndex: 0, smooth: true, data: autoSubmit, itemStyle: { color: '#d2a8ff' }, lineStyle: { width: 3, type: 'dashed' }, symbol: 'circle', symbolSize: 6, animationDuration: 400 }, { name: 'DeepSeek 成功', type: 'line', yAxisIndex: 0, smooth: true, data: deepSeekSuccess, itemStyle: { color: '#f2cc60' }, lineStyle: { width: 2 }, symbol: 'circle', symbolSize: 5 }, { name: 'DeepSeek 改写', type: 'line', yAxisIndex: 0, smooth: true, data: deepSeekRewrite, itemStyle: { color: '#ff7b72' }, lineStyle: { width: 2 }, symbol: 'diamond', symbolSize: 6 }]
  }, true); chart.resize();
}
function updateHeatmap(data, year) {
  var maxVal = data.max || 1;
  heatmap.setOption({
    tooltip: { position: 'top', formatter: function(p) { var val = p.data ? p.data[1] || 0 : 0; return p.data[0] + '<br/>生成字数: ' + val.toLocaleString(); }, backgroundColor: '#1c2128', borderColor: '#30363d', textStyle: { color: '#c9d1d9', fontSize: 12 } },
    visualMap: { min: 0, max: maxVal, calculable: true, orient: 'horizontal', left: 'center', top: 0, inRange: { color: ['#161b22', '#0e4429', '#006d32', '#26a641', '#39d353'] }, textStyle: { color: '#8b949e', fontSize: 11 } },
    calendar: { top: 40, left: 10, right: 10, bottom: 10, range: year, cellSize: ['auto', 14], splitLine: { lineStyle: { color: '#0d1117', width: 2 } }, yearLabel: { show: false }, dayLabel: { nameMap: ['日', '一', '二', '三', '四', '五', '六'], textStyle: { color: '#8b949e', fontSize: 10 } }, monthLabel: { nameMap: 'ZH', textStyle: { color: '#8b949e', fontSize: 11 } }, itemStyle: { color: '#161b22', borderWidth: 1, borderColor: '#0d1117', borderRadius: 2 } },
    series: [{ type: 'heatmap', coordinateSystem: 'calendar', data: data.data, animation: false }]
  }, true); heatmap.resize();
}
window.addEventListener('resize', () => { chart.resize(); heatmap.resize(); });
</script>
</body>
</html>"""


# ═══════════════════════════════════════════════════════
# 数据层（统计）
# ═══════════════════════════════════════════════════════

def load_events(data_path: str) -> list[dict]:
    events: list[dict] = []
    path = Path(data_path)
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def parse_iso(s: str) -> datetime | None:
    try:
        timestamp = datetime.fromisoformat(s.replace("Z", "+00:00"))
        return timestamp if timestamp.tzinfo is not None else None
    except (ValueError, AttributeError):
        return None


def daily_summaries(events: list[dict], start: datetime, end: datetime) -> list[dict]:
    daily: dict[str, dict] = {}
    for ev in events:
        ts = parse_iso(ev.get("timestamp", ""))
        if ts is None or ts < start or ts > end:
            continue
        ts = ts.astimezone(timezone.utc)
        day = ts.strftime("%Y-%m-%d")
        if day not in daily:
            daily[day] = {"date": day, "voiceInputCount": 0, "characterCount": 0, "autoSubmitCount": 0, "deepSeekRequestCount": 0, "deepSeekSuccessCount": 0, "deepSeekRewriteCount": 0, "deepSeekRewriteItemCount": 0}
        event_type = ev.get("type", "")
        if event_type == "voice_started":
            daily[day]["voiceInputCount"] += 1
        elif event_type == "transcription_committed":
            daily[day]["characterCount"] += ev.get("characterCount", 0)
        elif event_type == "auto_submitted":
            daily[day]["autoSubmitCount"] += 1
        elif event_type == "deepseek_correction":
            daily[day]["deepSeekRequestCount"] += 1
            if ev.get("succeeded") is True:
                daily[day]["deepSeekSuccessCount"] += 1
                rewrite_count = ev.get("rewriteCount", 0)
                if isinstance(rewrite_count, int) and not isinstance(rewrite_count, bool) and rewrite_count > 0:
                    daily[day]["deepSeekRewriteCount"] += 1
                    daily[day]["deepSeekRewriteItemCount"] += rewrite_count
    result = sorted(daily.values(), key=lambda x: x["date"])
    if result:
        cursor = datetime.strptime(result[0]["date"], "%Y-%m-%d").date()
        end_date = datetime.strptime(result[-1]["date"], "%Y-%m-%d").date()
        filled = []
        idx = 0
        while cursor <= end_date:
            cursor_str = cursor.strftime("%Y-%m-%d")
            if idx < len(result) and result[idx]["date"] == cursor_str:
                filled.append(result[idx])
                idx += 1
            else:
                filled.append({"date": cursor_str, "voiceInputCount": 0, "characterCount": 0, "autoSubmitCount": 0, "deepSeekRequestCount": 0, "deepSeekSuccessCount": 0, "deepSeekRewriteCount": 0, "deepSeekRewriteItemCount": 0})
            cursor += timedelta(days=1)
        result = filled
    return result


def total_summary(events: list[dict], start: datetime, end: datetime) -> dict:
    total = {"voiceInputCount": 0, "characterCount": 0, "autoSubmitCount": 0, "deepSeekRequestCount": 0, "deepSeekSuccessCount": 0, "deepSeekRewriteCount": 0, "deepSeekRewriteItemCount": 0}
    for ev in events:
        ts = parse_iso(ev.get("timestamp", ""))
        if ts is None or ts < start or ts > end:
            continue
        event_type = ev.get("type", "")
        if event_type == "voice_started":
            total["voiceInputCount"] += 1
        elif event_type == "transcription_committed":
            total["characterCount"] += ev.get("characterCount", 0)
        elif event_type == "auto_submitted":
            total["autoSubmitCount"] += 1
        elif event_type == "deepseek_correction":
            total["deepSeekRequestCount"] += 1
            if ev.get("succeeded") is True:
                total["deepSeekSuccessCount"] += 1
                rewrite_count = ev.get("rewriteCount", 0)
                if isinstance(rewrite_count, int) and not isinstance(rewrite_count, bool) and rewrite_count > 0:
                    total["deepSeekRewriteCount"] += 1
                    total["deepSeekRewriteItemCount"] += rewrite_count
    return total


def load_json_object(data_path: str) -> dict:
    try:
        data = json.loads(Path(data_path).read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return {}


def parse_date_range(start_date: str | None, end_date: str | None) -> tuple[datetime, datetime] | None:
    try:
        start = datetime.strptime(start_date or "", "%Y-%m-%d").replace(tzinfo=timezone.utc)
        end = datetime.strptime(end_date or "", "%Y-%m-%d").replace(tzinfo=timezone.utc, hour=23, minute=59, second=59)
    except ValueError:
        return None
    return (start, end) if start <= end else None


def build_vocab_insights(vocabulary: dict, learner_state: dict, events: list[dict], start: datetime, end: datetime) -> dict:
    vocabulary = vocabulary if isinstance(vocabulary, dict) else {}
    learner_state = learner_state if isinstance(learner_state, dict) else {}
    hotwords = vocabulary.get("hotwords", {})
    hotwords = hotwords if isinstance(hotwords, dict) else {}
    learned = {
        word: state for word, state in learner_state.items()
        if word in hotwords and isinstance(state, dict)
    }
    dates = []
    cursor = start.date()
    while cursor <= end.date():
        dates.append(cursor.strftime("%Y-%m-%d"))
        cursor += timedelta(days=1)

    additions = dict.fromkeys(dates, 0)
    top_learned = []
    for word, state in learned.items():
        try:
            added_at = datetime.fromtimestamp(state.get("added_at"), tz=timezone.utc)
        except (TypeError, ValueError, OSError, OverflowError):
            added_at = None
        if added_at and start <= added_at <= end:
            additions[added_at.strftime("%Y-%m-%d")] += 1
        frequency = state.get("freq")
        if not isinstance(frequency, (int, float)) or isinstance(frequency, bool) or frequency < 0:
            continue
        weight = hotwords[word]
        weight = weight if isinstance(weight, (int, float)) and not isinstance(weight, bool) else 0
        top_learned.append({
            "word": word,
            "frequency": frequency,
            "addedAt": added_at.strftime("%Y-%m-%d") if added_at else None,
            "weight": weight,
        })
    top_learned.sort(key=lambda row: (-row["frequency"], row["word"]))

    usage_daily = {date: {"date": date, "committedCount": 0, "autoSubmitCount": 0} for date in dates}
    usage = {"voiceInputCount": 0, "committedCount": 0, "autoSubmitCount": 0}
    for event in events:
        if not isinstance(event, dict):
            continue
        timestamp = parse_iso(event.get("timestamp", ""))
        if timestamp is None or timestamp < start or timestamp > end:
            continue
        timestamp = timestamp.astimezone(timezone.utc)
        event_type = event.get("type")
        day = timestamp.strftime("%Y-%m-%d")
        if event_type == "voice_started":
            usage["voiceInputCount"] += 1
        elif event_type == "transcription_committed":
            usage["committedCount"] += 1
            usage_daily[day]["committedCount"] += 1
        elif event_type == "auto_submitted":
            usage["autoSubmitCount"] += 1
            usage_daily[day]["autoSubmitCount"] += 1

    total_count = len(hotwords)
    auto_learned_count = len(learned)
    voice_count = usage["voiceInputCount"]
    committed_count = usage["committedCount"]
    usage["commitRate"] = round(committed_count / voice_count * 100, 1) if voice_count else None
    usage["autoSubmitRate"] = round(usage["autoSubmitCount"] / committed_count * 100, 1) if committed_count else None
    usage["daily"] = list(usage_daily.values())
    return {
        "summary": {
            "totalCount": total_count,
            "autoLearnedCount": auto_learned_count,
            "manualCount": total_count - auto_learned_count,
            "autoLearnedShare": round(auto_learned_count / total_count * 100, 1) if total_count else None,
            "capacity": 400,
        },
        "learningDaily": [{"date": date, "addedCount": additions[date]} for date in dates],
        "learnedWords": sorted(learned),
        "topLearned": top_learned,
        "usage": usage,
    }


# ═══════════════════════════════════════════════════════
# HTTP 处理器
# ═══════════════════════════════════════════════════════

class WebHandler(http.server.BaseHTTPRequestHandler):
    stats_data_path: str = ""
    vocab_data_path: str = ""
    vocab_state_data_path: str = ""
    prompt_template_path: str = ""
    transcription_log_path: str = "/private/tmp/codex-voice-hotkey.log"
    icon_path: str = ""

    def do_GET(self):
        parsed = urlparse(self.path)
        raw_path = parsed.path
        path = raw_path.rstrip("/") or "/"
        params = parse_qs(parsed.query)

        if path == "/":
            self._send_html(LANDING_HTML)
        elif path in ("/icon.png", "/favicon.ico"):
            self._send_icon()
        elif path == "/vocab" or path.startswith("/vocab/"):
            if path == "/vocab/api/hotwords":
                self._send_vocab_data()
            elif path == "/vocab/api/insights":
                self._send_vocab_insights(params)
            elif path == "/vocab/api/prompt":
                self._send_prompt_template()
            elif path == "/vocab/api/corrections":
                self._send_corrections()
            elif path == "/vocab/api/recent-results":
                self._send_recent_results()
            else:
                self._send_html(VOCAB_HTML)
        elif path == "/stats" or path.startswith("/stats/"):
            if path == "/stats/api/data":
                self._send_stats_api(params)
            elif path == "/stats/api/heatmap":
                self._send_stats_heatmap(params)
            else:
                self._send_html(STATS_HTML)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        if path == "/vocab/api/hotwords":
            self._save_vocab_data()
        elif path == "/vocab/api/prompt":
            self._save_prompt_template()
        elif path == "/vocab/api/corrections":
            self._save_corrections()
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

    def _send_html(self, html: str):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(html.encode("utf-8"))

    def _send_vocab_data(self):
        vocab = self._load_vocab()
        body = json.dumps(vocab, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_prompt_template(self):
        try:
            template = Path(self.prompt_template_path).read_text(encoding="utf-8")
        except (FileNotFoundError, OSError, UnicodeDecodeError):
            template = DEFAULT_PROMPT_TEMPLATE
        self._send_json({"template": template})

    def _save_prompt_template(self):
        payload = self._read_json_body()
        template = payload.get("template")
        if not isinstance(template, str):
            self.send_error(400, "template must be a string")
            return
        self._write_text(self.prompt_template_path, template)
        self._send_json({"ok": True})

    def _send_corrections(self):
        corrections = self._load_vocab().get("corrections", {})
        if not isinstance(corrections, dict):
            corrections = {}
        self._send_json({"corrections": corrections})

    def _save_corrections(self):
        payload = self._read_json_body()
        corrections = payload.get("corrections", {})
        if not isinstance(corrections, dict) or any(
            not isinstance(source, str) or not isinstance(target, str)
            for source, target in corrections.items()
        ):
            self.send_error(400, "corrections must be a string map")
            return
        cleaned = {
            source.strip(): target.strip()
            for source, target in corrections.items()
            if source.strip() and target.strip()
        }
        vocabulary = self._load_vocab()
        vocabulary["corrections"] = cleaned
        self._write_json(self.vocab_data_path, vocabulary)
        self._send_json({"ok": True})

    def _send_recent_results(self):
        import re
        pattern = re.compile(r"收到最终转写：(.*)$")
        try:
            lines = Path(self.transcription_log_path).read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            lines = []
        results = []
        for line in reversed(lines):
            match = pattern.search(line)
            if match and match.group(1).strip() and match.group(1).strip() not in results:
                results.append(match.group(1).strip())
                if len(results) >= 30:
                    break
        self._send_json({"results": results})

    def _read_json_body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            payload = {}
        return payload if isinstance(payload, dict) else {}

    def _write_json(self, data_path: str, value: dict):
        self._write_text(data_path, json.dumps(value, ensure_ascii=False, indent=2))

    def _write_text(self, data_path: str, text: str):
        path = Path(data_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(text, encoding="utf-8")
        temporary.replace(path)

    def _send_json(self, value: dict):
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_vocab_insights(self, params: dict):
        date_range = parse_date_range(params.get("start", [None])[0], params.get("end", [None])[0])
        if date_range is None:
            body = b'{"error":"Invalid date range"}'
            self.send_response(400)
        else:
            body = json.dumps(build_vocab_insights(
                self._load_vocab(),
                load_json_object(self.vocab_state_data_path),
                load_events(self.stats_data_path),
                *date_range,
            ), ensure_ascii=False).encode("utf-8")
            self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _save_vocab_data(self):
        new_vocab = self._read_json_body()
        hotwords = new_vocab.get("hotwords")
        if not isinstance(hotwords, dict) or any(
            not isinstance(word, str) or not isinstance(weight, int) or isinstance(weight, bool)
            for word, weight in hotwords.items()
        ):
            self.send_error(400, "hotwords must be a string-to-integer map")
            return
        current = self._load_vocab()
        corrections = new_vocab.get("corrections", current.get("corrections", {}))
        if not isinstance(corrections, dict):
            corrections = {}
        self._write_json(self.vocab_data_path, {"hotwords": hotwords, "corrections": corrections})
        self._send_json({"ok": True})

    def _load_vocab(self) -> dict:
        path = Path(self.vocab_data_path)
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
        return {"hotwords": {}}

    def _send_stats_api(self, params: dict):
        events = load_events(self.stats_data_path)
        now = datetime.now(timezone.utc)
        start_str = params.get("start", [None])[0]
        end_str = params.get("end", [None])[0]
        start = parse_iso(start_str + "T00:00:00Z") if start_str else (now - timedelta(days=29)).replace(hour=0, minute=0, second=0, microsecond=0)
        end = parse_iso(end_str + "T23:59:59Z") if end_str else now
        daily = daily_summaries(events, start, end)
        summary = total_summary(events, start, end)
        response = {"daily": daily, "summary": summary}
        body = json.dumps(response, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_stats_heatmap(self, params: dict):
        events = load_events(self.stats_data_path)
        now = datetime.now(timezone.utc)
        year_str = params.get("year", [None])[0]
        year = int(year_str) if year_str else now.year
        start = datetime(year, 1, 1, tzinfo=timezone.utc)
        end = datetime(year, 12, 31, tzinfo=timezone.utc)
        daily_chars: dict[str, int] = {}
        for ev in events:
            ts = parse_iso(ev.get("timestamp", ""))
            if ts is None or ts < start or ts > end:
                continue
            if ev.get("type") == "transcription_committed":
                ts = ts.astimezone(timezone.utc)
                day = ts.strftime("%Y-%m-%d")
                daily_chars[day] = daily_chars.get(day, 0) + ev.get("characterCount", 0)
        heatmap_data = []
        max_val = 0
        cursor = start.date()
        end_date = end.date()
        while cursor <= end_date:
            cursor_str = cursor.strftime("%Y-%m-%d")
            val = daily_chars.get(cursor_str, 0)
            if val > max_val:
                max_val = val
            heatmap_data.append([cursor_str, val])
            cursor += timedelta(days=1)
        body = json.dumps({"data": heatmap_data, "max": max_val}, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


# ═══════════════════════════════════════════════════════
# 启动
# ═══════════════════════════════════════════════════════

def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description="cliMC 统一 Web 服务器")
    parser.add_argument("--port", type=int, default=0, help="端口号（0=自动分配）")
    parser.add_argument("--stats-data", type=str, default="", help="usage-events.jsonl 路径")
    parser.add_argument("--vocab-data", type=str, default="", help="vocabulary.json 路径")
    parser.add_argument("--vocab-state-data", type=str, default="", help="vocab-learner-state.json 路径")
    parser.add_argument("--prompt-template-data", type=str, default="", help="提示词模板保存路径")
    parser.add_argument("--transcription-log", type=str, default="", help="最终识别文本日志路径")
    parser.add_argument("--icon", type=str, default="", help="cliMC.png 路径")
    args = parser.parse_args()

    port = args.port or find_free_port()
    stats_data_path = args.stats_data
    vocab_data_path = args.vocab_data
    vocab_state_data_path = args.vocab_state_data
    prompt_template_path = args.prompt_template_data
    transcription_log_path = args.transcription_log or "/private/tmp/codex-voice-hotkey.log"
    icon_path = args.icon

    if not icon_path:
        script_dir = Path(__file__).parent
        candidate = script_dir / "cliMC.png"
        if candidate.exists():
            icon_path = str(candidate)

    if not stats_data_path:
        stats_data_path = str(Path.home() / "Library/Application Support/cliMC/usage-events.jsonl")
    if not vocab_data_path:
        vocab_data_path = str(Path.home() / ".config/codex-voice/vocabulary.json")
    if not vocab_state_data_path:
        vocab_state_data_path = str(Path.home() / ".config/codex-voice/vocab-learner-state.json")
    if not prompt_template_path:
        prompt_template_path = str(Path.home() / ".config/codex-voice/prompt-template.txt")

    WebHandler.stats_data_path = stats_data_path
    WebHandler.vocab_data_path = vocab_data_path
    WebHandler.vocab_state_data_path = vocab_state_data_path
    WebHandler.prompt_template_path = prompt_template_path
    WebHandler.transcription_log_path = transcription_log_path
    WebHandler.icon_path = icon_path

    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), WebHandler)
    print(port, flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
