#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_sim_logs.py — G2 仿真门：把一堆 xsim 日志变成一张"证据表"。

它做三件"只读最后一行 RESULT"做不到的事
    1) 统计每个日志里的 FAIL / ERROR / TIMEOUT 行数，而不是只看 PASS；
    2) 标出"结论 PASS 但过程中有 FAIL"的容差型通过（需要人工确认判据）；
    3) 标出"没有结构化结论"的日志（跑完没报错 != 验证过）。

用法
    python check_sim_logs.py --root sim/results
    python check_sim_logs.py --root . --md evidence.md
    python check_sim_logs.py --root . --strict          # 有任何 FAIL/ERROR 即退出码 1

退出码
    0 = 每个日志都有 PASS 结论且无 FAIL/ERROR
    1 = 存在 FAIL/ERROR/无结论
    2 = 参数错误

失效条件
    - 依赖日志里出现 "RESULT" 或 "PASS"/"FAIL" 字样；没有这两个词的日志会被判 NO-RESULT
      （这是有意的：没有结构化结论的 TB 不算证据）。
    - 不理解判据含义（容差 4 是否合理必须人读 TB）。
    - 不检查参数覆盖（那需要 _xelab.txt + RTL 源码，见 verification-charter.md §3 Q1）。
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

FAIL_RE = re.compile(r"\b(FAIL(?:ED|URE)?|ERROR|TIMEOUT|MISMATCH)\b", re.I)
PASS_RE = re.compile(r"\b(PASS(?:ED)?|OK)\b", re.I)
OK_RE = re.compile(r"\b[A-Z][A-Z0-9_]*_OK\b")  # PACING_OK / CRC_OK / LOCK_OK
RESULT_RE = re.compile(r"RESULT\s*[:=]?\s*(.*)$", re.I | re.M)


def analyse(path: Path):
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    fail_lines = [ln.strip() for ln in lines if FAIL_RE.search(ln)]
    strict_fail = [ln.strip() for ln in lines if re.match(r"^\s*\**\s*(FAIL|FAILED|FAILURE|TIMEOUT)\b", ln, re.I)]
    results = [m.group(1).strip() for m in RESULT_RE.finditer(text)]
    conclusion = results[-1] if results else ""

    if strict_fail:
        verdict = "FAIL"
    elif results and (PASS_RE.search(conclusion) or OK_RE.search(text)):
        verdict = "PASS"
    elif results:
        # 有结构化 RESULT 但没有 PASS/FAIL/OK 字样：需要人读判据
        verdict = "PASS" if any(re.search(r"^\s*\**\s*PASS\b", ln, re.I) for ln in lines) else "RESULT-ONLY"
    elif any(re.search(r"^\s*\**\s*PASS\b", ln, re.I) for ln in lines):
        verdict = "PASS(no RESULT line)"
    else:
        verdict = "NO-RESULT"

    return {
        "file": path.name,
        "verdict": verdict,
        "conclusion": conclusion[:120],
        "fail_lines": len(fail_lines),
        "first_fail": fail_lines[0][:120] if fail_lines else "",
        "tolerance": bool(fail_lines) and verdict.startswith("PASS"),
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="xsim log evidence table")
    ap.add_argument("--root", required=True)
    ap.add_argument("--md", help="同时输出 Markdown 表格")
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--ext", default=".log,.txt")
    args = ap.parse_args(argv)

    root = Path(args.root)
    if not root.is_dir():
        print(f"ERROR: not a directory: {root}")
        return 2

    exts = tuple(e.strip() for e in args.ext.split(",") if e.strip())
    logs = [p for p in sorted(root.rglob("*")) if p.is_file() and p.suffix.lower() in exts and p.stat().st_size > 0]
    if not logs:
        print(f"ERROR: no logs ({', '.join(exts)}) under {root}")
        return 2

    rows = [analyse(p) for p in logs]
    for r in rows:
        flag = "!" if r["tolerance"] else " "
        print(f"{flag}{r['file']:<32} {r['verdict']:<16} fail_lines={r['fail_lines']:<4} {r['conclusion']}")
        if r["tolerance"]:
            print(f"   ^ 结论 PASS 但过程有 FAIL：确认判据是否为容差（例：{r['first_fail']}）")

    bad = [r for r in rows if r["verdict"] == "FAIL" or r["verdict"] == "NO-RESULT"]
    if args.md:
        lines = ["| log | verdict | fail lines | conclusion |", "|---|---|---|---|"]
        for r in rows:
            lines.append(f"| {r['file']} | {r['verdict']} | {r['fail_lines']} | `{r['conclusion']}` |")
        Path(args.md).write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"\n# markdown -> {args.md}")

    if args.strict:
        ok = not bad and not any(r["tolerance"] for r in rows)
    else:
        ok = not bad
    print("\nPASS" if ok else "\nFAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
