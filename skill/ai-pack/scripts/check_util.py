#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_util.py — G4 资源门：从 Vivado utilization 报告里读主要资源占用并判定阈值。

用法
    python check_util.py build/reports/report_impl_util.rpt
    python check_util.py <报告> --lut 80 --ff 60 --bram 80 --dsp 80
    python check_util.py <报告> --json out.json

判定
    每项 Util% <= 对应阈值 则 PASS；任何一项超阈值即 FAIL。

退出码
    0 = PASS   1 = FAIL   2 = 解析失败

失效条件
    - 依赖 "| Slice LUTs | <used> | ... | <avail> | <pct> |" 这种表格行；
      7 系列/K7/UltraScale 的标签不同（CLB LUTs / CLB Registers），脚本已兼容常见别名。
    - Util% 列为空时用 used/avail 现算。
    - 不区分 LUT as Logic / as Memory；只看顶层合计行。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# 别名 → 统一键
ALIASES = {
    "lut": ("Slice LUTs", "CLB LUTs", "LUT as Logic"),
    "ff": ("Slice Registers", "CLB Registers", "Register as Flip Flop"),
    "bram": ("Block RAM Tile", "RAMB36/FIFO", "Block RAM"),
    "dsp": ("DSPs", "DSP Blocks", "DSP48E1"),
}

ROW = re.compile(
    r"^\|\s*([^|]+?)\s*\|\s*(\d+(?:\.\d+)?)\s*\|[^|]*\|[^|]*\|\s*(\d+(?:\.\d+)?)\s*\|\s*([\d.]*)\s*\|\s*$",
    re.M,
)


def parse_rows(text: str):
    found = {}
    for m in ROW.finditer(text):
        label = m.group(1).strip()
        used, avail, pct = float(m.group(2)), float(m.group(3)), m.group(4)
        if label not in found:
            found[label] = (used, avail, float(pct) if pct else (100.0 * used / avail if avail else 0.0))
    return found


def pick(found, key):
    for name in ALIASES[key]:
        if name in found:
            return name, found[name]
    return None, None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Vivado utilization gate")
    ap.add_argument("report")
    ap.add_argument("--lut", type=float, default=80.0)
    ap.add_argument("--ff", type=float, default=60.0)
    ap.add_argument("--bram", type=float, default=80.0)
    ap.add_argument("--dsp", type=float, default=80.0)
    ap.add_argument("--json", dest="json_out")
    args = ap.parse_args(argv)

    path = Path(args.report)
    if not path.is_file():
        print(f"ERROR: report not found: {path}")
        return 2

    found = parse_rows(path.read_text(encoding="utf-8", errors="replace"))
    if not found:
        print("ERROR: no utilization table rows found (expects '| <label> | used | ... | avail | pct |')")
        return 2

    limits = {"lut": args.lut, "ff": args.ff, "bram": args.bram, "dsp": args.dsp}
    results, ok = [], True
    for key, limit in limits.items():
        name, val = pick(found, key)
        if val is None:
            print(f"WARN: {key.upper()} not found in report (skipped)")
            continue
        used, avail, pct = val
        passed = pct <= limit
        ok = ok and passed
        results.append({"resource": key, "label": name, "used": used, "avail": avail, "pct": pct, "limit": limit, "pass": passed})
        print(f"{name:<20} {used:>7.1f} / {avail:<7.0f} = {pct:6.2f}%  (limit {limit:.1f}%)  {'PASS' if passed else 'FAIL'}")

    print("PASS" if ok else "FAIL")
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(results, indent=2), encoding="utf-8")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
