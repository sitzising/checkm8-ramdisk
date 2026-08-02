#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""为 macOS APFS GHA 生成矩阵（读 pairs.txt，校验 ipsw.me）。"""
from __future__ import print_function

import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request

UA = "ac-macos-apfs-plan"


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
        if ver and build and re.match(r"^\d+(\.\d+){0,3}$", ver):
            out.setdefault(ver, build)
    return out


def resolve_ios(vers, want):
    if want in vers:
        return want, vers[want]
    # 16.7.8 → 最高 16.7.x
    if want.startswith("16.7"):
        cands = [v for v in vers if v.startswith("16.7.")]
        if cands:
            cands.sort(key=lambda s: [int(x) for x in s.split(".")])
            v = cands[-1]
            return v, vers[v]
    if want == "16.4":
        cands = [v for v in vers if v == "16.4" or v.startswith("16.4.")]
        if cands:
            cands.sort(key=lambda s: [int(x) for x in s.split(".")])
            v = cands[-1]
            return v, vers[v]
    return None, ""


def load_pairs(path):
    pairs = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "|" not in line:
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) < 2:
                continue
            pt = parts[0].replace(".", ",")
            ios = parts[1]
            out = parts[2] if len(parts) >= 3 and parts[2] else ios
            pairs.append((pt, ios, out))
    return pairs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--pairs-file",
        default=os.environ.get(
            "PAIRS_FILE",
            os.path.join(os.path.dirname(os.path.abspath(__file__)), "pairs.txt"),
        ),
    )
    ap.add_argument("--only-product", default=os.environ.get("ONLY_PRODUCT", ""))
    ap.add_argument("--only-ios", default=os.environ.get("ONLY_IOS", ""))
    ap.add_argument("--out", default=os.environ.get("MATRIX_OUT", "matrix.json"))
    ap.add_argument("--skip-ipsw-check", action="store_true")
    args = ap.parse_args()

    pairs = load_pairs(args.pairs_file)
    # 机型用空白分隔，保留逗号（iPhone10,6）；勿把逗号当分隔符
    only_p = set(
        x.strip().replace(".", ",")
        for x in (args.only_product or "").split()
        if x.strip()
    )
    only_i = set(x.strip() for x in (args.only_ios or "").split() if x.strip())
    if only_p:
        pairs = [p for p in pairs if p[0] in only_p]
    if only_i:
        pairs = [p for p in pairs if p[1] in only_i or p[2] in only_i]
    print(
        "[info] pairs=%d only_product=%r only_ios=%r"
        % (len(pairs), sorted(only_p), sorted(only_i)),
        file=sys.stderr,
    )

    cache = {}
    jobs = []
    for pt, ios, out in pairs:
        if args.skip_ipsw_check:
            build_ios, buildid = ios, ""
        else:
            if pt not in cache:
                cache[pt] = firmware_versions(pt)
            build_ios, buildid = resolve_ios(cache[pt], ios)
            if not build_ios:
                print("[skip] %s no iOS %s" % (pt, ios), file=sys.stderr)
                continue
            if build_ios != ios:
                print("[resolve] %s %s → build %s (out=%s)" % (pt, ios, build_ios, out), file=sys.stderr)
        jobs.append(
            {
                "product": pt,
                "ios": build_ios,
                "out": out,
                "buildid": buildid,
                "name": ("%s__%s" % (pt, out)).replace(",", "-"),
            }
        )

    matrix = {"include": jobs}
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(matrix, f, ensure_ascii=False, indent=2)

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
        sys.exit(2)
    print(json.dumps({"count": len(jobs), "sample": jobs[:3]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
