#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rtl_const_check.py — G1 静态门：Verilog 常量位宽 / 占位逻辑 / 未用输入。

检查三类"工具链不报错、人也很容易漏"的问题
    V1 常量位宽截断：`localparam [24:0] X = 25'd50_000_000;` 值超出声明位宽，静默取模
    V2 恒 0 / 恒 1 占位：`x && 1'b0`、`y | 1'b1` —— 功能没写完
    V3 未使用的 input：接口声明了，模块体内从未出现

用法
    python rtl_const_check.py --root src/rtl
    python rtl_const_check.py --root . --only-high        # 只报 V1/V2
    python rtl_const_check.py --root . --json out.json

退出码
    0 = 无高危险问题（V3 属提示）   1 = 发现 V1 或 V2   2 = 参数错误

失效条件
    - 纯正则扫描：不理解宏、ifdef、generate、函数内局部变量、位选 `a[7:0]`。
    - 对 `localparam int` / SystemVerilog 类型参数不适用（会跳过，不误报）。
    - V3 的"未使用"是文本级统计：注释/字符串里的同名标识符会干扰；跨 module 同名信号
      会互相干扰，因此按单个 module 文本块统计。
    - 结论必须人工复核；脚本只负责把可疑点摆到桌面。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT = re.compile(r"//[^\n]*")

CONST_RE = re.compile(
    r"\b(localparam|parameter)\b\s*(?:\[(\d+)\s*:\s*(\d+)\])?\s*([A-Za-z_]\w*)\s*=\s*"
    r"(?:(\d+)\s*)?'([sS]?)([dDhHbBoO])([0-9a-fA-FxXzZ_]+)",
)
PLACEHOLDER_RE = re.compile(r"(&&\s*1'b0|&&\s*1'b1\s*;|\|\|\s*1'b1|\|\s*1'b1\s*;|\?\s*1'b0\s*:\s*1'b0)")
MODULE_RE = re.compile(r"\bmodule\s+(\w+)(.*?)\bendmodule\b", re.S)
INPUT_RE = re.compile(r"\binput\b[^;\n]*?([A-Za-z_]\w*)\s*(?:,|;|$)", re.M)


def strip_comments(text: str) -> str:
    return LINE_COMMENT.sub("", BLOCK_COMMENT.sub("", text))


def to_value(base: str, digits: str):
    d = digits.replace("_", "")
    try:
        if base in "dD":
            return int(d)
        if base in "hH":
            return int(d, 16)
        if base in "bB":
            return int(d, 2)
        if base in "oO":
            return int(d, 8)
    except ValueError:
        return None
    return None


def check_file(path: Path):
    raw = path.read_text(encoding="utf-8", errors="replace")
    text = strip_comments(raw)
    issues = []

    # V1 常量位宽截断
    for m in CONST_RE.finditer(text):
        kind, msb, lsb, name, width, _signed, base, digits = m.groups()
        value = to_value(base, digits)
        if value is None:
            continue
        if msb is None:
            continue  # 无位宽声明 → 不截断，交给 lint
        bits = int(msb) - int(lsb) + 1
        cap = 1 << bits
        if value >= cap:
            line = text[: m.start()].count("\n") + 1
            issues.append({
                "rule": "V1",
                "line": line,
                "detail": f"{kind} [{msb}:{lsb}] {name} = {value} 超出 {bits} bit 上限 {cap - 1}",
                "fix": f"位宽改为 >= {value.bit_length()} bit（如 [31:0]），或改值；改完按'行为变更'记录",
            })

    # V2 占位逻辑
    for m in PLACEHOLDER_RE.finditer(text):
        line = text[: m.start()].count("\n") + 1
        snippet = text.splitlines()[line - 1].strip()[:100]
        issues.append({
            "rule": "V2",
            "line": line,
            "detail": f"恒值占位表达式：{snippet}",
            "fix": "功能未实现或调试残留；要么补逻辑，要么删掉并写进'未实现清单'",
        })

    # V3 未使用的 input（按 module 块统计）
    for m in MODULE_RE.finditer(text):
        mod_name, body = m.group(1), m.group(2)
        inputs = []
        for decl in re.finditer(r"\binput\b([^;)]*)", body):
            seg = decl.group(1)
            names = re.findall(r"[A-Za-z_]\w*", seg)
            if names:
                inputs.append(names[-1])
        for name in inputs:
            uses = len(re.findall(rf"\b{re.escape(name)}\b", body))
            if uses <= 1:
                line = text[: m.start()].count("\n") + 1
                issues.append({
                    "rule": "V3",
                    "line": line,
                    "detail": f"{mod_name}: input '{name}' 在模块体内未被引用",
                    "fix": "确认是否接口未接完；未接完的写进'未实现清单'",
                })
    return issues


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Verilog constant/placeholder/unused-input scan")
    ap.add_argument("--root", required=True)
    ap.add_argument("--only-high", action="store_true", help="只报 V1/V2")
    ap.add_argument("--include", default="*.v,*.sv,*.vh")
    ap.add_argument("--exclude", default="")
    ap.add_argument("--json", dest="json_out")
    args = ap.parse_args(argv)

    root = Path(args.root)
    if not root.is_dir():
        print(f"ERROR: not a directory: {root}")
        return 2

    includes = [p.strip() for p in args.include.split(",") if p.strip()]
    excludes = [p.strip() for p in args.exclude.split(",") if p.strip()]
    files = []
    for pat in includes:
        files.extend(root.rglob(pat))
    files = sorted({
        f for f in files
        if f.is_file() and not any(f.match(x) or x in f.name for x in excludes)
    })
    if not files:
        print(f"ERROR: no RTL files ({args.include}) under {root}")
        return 2

    all_issues = []
    for f in files:
        for issue in check_file(f):
            if args.only_high and issue["rule"] == "V3":
                continue
            issue["file"] = f.relative_to(root).as_posix()
            all_issues.append(issue)

    order = {"V1": 0, "V2": 1, "V3": 2}
    all_issues.sort(key=lambda x: (order[x["rule"]], x["file"], x["line"]))
    for i in all_issues:
        print(f"[{i['rule']}] {i['file']}:{i['line']}  {i['detail']}")
        print(f"      → {i['fix']}")

    high = [i for i in all_issues if i["rule"] in ("V1", "V2")]
    print(f"\nfiles={len(files)} issues={len(all_issues)} high={len(high)}")
    print("PASS" if not high else "FAIL")
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(all_issues, indent=2, ensure_ascii=False), encoding="utf-8")
    return 0 if not high else 1


if __name__ == "__main__":
    sys.exit(main())
