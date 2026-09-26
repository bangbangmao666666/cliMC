import importlib.util
import json
import threading
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest


SCRIPT_PATH = Path(__file__).parents[1] / "scripts" / "web-server.py"
SPEC = importlib.util.spec_from_file_location("web_server", SCRIPT_PATH)
web_server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(web_server)


@pytest.fixture
def server(tmp_path):
    vocabulary_path = tmp_path / "vocabulary.json"
    state_path = tmp_path / "vocab-learner-state.json"
    events_path = tmp_path / "usage-events.jsonl"
    vocabulary_path.write_text(json.dumps({"hotwords": {"ffmpeg": 10}}), encoding="utf-8")
    state_path.write_text(json.dumps({"ffmpeg": {"freq": 10, "added_at": 1785828642}}), encoding="utf-8")
    events_path.write_text('{"timestamp":"2026-08-04T08:00:00Z","type":"voice_started"}\n', encoding="utf-8")

    web_server.WebHandler.stats_data_path = str(events_path)
    web_server.WebHandler.vocab_data_path = str(vocabulary_path)
    web_server.WebHandler.vocab_state_data_path = str(state_path)
    httpd = web_server.http.server.ThreadingHTTPServer(("127.0.0.1", 0), web_server.WebHandler)
    thread = threading.Thread(target=httpd.serve_forever)
    thread.start()

    try:
        yield type("Server", (), {"url": f"http://127.0.0.1:{httpd.server_port}"})()
    finally:
        httpd.shutdown()
        thread.join()
        httpd.server_close()


def test_build_vocab_insights_classifies_words_and_calculates_rates():
    vocabulary = {"hotwords": {"ffmpeg": 10, "解释代码": 7, "待提交": 7}}
    learner_state = {
        "解释代码": {"freq": 110, "added_at": 1785828642},
        "待提交": {"freq": 44, "added_at": 1785828642},
    }
    events = [
        {"timestamp": "2026-08-04T08:00:00Z", "type": "voice_started"},
        {"timestamp": "2026-08-04T08:00:03Z", "type": "transcription_committed", "characterCount": 8},
        {"timestamp": "2026-08-04T08:00:06Z", "type": "auto_submitted"},
    ]

    result = web_server.build_vocab_insights(
        vocabulary, learner_state, events,
        datetime(2026, 8, 4, tzinfo=timezone.utc),
        datetime(2026, 8, 4, 23, 59, 59, tzinfo=timezone.utc),
    )

    assert result["summary"] == {
        "totalCount": 3,
        "autoLearnedCount": 2,
        "manualCount": 1,
        "autoLearnedShare": 66.7,
        "capacity": 400,
    }
    assert [row["word"] for row in result["topLearned"]] == ["解释代码", "待提交"]
    assert result["usage"]["commitRate"] == 100.0
    assert result["usage"]["autoSubmitRate"] == 100.0


def test_insights_endpoint_returns_json_for_valid_range(server):
    response = urlopen(server.url + "/vocab/api/insights?start=2026-08-04&end=2026-08-04")
    body = json.load(response)

    assert response.status == 200
    assert body["summary"]["capacity"] == 400
    assert "usage" in body


def test_insights_endpoint_rejects_invalid_range(server):
    with pytest.raises(HTTPError) as error:
        urlopen(server.url + "/vocab/api/insights?start=invalid&end=2026-08-04")

    assert error.value.code == 400


def test_missing_or_malformed_state_is_empty(tmp_path):
    missing = tmp_path / "missing.json"
    malformed = tmp_path / "malformed.json"
    malformed.write_text("{not-json", encoding="utf-8")

    assert web_server.load_json_object(str(missing)) == {}
    assert web_server.load_json_object(str(malformed)) == {}


def test_build_vocab_insights_ignores_malformed_data():
    start = datetime(2026, 8, 4, tzinfo=timezone.utc)
    end = datetime(2026, 8, 4, 23, 59, 59, tzinfo=timezone.utc)

    assert web_server.build_vocab_insights([], [], [None], start, end)["summary"]["totalCount"] == 0

    result = web_server.build_vocab_insights(
        {"hotwords": {"bad": "heavy", "valid": 7}},
        {"bad": {"freq": "often", "added_at": "never"}, "valid": "invalid"},
        [None, "invalid", {"timestamp": "2026-08-04T08:00:00", "type": "voice_started"}],
        start,
        end,
    )

    assert result["summary"]["autoLearnedCount"] == 1
    assert result["topLearned"] == []
    assert result["usage"]["voiceInputCount"] == 0


