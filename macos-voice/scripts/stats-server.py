#!/usr/bin/env python3
"""cliMC 使用统计 Web 服务器

启动一个本地 HTTP 服务器，提供 ECharts 交互式仪表盘。
用法: python3 stats-server.py --port 0 --data /path/to/usage-events.jsonl
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


# ── 数据层 ──────────────────────────────────────────

def load_events(data_path: str) -> list[dict]:
    """读取 JSONL 文件，返回事件列表。"""
    events: list[dict] = []
    path = Path(data_path)
    if path.exists():
        for line in path.read_text(encoding="utf-8").strip().split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def parse_iso(s: str) -> datetime | None:
    """解析 ISO 8601 日期时间字符串。"""
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def daily_summaries(events: list[dict], start: datetime, end: datetime) -> list[dict]:
    """按天聚合事件数据。"""
    daily: dict[str, dict] = {}
    for ev in events:
        ts = parse_iso(ev.get("timestamp", ""))
        if ts is None or ts < start or ts > end:
            continue
        day = ts.strftime("%Y-%m-%d")
        if day not in daily:
            daily[day] = {
                "date": day,
                "voiceInputCount": 0,
                "characterCount": 0,
                "autoSubmitCount": 0,
            }
        event_type = ev.get("type", "")
        if event_type == "voice_started":
            daily[day]["voiceInputCount"] += 1
        elif event_type == "transcription_committed":
            daily[day]["characterCount"] += ev.get("characterCount", 0)
        elif event_type == "auto_submitted":
            daily[day]["autoSubmitCount"] += 1

    # 按日期排序
    result = sorted(daily.values(), key=lambda x: x["date"])

    # 填充无数据的日期（让图表连续）
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
                filled.append({
                    "date": cursor_str,
                    "voiceInputCount": 0,
                    "characterCount": 0,
                    "autoSubmitCount": 0,
                })
            cursor += timedelta(days=1)
        result = filled

    return result


def total_summary(events: list[dict], start: datetime, end: datetime) -> dict:
    """统计时间范围内的汇总。"""
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


# ── Mock 数据（已禁用）─────────────────────────
# 以下 mock 数据生成代码已注释，使用真实数据。
# MOCK_EVENTS: list[dict] = []
# ...


# ── HTML 仪表盘 ─────────────────────────────────────

HTML = r"""<!DOCTYPE html>
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

