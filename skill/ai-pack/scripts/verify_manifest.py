#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_manifest.py — G5 交付门 / 只读验证：SHA256 快照与比对。

两种用法

1) 快照 + 比对（推荐，验证"原件一个字节都没动"）
       python verify_manifest.py --root <proj> --save baseline.json
       python verify_manifest.py --root <proj> --check baseline.json

2) 校验标准 sha256sum 清单（形如 "<hash>  <相对路径>"）
       python verify_manifest.py --root <proj> --manifest data/checksums.sha256

退出码
    0 = 完全一致   1 = 有新增/删除/修改   2 = 参数或路径错误

失效条件
    - 只做内容哈希：不记录权限、时间戳、ACL。
    - 不跟随符号链接/目录联接（安全考虑）。
    - 单文件 > --max-mb 时跳过并显式提示（默认 512 MB）。
    - 哈希一致只证明"内容没变"，不能证明"原本就是对的"。
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import sys
from pathlib import Path

SKIP_DIRS = {".git", ".svn", "__pycache__", ".Xil", "xsim.dir", ".dsh"}


def sha256(path: Path, max_mb: float):
    size_mb = path.stat().st_size / (1024 * 1024)
    if size_mb > max_mb:
        return None
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def walk(root: Path, patterns, max_mb: float):
    result = {}
    for p in sorted(root.rglob("*")):
        if not p.is_file() or p.is_symlink():
            continue
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        rel = p.relative_to(root).as_posix()
        if patterns and not any(fnmatch.fnmatch(rel, pat) or fnmatch.fnmatch(p.name, pat) for pat in patterns):
            continue
        digest = sha256(p, max_mb)
        if digest is None:
            print(f"SKIP (>{max_mb} MB): {rel}")
            continue
        result[rel] = digest
    return result


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="SHA256 manifest for read-only verification")
    ap.add_argument("--root", required=True)
    ap.add_argument("--save")
    ap.add_argument("--check")
    ap.add_argument("--manifest", help="verify a sha256sum-style list file")
    ap.add_argument("--include", help="逗号分隔的 glob，例如 '*.v,*.sv,*.xdc'")
    ap.add_argument("--max-mb", type=float, default=512.0)
    args = ap.parse_args(argv)

    root = Path(args.root).resolve()
    if not root.is_dir():
        print(f"ERROR: not a directory: {root}")
        return 2

    patterns = [s.strip() for s in args.include.split(",") if s.strip()] if args.include else None

    if args.manifest:
        listing = Path(args.manifest)
        if not listing.is_file():
            print(f"ERROR: manifest not found: {listing}")
            return 2
        bad = missing = 0
        for line in listing.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            expect, _, rel = line.partition("  ")
            target = root / rel
            if not target.is_file():
                print(f"MISSING  {rel}")
                missing += 1
                continue
            actual = sha256(target, args.max_mb)
            if actual != expect:
                print(f"CHANGED  {rel}")
                bad += 1
        total = bad + missing
        print(f"{'PASS' if total == 0 else 'FAIL'}  changed={bad} missing={missing}")
        return 0 if total == 0 else 1

    current = walk(root, patterns, args.max_mb)

    if args.check:
        baseline = json.loads(Path(args.check).read_text(encoding="utf-8"))
        added = sorted(set(current) - set(baseline))
        removed = sorted(set(baseline) - set(current))
        changed = sorted(k for k in set(current) & set(baseline) if current[k] != baseline[k])
        for k in added:
            print(f"ADDED    {k}")
        for k in removed:
            print(f"REMOVED  {k}")
        for k in changed:
            print(f"CHANGED  {k}")
        bad = len(added) + len(removed) + len(changed)
        print(f"{'PASS' if bad == 0 else 'FAIL'}  added={len(added)} removed={len(removed)} changed={len(changed)}")
        return 0 if bad == 0 else 1

    if args.save:
        Path(args.save).write_text(json.dumps(current, indent=2, sort_keys=True), encoding="utf-8")
        print(f"SAVED {len(current)} files -> {args.save}")
        return 0

    for rel, digest in current.items():
        print(f"{digest}  {rel}")
    print(f"# {len(current)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
