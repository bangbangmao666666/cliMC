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

VOCAB_HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>cliMC 自定义热词</title>
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
.insights { margin-bottom: 24px; }
.insights h2 { color: #f0f6fc; font-size: 18px; margin-bottom: 4px; }
.insights > p, .insight-section > p { color: #8b949e; font-size: 12px; line-height: 1.6; margin: 6px 0 12px; }
.insight-controls { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin: 12px 0; }
.insight-controls input[type=date], .insight-controls button { background: #161b22; color: #c9d1d9; border: 1px solid #30363d; border-radius: 6px; font-size: 13px; padding: 6px 10px; }
.insight-controls button { cursor: pointer; }
.insight-controls button:hover { border-color: #58a6ff; }
.insight-controls .primary { background: #238636; border-color: #2ea043; color: #fff; }
.insight-cards { display: grid; grid-template-columns: repeat(5, 1fr); gap: 8px; margin-bottom: 16px; }
.insight-card { background: #161b22; border: 1px solid #21262d; border-radius: 8px; padding: 12px; text-align: center; }
.insight-card .value { color: #58a6ff; font-size: 20px; font-weight: 700; }
.insight-card:nth-child(2) .value, .insight-card:nth-child(4) .value { color: #7ee787; }
.insight-card:nth-child(3) .value, .insight-card:nth-child(5) .value { color: #d2a8ff; }
.insight-card .label { color: #8b949e; font-size: 11px; margin-top: 4px; }
.insight-section { margin-top: 20px; }
.chart { width: 100%; height: 240px; background: #161b22; border: 1px solid #21262d; border-radius: 8px; }
.chart-message { align-items: center; color: #8b949e; display: flex; font-size: 13px; justify-content: center; padding: 16px; text-align: center; }
.insight-status { color: #8b949e; font-size: 12px; min-height: 18px; margin: 8px 0; }
.insight-status.error { color: #f85149; }
.table-wrap { overflow-x: auto; background: #161b22; border: 1px solid #21262d; border-radius: 8px; }
.learned-table { border-collapse: collapse; min-width: 480px; width: 100%; font-size: 13px; }
.learned-table th, .learned-table td { border-bottom: 1px solid #21262d; padding: 10px 12px; text-align: left; }
.learned-table th { color: #8b949e; font-size: 11px; font-weight: 500; }
.learned-table tr:last-child td { border-bottom: 0; }
.source-badge { background: #d2a8ff; border-radius: 10px; color: #0d1117; font-size: 10px; margin-left: 6px; padding: 2px 6px; white-space: nowrap; }
.insight-note { background: #161b22; border-left: 3px solid #58a6ff; color: #8b949e; font-size: 12px; line-height: 1.7; margin-top: 16px; padding: 10px 12px; }
@media (max-width: 600px) { .insight-cards { grid-template-columns: 1fr; } .table-wrap { overflow-x: auto; } }
</style>
</head>
<body>
<div class="container">
  <a href="/" class="back">← 返回首页</a>
   <div class="header">
    <img src="/icon.png" class="logo">
    <div>
      <h1>自定义热词</h1>
      <p>添加后，火山引擎 ASR 会优先识别这些词汇</p>
     </div>
   </div>
   <section class="insights">
     <h2>词表成效</h2>
     <p>查看词表构成、自动学习和同期使用表现。</p>
     <div class="insight-controls">
       <input type="date" id="insightStartDate" aria-label="开始日期">
       <span>至</span><input type="date" id="insightEndDate" aria-label="结束日期">
       <button onclick="quickInsights(1)">今天</button>
       <button onclick="quickInsights(7)">7 天</button>
       <button onclick="quickInsights(30)">30 天</button>
       <button class="primary" onclick="fetchInsights()">刷新</button>
      </div>
      <div class="insight-cards" id="insightCards"></div>
      <p class="insight-status" id="insightStatus" aria-live="polite"></p>
     <div class="insight-section">
       <p>每日自动学习新增</p><div class="chart" id="learningChart"></div>
     </div>
     <div class="insight-section">
       <p>自动学习词排名</p>
       <div class="table-wrap"><table class="learned-table"><thead><tr><th>词汇</th><th>频次</th><th>首次加入</th><th>权重</th></tr></thead><tbody id="topLearned"></tbody></table></div>
     </div>
     <div class="insight-section">
       <p>同期使用表现</p><div class="insight-cards" id="usageCards"></div><div class="chart" id="usageChart"></div>
     </div>
     <div class="insight-note">自动学习基于最终转写，仅适用于火山引擎 ASR。同期使用表现仅提供使用上下文，不代表热词单独带来的提升。</div>
   </section>
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
let insights = { topLearned: [] };
let learningChart = null;
let usageChart = null;
function setInsightStatus(message, isError) {
  const status = document.getElementById('insightStatus');
  status.textContent = message || '';
  status.className = 'insight-status' + (isError ? ' error' : '');
}
function setChartMessage(id, message) {
  const chart = document.getElementById(id);
  chart.replaceChildren();
  const text = document.createElement('div');
  text.className = 'chart-message';
  text.textContent = message;
  chart.appendChild(text);
}
function initInsightCharts() {
  if (!window.echarts) {
    setChartMessage('learningChart', '图表不可用：ECharts 未加载，仍可查看和编辑词表。');
    setChartMessage('usageChart', '图表不可用：ECharts 未加载，仍可查看和编辑词表。');
    return;
  }
  try {
    learningChart = window.echarts.init(document.getElementById('learningChart'), 'dark');
    usageChart = window.echarts.init(document.getElementById('usageChart'), 'dark');
  } catch (error) {
    learningChart = null;
    usageChart = null;
    setChartMessage('learningChart', '图表不可用：ECharts 初始化失败，仍可查看和编辑词表。');
    setChartMessage('usageChart', '图表不可用：ECharts 初始化失败，仍可查看和编辑词表。');
  }
}
function localDateStr(date) {
  return date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' + String(date.getDate()).padStart(2, '0');
}
function todayStr() { return localDateStr(new Date()); }
function initInsightDates() {
  const end = todayStr();
  const start = new Date(); start.setDate(start.getDate() - 29);
  document.getElementById('insightStartDate').value = localDateStr(start);
  document.getElementById('insightEndDate').value = end;
}
function quickInsights(days) {
  const end = todayStr(); const start = new Date(); start.setDate(start.getDate() - days + 1);
  document.getElementById('insightStartDate').value = localDateStr(start);
  document.getElementById('insightEndDate').value = end; fetchInsights();
}
function fetchInsights() {
  const start = document.getElementById('insightStartDate').value;
  const end = document.getElementById('insightEndDate').value;
  setInsightStatus('成效数据加载中…');
  fetch('/vocab/api/insights?start=' + start + '&end=' + end).then(r => {
    if (!r.ok) throw new Error('HTTP ' + r.status); return r.json();
  }).then(result => {
    insights = result; renderInsightCards(result.summary); renderLearningChart(result.learningDaily);
    renderTopLearned(result.topLearned); renderUsage(result.usage); render();
    const isEmpty = !result.summary.totalCount && !result.topLearned.length && !result.usage.voiceInputCount;
    setInsightStatus(isEmpty ? '暂无成效数据' : '');
  }).catch(err => setInsightStatus('成效加载失败: ' + err + '。请重试。', true));
}
function renderCards(id, cards) {
  const container = document.getElementById(id);
  container.replaceChildren();
  cards.forEach(card => {
    const element = document.createElement('div'); element.className = 'insight-card';
    const value = document.createElement('div'); value.className = 'value'; value.textContent = card[1];
    const label = document.createElement('div'); label.className = 'label'; label.textContent = card[0];
    element.append(value, label); container.appendChild(element);
  });
}
function renderInsightCards(summary) {
  const cards = [['当前词汇', summary.totalCount], ['自动学习', summary.autoLearnedCount], ['手动添加', summary.manualCount], ['自动占比', summary.autoLearnedShare == null ? '--' : summary.autoLearnedShare + '%'], ['容量', summary.capacity]];
  renderCards('insightCards', cards);
}
function chartOption(daily, series, colors) {
  return { tooltip: { trigger: 'axis' }, legend: { data: series.map(s => s.name), textStyle: { color: '#8b949e' } }, grid: { left: 45, right: 20, top: 35, bottom: 30 }, xAxis: { type: 'category', data: daily.map(row => row.date.slice(5)), axisLabel: { color: '#8b949e' }, axisLine: { lineStyle: { color: '#21262d' } } }, yAxis: { type: 'value', minInterval: 1, axisLabel: { color: '#8b949e' }, splitLine: { lineStyle: { color: '#21262d' } } }, series: series.map((s, i) => ({ name: s.name, type: s.type || 'line', data: daily.map(s.value), itemStyle: { color: colors[i] } })) };
}
function renderLearningChart(daily) { if (learningChart) { learningChart.setOption(chartOption(daily, [{ name: '新增词汇', type: 'bar', value: row => row.addedCount }], ['#7ee787']), true); learningChart.resize(); } }
function renderTopLearned(rows) {
  const body = document.getElementById('topLearned'); body.replaceChildren();
  if (!rows.length) {
    const row = document.createElement("tr"); const cell = document.createElement('td');
    cell.colSpan = 4; cell.className = 'empty'; cell.textContent = '暂无自动学习词汇'; row.appendChild(cell); body.appendChild(row); return;
  }
  rows.forEach(item => {
    const row = document.createElement("tr");
    [item.word, item.frequency, item.addedAt || '--', item.weight].forEach(value => {
      const cell = document.createElement('td'); cell.textContent = value; row.appendChild(cell);
    });
    body.appendChild(row);
  });
}
function renderUsage(usage) {
  const cards = [['语音开始', usage.voiceInputCount], ['最终提交', usage.committedCount], ['自动提交', usage.autoSubmitCount], ['提交率', usage.commitRate == null ? '--' : usage.commitRate + '%'], ['自动提交率', usage.autoSubmitRate == null ? '--' : usage.autoSubmitRate + '%']];
  renderCards('usageCards', cards);
  if (usageChart) { usageChart.setOption(chartOption(usage.daily, [{ name: '最终提交', value: row => row.committedCount }, { name: '自动提交', value: row => row.autoSubmitCount }], ['#58a6ff', '#d2a8ff']), true); usageChart.resize(); }
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
  const learnedWords = new Set(insights.topLearned.map(row => row.word));
  filtered.forEach(([word, weight]) => {
    const row = document.createElement('div'); row.className = 'row';
    const wordCell = document.createElement('div'); wordCell.className = 'word';
    const wordInput = document.createElement("input"); wordInput.type = 'text'; wordInput.value = word;
    wordInput.dataset.word = word;
    wordInput.addEventListener("input", () => update(wordInput, getWeight(wordInput)));
    wordInput.addEventListener('keydown', onKey); wordCell.appendChild(wordInput);
    if (learnedWords.has(word)) { const badge = document.createElement('span'); badge.className = 'source-badge'; badge.textContent = '自动学习'; wordCell.appendChild(badge); }
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
  if ((e.metaKey || e.ctrlKey) && e.key === 's') { e.preventDefault(); save(); }
});
window.addEventListener('beforeunload', e => { if (dirty) { e.preventDefault(); e.returnValue = ''; } });
window.addEventListener('resize', () => { if (learningChart) learningChart.resize(); if (usageChart) usageChart.resize(); });
initInsightDates(); initInsightCharts(); load(); fetchInsights();
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
@media (max-width: 600px) { .cards { grid-template-columns: repeat(1, 1fr); } }
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
      const activeDays = data.daily.filter(d => d.voiceInputCount || d.characterCount || d.autoSubmitCount).length;
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
  chart.setOption({
    tooltip: { trigger: 'axis', backgroundColor: '#1c2128', borderColor: '#30363d', textStyle: { color: '#c9d1d9', fontSize: 13 } },
    legend: { data: ['语音输入', '生成字数', '自动提交'], textStyle: { color: '#8b949e' }, top: 8 },
    grid: { left: 50, right: 70, top: 50, bottom: 30 },
    xAxis: { type: 'category', data: dates, axisLine: { lineStyle: { color: '#21262d' } }, axisLabel: { color: '#8b949e', fontSize: 11 }, splitLine: { show: false } },
    yAxis: [{ type: 'value', name: '次数', position: 'left', axisLine: { show: false }, axisLabel: { color: '#8b949e', fontSize: 11 }, splitLine: { lineStyle: { color: '#21262d', type: 'dashed' } } }, { type: 'value', name: '字数', position: 'right', axisLine: { show: false }, axisLabel: { color: '#8b949e', fontSize: 11 }, splitLine: { show: false } }],
    series: [{ name: '语音输入', type: 'line', yAxisIndex: 0, smooth: true, data: voiceInput, itemStyle: { color: '#79c0ff' }, lineStyle: { width: 3 }, symbol: 'circle', symbolSize: 6, areaStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: 'rgba(121, 192, 255, 0.3)' }, { offset: 1, color: 'rgba(121, 192, 255, 0.02)' }]) }, animationDuration: 400, animationEasing: 'cubicOut' }, { name: '生成字数', type: 'line', yAxisIndex: 1, smooth: true, data: characterCount, itemStyle: { color: '#7ee787' }, lineStyle: { width: 3 }, symbol: 'circle', symbolSize: 6, areaStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [{ offset: 0, color: 'rgba(126, 231, 135, 0.25)' }, { offset: 1, color: 'rgba(126, 231, 135, 0.01)' }]) }, animationDuration: 400 }, { name: '自动提交', type: 'line', yAxisIndex: 0, smooth: true, data: autoSubmit, itemStyle: { color: '#d2a8ff' }, lineStyle: { width: 3, type: 'dashed' }, symbol: 'circle', symbolSize: 6, animationDuration: 400 }]
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
            daily[day] = {"date": day, "voiceInputCount": 0, "characterCount": 0, "autoSubmitCount": 0}
        event_type = ev.get("type", "")
        if event_type == "voice_started":
            daily[day]["voiceInputCount"] += 1
        elif event_type == "transcription_committed":
            daily[day]["characterCount"] += ev.get("characterCount", 0)
        elif event_type == "auto_submitted":
            daily[day]["autoSubmitCount"] += 1
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
                filled.append({"date": cursor_str, "voiceInputCount": 0, "characterCount": 0, "autoSubmitCount": 0})
            cursor += timedelta(days=1)
        result = filled
    return result


def total_summary(events: list[dict], start: datetime, end: datetime) -> dict:
    total = {"voiceInputCount": 0, "characterCount": 0, "autoSubmitCount": 0}
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
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        new_vocab = json.loads(body)
        with open(self.vocab_data_path, "w", encoding="utf-8") as f:
            json.dump(new_vocab, f, ensure_ascii=False, indent=2)
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

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
    parser.add_argument("--icon", type=str, default="", help="cliMC.png 路径")
    args = parser.parse_args()

    port = args.port or find_free_port()
    stats_data_path = args.stats_data
    vocab_data_path = args.vocab_data
    vocab_state_data_path = args.vocab_state_data
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

    WebHandler.stats_data_path = stats_data_path
    WebHandler.vocab_data_path = vocab_data_path
    WebHandler.vocab_state_data_path = vocab_state_data_path
    WebHandler.icon_path = icon_path

    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), WebHandler)
    print(port, flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
