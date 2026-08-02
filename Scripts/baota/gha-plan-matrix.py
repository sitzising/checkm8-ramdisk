#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
为 GitHub Actions 生成 checkm8 Ramdisk 构建矩阵（覆盖节点，非逐版本）。

节点：该机型最低可用 → iPhone X 最高区间（16.7.x）
无固件的组合会跳过；16.1+ 默认标记 needs_apfs（Linux 常失败）。
"""
from __future__ import print_function

import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request

# A7–A11（USB checkm8），与 Checkm8UsbPwnCatalog / build-checkm8.sh 对齐
ALL_DEVICES = [
    # A11
    "iPhone10,1", "iPhone10,2", "iPhone10,3", "iPhone10,4", "iPhone10,5", "iPhone10,6",
    # A10 / A10X
    "iPhone9,1", "iPhone9,2", "iPhone9,3", "iPhone9,4",
    "iPad7,1", "iPad7,2", "iPad7,3", "iPad7,4", "iPad7,5", "iPad7,6", "iPad7,11", "iPad7,12",
    "iPod9,1",
    # A9 / A9X
    "iPhone8,1", "iPhone8,2", "iPhone8,4",
    "iPad6,3", "iPad6,4", "iPad6,7", "iPad6,8", "iPad6,11", "iPad6,12",
    # A8
    "iPhone7,1", "iPhone7,2",
    "iPad5,1", "iPad5,2", "iPad5,3", "iPad5,4",
    "iPod7,1",
    # A7
    "iPhone6,1", "iPhone6,2",
    "iPad4,1", "iPad4,2", "iPad4,3", "iPad4,4", "iPad4,5", "iPad4,6", "iPad4,7", "iPad4,8", "iPad4,9",
]

A11_DEVICES = [d for d in ALL_DEVICES if d.startswith("iPhone10,")]

# out=发布 zip 名；ios=传给 sshrd_lite -s；覆盖区间见 coverage
# 12.4.1：A11 有；12.5.7：A7/A8 末版（无固件的组合会在 plan 阶段跳过）
NODES = [
    {"out": "11.4.1", "ios": "11.4.1", "coverage": "iOS 11.0 ~ 11.4.1"},
    {"out": "12.4.1", "ios": "12.4.1", "coverage": "iOS 12.0 ~ 12.4.1"},
    {"out": "12.5.7", "ios": "12.5.7", "coverage": "iOS 12.5.x（A7/A8 末版）"},
    {"out": "13.7", "ios": "13.7", "coverage": "iOS 13.0 ~ 13.7"},
    {"out": "14.0", "ios": "14.0", "coverage": "iOS 14.0 ~ 14.8.1"},
    {"out": "15.0", "ios": "15.0", "coverage": "iOS 15.0 ~ 15.8.x"},
    {"out": "16.0", "ios": "16.0", "coverage": "iOS 16.0 ~ 16.3.1"},
    {"out": "16.7.8", "ios": "16.7.8", "coverage": "iOS 16.4 ~ 16.7.x（X 最高）", "needs_apfs": True},
]

UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


def parse_ios_tuple(ver):
    m = re.match(r"^(\d+)(?:\.(\d+))?(?:\.(\d+))?", (ver or "").strip())
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2) or 0), int(m.group(3) or 0))


def http_json(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def firmware_versions(device):
    url = "https://api.ipsw.me/v4/device/%s?type=ipsw" % urllib.parse.quote(device)
    try:
        data = http_json(url)
    except Exception as e:
        print("[warn] ipsw.me fail %s: %s" % (device, e), file=sys.stderr)
        return {}
    out = {}
    for fw in data.get("firmwares") or []:
        ver = (fw.get("version") or "").strip()
        build = (fw.get("buildid") or "").strip()
        if not ver or not build:
            continue
        if not re.match(r"^\d+(\.\d+){0,3}$", ver):
            continue
        # 同版本多 build 取第一条
        out.setdefault(ver, build)
    return out


def resolve_devices(scope, only_product):
    if only_product.strip():
        return [p.strip().replace(".", ",") for p in only_product.split() if p.strip()]
    scope = (scope or "a11").lower()
    if scope == "smoke":
        return ["iPhone10,6"]
    if scope == "a11":
        return list(A11_DEVICES)
    if scope == "all":
        return list(ALL_DEVICES)
    raise SystemExit("unknown scope: %r (smoke|a11|all)" % scope)


def resolve_nodes(only_ios, include_apfs):
    if only_ios.strip():
        want = set(x.strip() for x in only_ios.replace(",", " ").split() if x.strip())
        nodes = [n for n in NODES if n["out"] in want or n["ios"] in want]
        if not nodes:
            raise SystemExit("only_ios matched nothing: %r" % only_ios)
        return nodes
    if include_apfs:
        return list(NODES)
    return [n for n in NODES if not n.get("needs_apfs")]


def load_pairs(path):
    """每行 product|ios，例如 iPhone10,1|11.4.1"""
    pairs = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "|" not in line:
                continue
            pt, ios = line.split("|", 1)
            pt = pt.strip().replace(".", ",")
            ios = ios.strip()
            if pt and ios:
                pairs.append((pt, ios))
    return pairs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scope", default=os.environ.get("SCOPE", "a11"))
    ap.add_argument("--only-product", default=os.environ.get("ONLY_PRODUCT", ""))
    ap.add_argument("--only-ios", default=os.environ.get("ONLY_IOS", ""))
    ap.add_argument(
        "--include-apfs",
        action="store_true",
        default=os.environ.get("INCLUDE_APFS", "").lower() in ("1", "true", "yes"),
    )
    ap.add_argument("--out", default=os.environ.get("MATRIX_OUT", "matrix.json"))
    ap.add_argument("--skip-ipsw-check", action="store_true")
    ap.add_argument(
        "--pairs-file",
        default=os.environ.get("PAIRS_FILE", ""),
        help="精确重跑列表 product|ios（优先于 scope 笛卡尔积）",
    )
    args = ap.parse_args()

    jobs = []
    cache = {}

    pairs_file = (args.pairs_file or "").strip()
    only_prod = (args.only_product or "").strip()
    here = os.path.dirname(os.path.abspath(__file__))
    # 兼容：only_product=@retry / @fill 指向成对列表
    if only_prod in ("@retry", "retry", "__retry__") and not pairs_file:
        pairs_file = os.path.join(here, "_retry_fails.txt")
    if only_prod in ("@fill", "fill", "__fill__") and not pairs_file:
        pairs_file = os.path.join(here, "_fill_gaps.txt")
    if (args.scope or "").lower() == "retry" and not pairs_file:
        pairs_file = os.path.join(here, "_retry_fails.txt")
    if (args.scope or "").lower() == "fill" and not pairs_file:
        pairs_file = os.path.join(here, "_fill_gaps.txt")

    if pairs_file:
        if not os.path.isfile(pairs_file):
            raise SystemExit("pairs file missing: %s" % pairs_file)
        pairs = load_pairs(pairs_file)
        print("[info] pairs-file %s (%d)" % (pairs_file, len(pairs)), file=sys.stderr)
        node_by_ios = {n["ios"]: n for n in NODES}
        for pt, ios in pairs:
            n = node_by_ios.get(ios) or {
                "out": ios,
                "ios": ios,
                "coverage": "retry",
                "needs_apfs": False,
            }
            if args.skip_ipsw_check:
                vers = None
            else:
                if pt not in cache:
                    cache[pt] = firmware_versions(pt)
                vers = cache[pt]
            buildid = ""
            if vers is not None:
                if ios not in vers:
                    print("[skip] %s no iOS %s" % (pt, ios), file=sys.stderr)
                    continue
                buildid = vers[ios]
            needs_apfs = bool(n.get("needs_apfs"))
            t = parse_ios_tuple(ios)
            if t and t >= (16, 1, 0):
                needs_apfs = True
            jobs.append(
                {
                    "product": pt,
                    "ios": ios,
                    "out": n.get("out") or ios,
                    "buildid": buildid,
                    "needs_apfs": needs_apfs,
                    "coverage": n.get("coverage", ""),
                    "name": ("%s__%s" % (pt, n.get("out") or ios)).replace(",", "-"),
                }
            )
    else:
        devices = resolve_devices(args.scope, args.only_product)
        nodes = resolve_nodes(args.only_ios, args.include_apfs)

        # smoke：默认只打 15.0
        if (args.scope or "").lower() == "smoke" and not args.only_ios.strip():
            nodes = [n for n in NODES if n["out"] == "15.0"]

        for pt in devices:
            if args.skip_ipsw_check:
                vers = None
            else:
                if pt not in cache:
                    cache[pt] = firmware_versions(pt)
                vers = cache[pt]
            for n in nodes:
                ios = n["ios"]
                out = n["out"]
                buildid = ""
                if vers is not None:
                    if ios not in vers:
                        print("[skip] %s no iOS %s" % (pt, ios), file=sys.stderr)
                        continue
                    buildid = vers[ios]
                needs_apfs = bool(n.get("needs_apfs"))
                t = parse_ios_tuple(ios)
                if t and t >= (16, 1, 0):
                    needs_apfs = True
                jobs.append(
                    {
                        "product": pt,
                        "ios": ios,
                        "out": out,
                        "buildid": buildid,
                        "needs_apfs": needs_apfs,
                        "coverage": n.get("coverage", ""),
                        "name": ("%s__%s" % (pt, out)).replace(",", "-"),
                    }
                )

    matrix = {"include": jobs}
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(matrix, f, ensure_ascii=False, indent=2)

    # GitHub Actions: 写到 GITHUB_OUTPUT（heredoc，避免 JSON 特殊字符问题）
    gho = os.environ.get("GITHUB_OUTPUT")
    if gho:
        compact = json.dumps(matrix, separators=(",", ":"), ensure_ascii=False)
        with open(gho, "a", encoding="utf-8") as f:
            f.write("matrix<<EOF_MATRIX\n")
            f.write(compact + "\n")
            f.write("EOF_MATRIX\n")
            f.write("count=%d\n" % len(jobs))

    print("[ok] jobs=%d -> %s" % (len(jobs), args.out), file=sys.stderr)
    if not jobs:
        print("[err] empty matrix — nothing to build", file=sys.stderr)
        sys.exit(2)
    print(json.dumps({"count": len(jobs), "sample": jobs[:3]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