def test_build_vocab_insights_excludes_invalid_learner_frequencies_from_rankings():
    start = datetime(2026, 8, 4, tzinfo=timezone.utc)
    end = datetime(2026, 8, 4, 23, 59, 59, tzinfo=timezone.utc)

    result = web_server.build_vocab_insights(
        {"hotwords": {"missing": 5, "text": 5, "bool": 5, "negative": 5, "valid": 5}},
        {
            "missing": {},
            "text": {"freq": "10"},
            "bool": {"freq": True},
            "negative": {"freq": -1},
            "valid": {"freq": 3},
        },
        [], start, end,
    )

    assert result["summary"]["autoLearnedCount"] == 5
    assert result["summary"]["manualCount"] == 0
    assert result["topLearned"] == [{"word": "valid", "frequency": 3, "addedAt": None, "weight": 5}]


def test_load_events_returns_empty_for_directory_and_non_utf8_files(tmp_path):
    directory = tmp_path / "events-directory"
    directory.mkdir()
    invalid_utf8 = tmp_path / "events-invalid-utf8.jsonl"
    invalid_utf8.write_bytes(b'\xff\xfe')

    assert web_server.load_events(str(directory)) == []
    assert web_server.load_events(str(invalid_utf8)) == []


def test_build_vocab_insights_handles_zero_denominators_and_zero_fills_selected_range():
    result = web_server.build_vocab_insights(
        {"hotwords": {}},
        {},
        [{"timestamp": "2026-08-05T08:00:00Z", "type": "transcription_committed"}],
        datetime(2026, 8, 4, tzinfo=timezone.utc),
        datetime(2026, 8, 6, 23, 59, 59, tzinfo=timezone.utc),
    )

    assert result["summary"]["autoLearnedShare"] is None
    assert result["usage"]["commitRate"] is None
    assert result["usage"]["autoSubmitRate"] == 0.0
    assert result["learningDaily"] == [
        {"date": "2026-08-04", "addedCount": 0},
        {"date": "2026-08-05", "addedCount": 0},
        {"date": "2026-08-06", "addedCount": 0},
    ]
    assert result["usage"]["daily"] == [
        {"date": "2026-08-04", "committedCount": 0, "autoSubmitCount": 0},
        {"date": "2026-08-05", "committedCount": 1, "autoSubmitCount": 0},
        {"date": "2026-08-06", "committedCount": 0, "autoSubmitCount": 0},
    ]


def test_build_vocab_insights_buckets_offset_events_by_utc_day():
    result = web_server.build_vocab_insights(
        {"hotwords": {}},
        {},
        [{"timestamp": "2026-08-03T20:30:00-04:00", "type": "transcription_committed"}],
        datetime(2026, 8, 4, tzinfo=timezone.utc),
        datetime(2026, 8, 4, 23, 59, 59, tzinfo=timezone.utc),
    )

    assert result["usage"]["daily"] == [
        {"date": "2026-08-04", "committedCount": 1, "autoSubmitCount": 0},
    ]


