#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_timing.py — G3 时序门：从 Vivado timing summary 报告里读 WNS/WHS/WPWS 并判定。

用法
    python check_timing.py build/reports/report_impl_timing.rpt
    python check_timing.py <报告> --json out.json
    python check_timing.py <报告> --wns-min 0.0 --whs-min 0.05

判定
    PASS  = 所有 Corner 的 WNS >= wns_min 且 WHS >= whs_min 且违例端点数为 0
    WPWS 单独报告，不参与 PASS/FAIL（OSERDES 等固有相位会长期为负）

退出码
    0 = PASS   1 = FAIL   2 = 解析失败/参数错误

失效条件
    - 只认 "Design Timing Summary" 表格（report_timing_summary 的输出）；
      自定义/裁剪过的报告可能没有该表。
    - 不做多时钟分组分析，只看汇总表的最差一行。
    - 不判断违例端点是否集中在 SERDES；那一步必须人工看 (见 cdc-and-signoff.md §4)。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

NUM = r"-?\d+(?:\.\d+)?"


def parse_summary(text: str):
    """返回每个 Corner 的 (wns, tns, tnf, tnt, whs, ths, thf, tht, wpws, tpws, tpf, tpt)。"""
    rows = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if not line.strip().startswith("WNS(ns)"):
            continue
        seen_sep = False
        for cand in lines[i + 1 : i + 8]:
            stripped = cand.strip()
            if not stripped:
                continue
            if set(stripped) <= set("- "):
                seen_sep = True
                continue
            if not seen_sep:
                continue
            nums = re.findall(NUM, cand)
            if len(nums) >= 12:
                v = [float(x) for x in nums[:12]]
                rows.append(
                    (
                        v[0], v[1], int(v[2]), int(v[3]),
                        v[4], v[5], int(v[6]), int(v[7]),
                        v[8], v[9], int(v[10]), int(v[11]),
                    )
                )
                break
    return rows


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Vivado timing summary gate")
    ap.add_argument("report")
    ap.add_argument("--wns-min", type=float, default=0.0)
    ap.add_argument("--whs-min", type=float, default=0.0)
    ap.add_argument("--json", dest="json_out")
    args = ap.parse_args(argv)

    path = Path(args.report)
    if not path.is_file():
        print(f"ERROR: report not found: {path}")
        return 2

    rows = parse_summary(path.read_text(encoding="utf-8", errors="replace"))
    if not rows:
        print("ERROR: no 'Design Timing Summary' table found")
        return 2

    ok = True
    out = []
    for r in rows:
        wns, tns, tnf, tnt, whs, ths, thf, tht, wpws, tpws, tpf, tpt = r
        corner_ok = wns >= args.wns_min and whs >= args.whs_min and tnf == 0 and thf == 0
        ok = ok and corner_ok
        out.append(
            {
                "wns": wns, "tns": tns, "tns_failing": tnf, "tns_total": tnt,
                "whs": whs, "ths": ths, "ths_failing": thf, "ths_total": tht,
                "wpws": wpws, "tpws": tpws, "tpws_failing": tpf, "tpws_total": tpt,
                "pass": corner_ok,
            }
        )
        print(f"WNS={wns:+.3f} ns  TNS={tns:.3f}  failing {tnf}/{tnt}")
        print(f"WHS={whs:+.3f} ns  THS={ths:.3f}  failing {thf}/{tht}")
        print(f"WPWS={wpws:+.3f} ns  failing {tpf}/{tpt}  (pulse width — 不参与判定)")

    if any(r["wpws"] < 0 for r in out):
        print("NOTE: WPWS 为负。先看违例端点是否集中在 OSERDES/SERDES；是则记为已知项。")

    print("PASS" if ok else "FAIL")
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(out, indent=2), encoding="utf-8")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
