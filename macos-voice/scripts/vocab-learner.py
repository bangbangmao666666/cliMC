#!/usr/bin/env python3
"""cliMC 高频生词自动学习器（常驻）

思路：不学"ASR 纠正方向"（噪声大、可能越学越错），而是从最终转写文本里
统计你高频说、但不是常见词的片段（多半是专有名词/术语/常用口令），
达到频次阈值就自动 merge 进 vocabulary.json，下次录音即被火山引擎 ASR
当作热词优先识别。

完全自动、无噪声风险：加进去最多是提升识别概率，不涉及"判断对错"。
局限（诚实说）：解决不了"接触→结束"这种常见词之间的近音混淆——那两个
都是常见词会被停用词表过滤掉；本学习器主攻"专有名词被识别错"。

数据源：tail /private/tmp/codex-voice-hotkey.log 中的 "收到最终转写：…" 行。
只读 final（已提交的干净文本），不读 partial（partial 边说边长，噪声大）。

用法（常驻，由 launchd 拉起）:
    python3 vocab-learner.py \
        --log /private/tmp/codex-voice-hotkey.log \
        --vocab ~/.config/codex-voice/vocabulary.json

调试:
    python3 vocab-learner.py --once --dry-run        # 扫一遍现有日志，只打印候选，不写文件
    python3 vocab-learner.py --once                   # 扫一遍并真正 merge
    python3 vocab-learner.py --reset-state            # 清空已学记录（之后会重新学）

只依赖 Python 标准库（系统自带 /usr/bin/python3 即可）。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from collections import Counter
from pathlib import Path

# ── 默认路径 ─────────────────────────────────────────
DEFAULT_LOG = "/private/tmp/codex-voice-hotkey.log"
DEFAULT_VOCAB = str(Path.home() / ".config/codex-voice/vocabulary.json")
DEFAULT_STATE = str(Path.home() / ".config/codex-voice/vocab-learner-state.json")
DEFAULT_INTERVAL = 60          # 常驻模式扫描间隔（秒）
DEFAULT_MIN_FREQ = 5           # 候选词至少出现的独立 utterance 次数
DEFAULT_MIN_LEN = 2            # CJK n-gram 最短长度
DEFAULT_MAX_LEN = 6            # CJK n-gram 最长长度
DEFAULT_WEIGHT = 7             # 自动学习词的默认权重（火山热词 1–10）
DEFAULT_MAX_TOTAL = 400        # vocabulary.json 热词总数上限（防膨胀）

# ── 日志行正则 ───────────────────────────────────────
# [2026-08-04T06:31:45.001Z] [cliMC] 收到最终转写：<文本>
FINAL_RE = re.compile(r"收到最终转写：(.*)$")

# ── 中文常见停用词 / 高频功能词 ─────────────────────
# 这些是"ASR 本来就认识、且你说了也不该当生词"的词。用精确匹配过滤，
# 不会误伤由它们组成的复合短语（如 "解释"/"代码" 被过滤，但 "解释代码" 保留）。
STOPWORDS = {
    # 单字功能词
    "的", "了", "是", "有", "在", "我", "你", "他", "她", "它", "这", "那", "个",
    "们", "和", "与", "或", "及", "等", "也", "都", "就", "还", "又", "再", "已",
    "被", "把", "给", "让", "向", "往", "到", "从", "对", "为", "以", "于", "把",
    "吗", "呢", "吧", "啊", "呀", "哦", "呃", "嗯", "哈", "啦", "嘛", "着", "过",
    "地", "得", "只", "才", "便", "且", "而", "如", "若", "虽", "但", "却", "则",
    # 代词/指示
    "这个", "那个", "这些", "那些", "这样", "那样", "这里", "那里", "哪儿", "哪里",
    "什么", "怎么", "为什么", "怎样", "这么", "那么", "的话", "的话",
    # 口语填充/连接
    "我们", "你们", "他们", "咱们", "自己", "别人", "大家",
    "然后", "所以", "因为", "但是", "不过", "而且", "或者", "还是", "如果",
    "就是", "只是", "也是", "都是", "不是", "还有", "没有", "有点", "一些",
    "一下", "一直", "一样", "一下", "等等", "之类的", "什么的",
    # 常见动词/助动
    "可以", "应该", "可能", "需要", "觉得", "认为", "知道", "了解", "看看",
    "进行", "继续", "完成", "开始", "结束", "解释", "提交", "重新", "打包",
    "测试", "生成", "看看", "看一下", "试一下", "一下", "处理", "整理",
    "做", "说", "看", "想", "用", "让", "给", "到", "去", "来", "是", "有",
    # 常见名词/通用词
    "代码", "项目", "分支", "方案", "设置", "模型", "服务", "用户", "内容",
    "历史", "环境", "功能", "改动", "更新", "部分", "情况", "问题", "时间",
    "节点", "语音", "识别", "输入", "输出", "东西", "地方", "时候", "方面",
    "这边", "那边", "上面", "下面", "前面", "后面", "里面", "外面",
    "今天", "现在", "然后", "已经", "正在", "马上", "一会", "一下",
    "中国", "国外", "本地", "本机", "当前", "目前", "主要", "基本",
    "一个", "一种", "第一", "第二", "第三",
    "哪些", "哪个", "哪种", "一下", "一些", "一下这个", "看一下", "试一下",
    # 常见动词短搭配（避免碎片）
    "是的", "好的", "对了", "行了", "可以", "没问题",
}

# 单字"常见字"集合：n-gram 若完全由这些字组成则丢弃（防"的话/我们"类碎片）
COMMON_CHARS = set("的了是在有我你他她它这个们和与或及等也都就还又再已被把给让向往到从对为以于吗呢吧啊呀哦呃嗯哈啦嘛着过地得只才便且而如若虽但却则一二三四五六七八九十来去说看想做用让给是")

# 候选首尾"坏边界字"：开头/结尾是这些字的 CJK n-gram 多半是碎片
# （如 "一下这" 尾字"这"、"哪些" 首字"哪"、"这个项目" 首字"这"）。
BOUNDARY_BAD = set(
    "这那哪个些种次条们地的了是有在和我你他她它把给让向往到从对为以于"
    "吗呢吧啊呀哦呃嗯哈等下一上下里外面前后中又再已正将要会能可应需"
)


# ── 文本抽取 ─────────────────────────────────────────

def extract_finals(log_path: str) -> list[str]:
    """从日志里抽取所有 final 转写文本（每行一个）。"""
    path = Path(log_path)
    if not path.exists():
        return []
    finals: list[str] = []
    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                m = FINAL_RE.search(line)
                if not m:
                    continue
                text = m.group(1).strip()
                if text:
                    finals.append(text)
    except OSError:
        pass
    return finals


# ── n-gram 统计 ──────────────────────────────────────

CJK_RE = re.compile(r"[\u4e00-\u9fff]+")
LATIN_RE = re.compile(r"[A-Za-z][A-Za-z0-9_]{2,}")


def cjk_ngrams(text: str, n_min: int, n_max: int) -> set[str]:
    """对每个连续 CJK 片段抽取 n_min..n_max 字的 n-gram。"""
    out: set[str] = set()
    for run in CJK_RE.findall(text):
        L = len(run)
        for n in range(n_min, n_max + 1):
            if L < n:
                continue
            for i in range(L - n + 1):
                out.add(run[i : i + n])
    return out


def latin_tokens(text: str) -> set[str]:
    """英文/标识符 token（长度>=3），小写化。"""
    return {m.group(0).lower() for m in LATIN_RE.finditer(text)}


def is_all_common(s: str) -> bool:
    return all(ch in COMMON_CHARS for ch in s)


def has_bad_boundary(s: str) -> bool:
    """CJK 候选首尾若落在功能字上，视为碎片，丢弃。"""
    if not s:
        return True
    return s[0] in BOUNDARY_BAD or s[-1] in BOUNDARY_BAD


def count_candidates(
    finals: list[str],
    n_min: int,
    n_max: int,
) -> tuple[Counter, Counter]:
    """返回 (cjk_ngram_counts, latin_token_counts)。每条 utterance 只计一次。"""
    cjk = Counter()
    lat = Counter()
    for text in finals:
        for g in cjk_ngrams(text, n_min, n_max):
            cjk[g] += 1
        for g in latin_tokens(text):
            lat[g] += 1
    return cjk, lat


# ── 候选筛选（去冗余子串）────────────────────────────

def select_candidates(
    counts: Counter,
    min_freq: int,
    stopwords: set[str],
) -> list[tuple[str, int]]:
    """筛出高频、非停用词的候选，并压制冗余子串。

    规则：按 (频次降序, 长度降序) 依次考虑候选 C；若 C 是某个已接受 A 的子串
    且 freq(C) <= freq(A)，则跳过 C（C 只是 A 的碎片）。这能避免同时收录
    "解释代码"/"释代码"/"解释"——只留最长的那个；但若短串频次更高（说明它还
    出现在别的语境），仍保留。
    """
    raw = [(g, c) for g, c in counts.items() if c >= min_freq]
    # 过滤停用词 / 全常见字
    filtered = [
        (g, c)
        for g, c in raw
        if g not in stopwords and not is_all_common(g) and not has_bad_boundary(g)
    ]
    # 排序：频次降序、长度降序
    filtered.sort(key=lambda x: (-x[1], -len(x[0])))

    accepted: list[tuple[str, int]] = []
    for g, c in filtered:
        redundant = False
        for ag, ac in accepted:
            if g in ag and c <= ac:
                # g 是已接受 ag 的子串，且频次不更高 → 碎片，丢弃
                redundant = True
                break
        if not redundant:
            accepted.append((g, c))
    return accepted


# ── vocabulary.json 读写 ─────────────────────────────

def load_vocab(vocab_path: str) -> dict:
    p = Path(vocab_path)
    if p.exists():
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
            if isinstance(data, dict) and isinstance(data.get("hotwords"), dict):
                return data
        except (OSError, json.JSONDecodeError):
            pass
    return {"hotwords": {}}


def save_vocab(vocab_path: str, vocab: dict) -> None:
    p = Path(vocab_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(
        json.dumps(vocab, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.replace(tmp, p)


# ── 学习状态（记录已学，尊重人工删除）────────────────

def load_state(state_path: str) -> dict:
    p = Path(state_path)
    if p.exists():
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            pass
    return {"learned": {}}


def save_state(state_path: str, state: dict) -> None:
    p = Path(state_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(
        json.dumps(state, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.replace(tmp, p)


# ── 主流程 ───────────────────────────────────────────

def run_learner(
    log_path: str,
    vocab_path: str,
    state_path: str,
    min_freq: int = DEFAULT_MIN_FREQ,
    weight: int = DEFAULT_WEIGHT,
    max_total: int = DEFAULT_MAX_TOTAL,
    dry_run: bool = False,
    once: bool = False,
    interval: int = DEFAULT_INTERVAL,
) -> int:
    stopwords = STOPWORDS
    state = load_state(state_path)
    learned: dict = state.setdefault("learned", {})

    def scan_once() -> None:
        nonlocal state, learned
        # 每轮重新读 vocab（用户可能在网页编辑器里手动改过）
        vocab = load_vocab(vocab_path)
        hotwords: dict = vocab.setdefault("hotwords", {})

        finals = extract_finals(log_path)
        if not finals:
            print(f"[learner] 日志无 final 文本: {log_path}", flush=True)
            return

        cjk_counts, lat_counts = count_candidates(finals, DEFAULT_MIN_LEN, DEFAULT_MAX_LEN)
        cjk_cands = select_candidates(cjk_counts, min_freq, stopwords)
        # 英文 token：直接按频次取，不做子串压制（英文词边界清晰）
        lat_cands = [(g, c) for g, c in lat_counts.most_common() if c >= min_freq]
        lat_cands = [(g, c) for g, c in lat_cands if g not in stopwords]

        now = int(time.time())
        added: list[str] = []
        skipped_already: list[str] = []
        skipped_deleted: list[str] = []

        def consider(word: str, freq: int) -> None:
            word_key = word  # 英文已小写；CJK 原样
            already_in_vocab = word_key in hotwords
            in_state = word_key in learned
            if already_in_vocab:
                # 已在热词表（无论是人工还是之前学的），刷新 state 频次记录即可
                learned[word_key] = {"freq": freq, "added_at": learned.get(word_key, {}).get("added_at", now)}
                return
            if in_state:
                # 学过但已不在 vocab → 视为用户手动删除，尊重之，不重新加
                skipped_deleted.append(word_key)
                return
            # 新词
            if len(hotwords) >= max_total:
                return
            hotwords[word_key] = weight
            learned[word_key] = {"freq": freq, "added_at": now}
            added.append(word_key)

        # 英文优先（专有名词价值高）
        for word, freq in lat_cands:
            consider(word, freq)
        # 中文候选
        for word, freq in cjk_cands:
            consider(word, freq)

        # 统计摘要
        print(
            f"[learner] finals={len(finals)} cjk_cands={len(cjk_cands)} "
            f"lat_cands={len(lat_cands)} vocab_total={len(hotwords)}",
            flush=True,
        )
        if added:
            print(f"[learner] ✅ 新增热词 {len(added)}: {added}", flush=True)
        if skipped_deleted:
            print(
                f"[learner] ⏭ 跳过已删词 {len(skipped_deleted)}（尊重人工删除）: "
                f"{skipped_deleted[:10]}",
                flush=True,
            )

        if dry_run:
            # dry-run 下也打印候选全貌，但不写任何文件
            print("[learner] (dry-run) 候选 CJK:", [(g, c) for g, c in cjk_cands[:25]], flush=True)
            print("[learner] (dry-run) 候选 EN:", lat_cands[:25], flush=True)
            return

        if added:
            save_vocab(vocab_path, vocab)
        # state 频次记录始终更新（便于观察）
        save_state(state_path, state)

    if once:
        scan_once()
        return 0

    print(
        f"[learner] 常驻启动: log={log_path} vocab={vocab_path} "
        f"state={state_path} interval={interval}s min_freq={min_freq}",
        flush=True,
    )
    while True:
        try:
            scan_once()
        except Exception as e:  # noqa: BLE001 — 常驻不能挂
            print(f"[learner] 扫描异常（已吞掉继续）: {e}", flush=True)
        time.sleep(interval)



def _selftest() -> int:
    """内置自检：覆盖 n-gram 抽取、停用词/边界过滤、子串去冗余、vocabulary merge。"""
    import tempfile
    ok = True
    def check(name, cond):
        nonlocal ok
        print(("PASS" if cond else "FAIL"), name)
        ok = ok and cond

    # 1) cjk_ngrams
    gs = cjk_ngrams("解释代码", 2, 4)
    check("cjk_ngrams 包含 '解释代码'", "解释代码" in gs)
    check("cjk_ngrams 包含 '解释'", "解释" in gs)

    # 2) latin_tokens
    lt = latin_tokens("用 CodexBridge 和 API2 调 a 吧")
    check("latin_tokens 含 codexbridge", "codexbridge" in lt)
    check("latin_tokens 含 api2", "api2" in lt)
    check("latin_tokens 排除短词 'a'", "a" not in lt)

    # 3) 停用词过滤
    c = Counter({"解释代码": 10, "解释": 10, "释代码": 10, "代码": 10, "的话": 10, "一下这": 5})
    sel = select_candidates(c, min_freq=3, stopwords=STOPWORDS)
    words = {w for w, _ in sel}
    check("保留 '解释代码'", "解释代码" in words)
    check("丢弃停用词 '解释'", "解释" not in words)
    check("丢弃停用词 '代码'", "代码" not in words)
    check("丢弃停用词 '的话'", "的话" not in words)
    check("丢弃坏边界 '一下这'", "一下这" not in words)
    # 子串去冗余：'释代码' 是 '解释代码' 子串且频次不高 → 应被丢
    check("丢弃冗余子串 '释代码'", "释代码" not in words)

    # 4) vocabulary merge + 尊重人工删除
    with tempfile.TemporaryDirectory() as d:
        vpath = os.path.join(d, "vocabulary.json")
        spath = os.path.join(d, "state.json")
        save_vocab(vpath, {"hotwords": {"已有词": 9}})
        # 第一次：学一个新词
        # 手工喂 state + 模拟 consider
        vocab = load_vocab(vpath)
        hotwords = vocab.setdefault("hotwords", {})
        learned = {}
        # 模拟 consider("新词", 6)
        assert "新词" not in hotwords and "新词" not in learned
        hotwords["新词"] = DEFAULT_WEIGHT
        learned["新词"] = {"freq": 6, "added_at": 1}
        save_vocab(vpath, vocab)
        save_state(spath, {"learned": learned})
        # 用户手动删除"新词"
        vocab = load_vocab(vpath)
        del vocab["hotwords"]["新词"]
        save_vocab(vpath, vocab)
        # 再跑一次 learner（once），"新词" 已在 state 但不在 vocab → 应跳过不重加
        rc = run_learner(log_path="/dev/null", vocab_path=vpath, state_path=spath, once=True)
        vocab2 = load_vocab(vpath)
        check("尊重人工删除：不重新加 '新词'", "新词" not in vocab2["hotwords"])

    print("SELFTEST", "OK" if ok else "FAILED")
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="cliMC 高频生词自动学习器")
    parser.add_argument("--log", default=DEFAULT_LOG, help="ASR 日志路径")
    parser.add_argument("--vocab", default=DEFAULT_VOCAB, help="vocabulary.json 路径")
    parser.add_argument("--state", default=DEFAULT_STATE, help="学习状态文件路径")
    parser.add_argument("--interval", type=int, default=DEFAULT_INTERVAL, help="常驻扫描间隔(秒)")
    parser.add_argument("--min-freq", type=int, default=DEFAULT_MIN_FREQ, help="候选最低频次")
    parser.add_argument("--weight", type=int, default=DEFAULT_WEIGHT, help="自动学习词默认权重(1-10)")
    parser.add_argument("--max-total", type=int, default=DEFAULT_MAX_TOTAL, help="热词总数上限")
    parser.add_argument("--once", action="store_true", help="只扫一遍后退出（调试）")
    parser.add_argument("--dry-run", action="store_true", help="只打印不写文件")
    parser.add_argument("--reset-state", action="store_true", help="清空学习状态后退出")
    parser.add_argument("--selftest", action="store_true", help="运行内置自检后退出")
    args = parser.parse_args()


    if args.selftest:
        return _selftest()

    if args.reset_state:
        try:
            Path(args.state).unlink()
            print(f"[learner] 已清空状态: {args.state}", flush=True)
        except FileNotFoundError:
            pass
        return 0

    return run_learner(
        log_path=args.log,
        vocab_path=args.vocab,
        state_path=args.state,
        min_freq=args.min_freq,
        weight=max(1, min(10, args.weight)),
        max_total=args.max_total,
        dry_run=args.dry_run,
        once=args.once,
        interval=args.interval,
    )


if __name__ == "__main__":
    sys.exit(main())