def test_hotword_get_and_post_apis_are_preserved(server):
    assert json.load(urlopen(server.url + "/vocab/api/hotwords")) == {"hotwords": {"ffmpeg": 10}}

    request = Request(
        server.url + "/vocab/api/hotwords",
        data=json.dumps({"hotwords": {"python": 8}}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    assert json.load(urlopen(request)) == {"ok": True}
    assert json.load(urlopen(server.url + "/vocab/api/hotwords")) == {"hotwords": {"python": 8}}


def test_vocab_page_exposes_insights_controls_and_limit_copy():
    assert 'id="insightStartDate"' in web_server.VOCAB_HTML
    assert 'id="insightCards"' in web_server.VOCAB_HTML
    assert 'id="learningChart"' in web_server.VOCAB_HTML
    assert 'id="usageChart"' in web_server.VOCAB_HTML
    assert "/vocab/api/insights" in web_server.VOCAB_HTML
    assert "同期使用表现" in web_server.VOCAB_HTML
    assert "不代表热词单独带来的提升" in web_server.VOCAB_HTML


def test_vocab_page_uses_the_experimental_echarts_visualizations():
    page = web_server.VOCAB_HTML

    assert "https://cdn.jsdelivr.net/npm/echarts@5/dist/echarts.min.js" in page
    assert "window.echarts.init" in page
    assert "learningChart.setOption" in page
    assert "usageChart.setOption" in page
    assert "renderLearningChart(daily)" in page
    assert "renderUsage(usage)" in page


def test_vocab_page_renders_source_badges_for_ranked_learner_words():
    page = web_server.VOCAB_HTML

    assert "const learnedWords = new Set(insights.topLearned.map(row => row.word));" in page
    assert "if (learnedWords.has(word))" in page
    assert "badge.textContent = '自动学习';" in page


def test_vocab_page_renders_api_data_and_word_actions_without_html_or_inline_handler_injection():
    page = web_server.VOCAB_HTML

    assert 'document.createElement("tr")' in page
    assert 'document.createElement("input")' in page
    assert 'wordInput.addEventListener("input"' in page
    assert 'deleteButton.addEventListener("click"' in page
    assert 'oninput="update(' not in page
    assert 'oninput="updateWeight(' not in page
    assert 'onclick="remove(' not in page
    assert "document.getElementById('topLearned').innerHTML" not in page
    assert "document.getElementById('insightCards').innerHTML" not in page
    assert "document.getElementById('usageCards').innerHTML" not in page


def test_vocab_page_defers_rerender_until_save_and_sorts_by_weight():
    page = web_server.VOCAB_HTML

    assert "const entries = Object.entries(data.hotwords).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));" in page
    assert "wordInput.dataset.word = word;" in page
    assert "wordInput.addEventListener(\"input\", () => update(wordInput, getWeight(wordInput)));" in page
    assert "weightInput.addEventListener(\"input\", () => updateWeight(wordInput.dataset.word, weightInput.value));" in page
    assert "deleteButton.addEventListener(\"click\", () => remove(wordInput.dataset.word));" in page
    assert "dirty = true; render();" not in page[page.index("function update(input"):page.index("function remove(word)")]
    assert "dirty = false; render(); showStatus('✅ 已保存 — 下次录音生效');" in page


def test_vocab_page_keeps_dashboard_and_editor_loading_states():
    page = web_server.VOCAB_HTML

    assert "成效数据加载中" in page
    assert "暂无成效数据" in page
    assert "成效加载失败" in page
    assert "body: JSON.stringify(data)" in page


def test_vocab_page_uses_local_calendar_dates_for_default_and_quick_ranges():
    page = web_server.VOCAB_HTML

    assert "function localDateStr(date)" in page
    assert "date.getFullYear()" in page
    assert "date.getMonth() + 1" in page
    assert "date.getDate()" in page
    assert "toISOString()" not in page
    assert page.count("localDateStr(") == 4


def test_stats_apis_bucket_offset_events_by_utc_day(server, tmp_path):
    events_path = tmp_path / "usage-events.jsonl"
    events_path.write_text(
        '{"timestamp":"2026-08-03T20:30:00-04:00","type":"transcription_committed","characterCount":8}\n',
        encoding="utf-8",
    )

    stats = json.load(urlopen(server.url + "/stats/api/data?start=2026-08-04&end=2026-08-04"))
    heatmap = json.load(urlopen(server.url + "/stats/api/heatmap?year=2026"))

    assert stats["daily"] == [
        {"date": "2026-08-04", "voiceInputCount": 0, "characterCount": 8, "autoSubmitCount": 0},
    ]
    assert dict(heatmap["data"])["2026-08-04"] == 8
    assert dict(heatmap["data"])["2026-08-03"] == 0


def test_stats_page_shows_weekend_trend_only_above_ten_voice_inputs():
    page = web_server.STATS_HTML

    assert "function trendDaily(daily)" in page
    assert "return isWeekday || (row.voiceInputCount || 0) > 10;" in page
    assert "const trend = trendDaily(daily);" in page
    assert "const dates = trend.map(d => d.date.slice(5));" in page
    assert "周末不展示趋势数据" in page
    assert "updateCards(data.summary); updateChart(data.daily, start, end);" in page