/* 顶部 */
.header {
  display: flex; justify-content: space-between; align-items: center;
  margin-bottom: 24px; flex-wrap: wrap; gap: 12px;
}
.header h1 { font-size: 22px; font-weight: 600; color: #f0f6fc; }
.header p { font-size: 13px; color: #8b949e; margin-top: 4px; }
.logo { width: 36px; height: 36px; border-radius: 8px; flex-shrink: 0; }
.controls {
  display: flex; align-items: center; gap: 8px; flex-wrap: wrap;
}
.controls label { font-size: 13px; color: #8b949e; }
.controls input[type=date] {
  background: #161b22; color: #c9d1d9; border: 1px solid #30363d;
  padding: 6px 10px; border-radius: 6px; font-size: 13px;
  outline: none;
}
.controls input[type=date]:focus { border-color: #58a6ff; }
.controls select {
  background: #161b22; color: #c9d1d9; border: 1px solid #30363d;
  padding: 6px 10px; border-radius: 6px; font-size: 13px; outline: none;
}
.controls select:focus { border-color: #58a6ff; }
.controls button {
  background: #21262d; color: #c9d1d9; border: 1px solid #30363d;
  padding: 6px 14px; border-radius: 6px; font-size: 13px; cursor: pointer;
  transition: background 0.15s;
}
.controls button:hover { background: #30363d; }
.controls button.primary { background: #238636; border-color: #2ea043; color: #fff; }
.controls button.primary:hover { background: #2ea043; }
.sep { color: #30363d; font-size: 13px; }

/* 汇总卡片 */
.cards-header {
  font-size: 13px; color: #8b949e; margin-bottom: 10px;
}
.cards {
  display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px;
  margin-bottom: 20px;
}
@media (max-width: 600px) { .cards { grid-template-columns: repeat(1, 1fr); } }
.card {
  background: #161b22; border-radius: 10px; padding: 16px;
  text-align: center; border: 1px solid #21262d;
}
.card .val { font-size: 28px; font-weight: 700; line-height: 1.2; }
.card .lbl { font-size: 12px; color: #8b949e; margin-top: 4px; }
.c0 .val { color: #79c0ff; }
.c1 .val { color: #7ee787; }
.c2 .val { color: #d2a8ff; }

/* 图表 */
#chart {
  width: 100%; height: 480px;
  background: #161b22; border-radius: 10px; border: 1px solid #21262d;
}
#heatmap {
  width: 100%; height: 220px;
  background: #161b22; border-radius: 10px; border: 1px solid #21262d;
  margin-top: 16px;
}

/* 底部信息 */
.footer { text-align: center; margin-top: 12px; color: #484f58; font-size: 12px; }
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <div style="display:flex;align-items:center;gap:12px;">
      <img src="/icon.png" class="logo">
      <div>
        <h1>cliMC 使用统计</h1>
        <p>下方卡片为所选日期范围的合计</p>
      </div>
    </div>
    <div class="controls">
      <label>从</label>
      <input type="date" id="startDate">
      <span class="sep">—</span>
      <label>到</label>
      <input type="date" id="endDate">
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

// 设置默认日期范围（最近 30 天）
(function initDates() {
  const now = new Date();
  const end = now.toISOString().split('T')[0];
  const start = new Date(now.getTime() - 29 * 86400000).toISOString().split('T')[0];
  document.getElementById('startDate').value = start;
  document.getElementById('endDate').value = end;
  fetchData();
  fetchHeatmap();
})();

function todayStr() { return new Date().toISOString().split('T')[0]; }

function quick(days) {
  const end = todayStr();
  const d = new Date();
  d.setDate(d.getDate() - days + 1);
  document.getElementById('startDate').value = d.toISOString().split('T')[0];
  document.getElementById('endDate').value = end;
  fetchData();
}

function fetchData() {
  const start = document.getElementById('startDate').value;
  const end = document.getElementById('endDate').value;

  fetch('/api/data?start=' + start + '&end=' + end)
    .then(r => r.json())
    .then(data => {
      updateCards(data.summary);
      updateChart(data.daily, start, end);
      const activeDays = data.daily.filter(d => d.voiceInputCount || d.characterCount || d.autoSubmitCount).length;
      document.getElementById('footer').textContent =
        '数据范围: ' + start + ' ~ ' + end + ' | ' + activeDays + ' 天有活动';
    })
    .catch(err => {
      document.getElementById('footer').textContent = '加载失败: ' + err;
    });
}

function fetchHeatmap() {
  const year = new Date().getFullYear();
  fetch('/api/heatmap?year=' + year)
    .then(r => r.json())
    .then(data => updateHeatmap(data, year))
    .catch(() => {});
}

function updateCards(summary) {
  const labels = ['语音输入', '生成字数', '自动提交'];
  const keys = ['voiceInputCount', 'characterCount', 'autoSubmitCount'];
  const html = keys.map((k, i) =>
    '<div class="card c' + i + '">' +
      '<div class="val">' + (summary[k] || 0).toLocaleString() + '</div>' +
      '<div class="lbl">' + labels[i] + '</div>' +
    '</div>'
  ).join('');
  document.getElementById('cards').innerHTML = html;
}

function updateChart(daily, start, end) {
  const dates = daily.map(d => d.date.slice(5));  // MM-DD
  const voiceInput = daily.map(d => d.voiceInputCount || 0);
  const characterCount = daily.map(d => d.characterCount || 0);
  const autoSubmit = daily.map(d => d.autoSubmitCount || 0);

  chart.setOption({
    tooltip: {
      trigger: 'axis',
      backgroundColor: '#1c2128',
      borderColor: '#30363d',
      textStyle: { color: '#c9d1d9', fontSize: 13 }
    },
    legend: {
      data: ['语音输入', '生成字数', '自动提交'],
      textStyle: { color: '#8b949e' },
      top: 8
    },
    grid: { left: 50, right: 70, top: 50, bottom: 30 },
    xAxis: {
      type: 'category', data: dates,
      axisLine: { lineStyle: { color: '#21262d' } },
      axisLabel: { color: '#8b949e', fontSize: 11 },
      splitLine: { show: false }
    },
    yAxis: [
      {
        type: 'value', name: '次数',
        min: 0,
        position: 'left',
        axisLine: { show: false },
        axisLabel: { color: '#8b949e', fontSize: 11 },
        splitLine: { lineStyle: { color: '#21262d', type: 'dashed' } }
      },
      {
        type: 'value', name: '字数',
        min: 0,
        position: 'right',
        axisLine: { show: false },
        axisLabel: { color: '#8b949e', fontSize: 11 },
        splitLine: { show: false }
      }
    ],
    series: [
      {
        name: '语音输入',
        type: 'line',
        yAxisIndex: 0,
        smooth: true,
        data: voiceInput,
        itemStyle: { color: '#79c0ff' },
        lineStyle: { width: 3 },
        symbol: 'circle',
        symbolSize: 6,
        areaStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
          { offset: 0, color: 'rgba(121, 192, 255, 0.3)' },
          { offset: 1, color: 'rgba(121, 192, 255, 0.02)' }
        ])},
        animationDuration: 400,
        animationEasing: 'cubicOut'
      },
      {
        name: '生成字数',
        type: 'line',
        yAxisIndex: 1,
        smooth: true,
        data: characterCount,
        itemStyle: { color: '#7ee787' },
        lineStyle: { width: 3 },
        symbol: 'circle',
        symbolSize: 6,
        areaStyle: { color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
          { offset: 0, color: 'rgba(126, 231, 135, 0.25)' },
          { offset: 1, color: 'rgba(126, 231, 135, 0.01)' }
        ])},
        animationDuration: 400
      },
      {
        name: '自动提交',
        type: 'line',
        yAxisIndex: 0,
        smooth: true,
        data: autoSubmit,
        itemStyle: { color: '#d2a8ff' },
        lineStyle: { width: 3, type: 'dashed' },
        symbol: 'circle',
        symbolSize: 6,
        animationDuration: 400
      }
    ]
  }, true);
  chart.resize();
}

function updateHeatmap(data, year) {
  var maxVal = data.max || 1;
  // 5 级颜色：从浅到深绿色（类 GitHub 风格）
  var colors = ['#0e4429', '#006d32', '#26a641', '#39d353'];
  // 0 值用更淡的背景色
  var pieces = [
    { min: 1, max: Math.ceil(maxVal * 0.25), color: '#0e4429' },
    { min: Math.ceil(maxVal * 0.25) + 1, max: Math.ceil(maxVal * 0.5), color: '#006d32' },
    { min: Math.ceil(maxVal * 0.5) + 1, max: Math.ceil(maxVal * 0.75), color: '#26a641' },
    { min: Math.ceil(maxVal * 0.75) + 1, max: maxVal, color: '#39d353' }
  ];

  heatmap.setOption({
    tooltip: {
      position: 'top',
      formatter: function(p) {
        var val = p.data ? p.data[1] || 0 : 0;
        return p.data[0] + '<br/>生成字数: ' + val.toLocaleString();
      },
      backgroundColor: '#1c2128',
      borderColor: '#30363d',
      textStyle: { color: '#c9d1d9', fontSize: 12 }
    },
    visualMap: {
      min: 0, max: maxVal,
      calculable: true,
      orient: 'horizontal',
      left: 'center', top: 0,
      inRange: { color: ['#161b22', '#0e4429', '#006d32', '#26a641', '#39d353'] },
      textStyle: { color: '#8b949e', fontSize: 11 }
    },
    calendar: {
      top: 40, left: 10, right: 10, bottom: 10,
      range: year,
      cellSize: ['auto', 14],
      splitLine: { lineStyle: { color: '#0d1117', width: 2 } },
      yearLabel: { show: false },
      dayLabel: {
        nameMap: ['日', '一', '二', '三', '四', '五', '六'],
        textStyle: { color: '#8b949e', fontSize: 10 }
      },
      monthLabel: {
        nameMap: 'ZH',
        textStyle: { color: '#8b949e', fontSize: 11 }
      },
      itemStyle: {
        color: '#161b22',
        borderWidth: 1,
        borderColor: '#0d1117',
        borderRadius: 2
      }
    },
    series: [{
      type: 'heatmap',
      coordinateSystem: 'calendar',
      data: data.data,
      animation: false
    }]
  }, true);
  heatmap.resize();
}

// 窗口大小变化时 resize
window.addEventListener('resize', () => {
  chart.resize();
  heatmap.resize();
});
</script>
</body>
</html>"""


# ── HTTP 服务器 ──────────────────────────────────────

class StatsHandler(http.server.BaseHTTPRequestHandler):
    """处理 API 和静态文件请求。"""

    data_path: str = ""
    icon_path: str = ""

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        if path == "/":
            self._send_html()
        elif path in ("/icon.png", "/favicon.ico"):
            self._send_icon()
        elif path == "/api/data":
            self._send_api(params)
        elif path == "/api/heatmap":
            self._send_heatmap(params)
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

    def _send_api(self, params: dict):
        events = load_events(self.data_path)
        now = datetime.now(timezone.utc)

        # 解析日期参数
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

    def _send_heatmap(self, params: dict):
        events = load_events(self.data_path)
        now = datetime.now(timezone.utc)

        year_str = params.get("year", [None])[0]
        if year_str:
            year = int(year_str)
        else:
            year = now.year

        # 全年每日生成字数
        start = datetime(year, 1, 1, tzinfo=timezone.utc)
        end = datetime(year, 12, 31, tzinfo=timezone.utc)

        daily_chars: dict[str, int] = {}
        for ev in events:
            ts = parse_iso(ev.get("timestamp", ""))
            if ts is None or ts < start or ts > end:
                continue
            if ev.get("type") == "transcription_committed":
                day = ts.strftime("%Y-%m-%d")
                daily_chars[day] = daily_chars.get(day, 0) + ev.get("characterCount", 0)

        # 转为 [[date, value], ...] 格式，包含全年每一天
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
        # 安静运行，不打印日志
        pass


def find_free_port() -> int:
    """找可用端口。"""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description="cliMC 使用统计服务器")
    parser.add_argument("--port", type=int, default=0, help="端口号（0=自动分配）")
    parser.add_argument("--data", type=str, default="", help="usage-events.jsonl 路径")
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
        data_path = str(Path.home() / "Library/Application Support/cliMC/usage-events.jsonl")

    StatsHandler.data_path = data_path
    StatsHandler.icon_path = icon_path

    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), StatsHandler)

    # 第一行输出端口号，供父进程读取
    print(port, flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
