#!/usr/bin/env python3
"""Rebuild manifest.json + gha-index.json from all zip assets on a Release."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import tempfile
from pathlib import Path

NAME_RE = re.compile(
    r"^(?P<body>.+?)-(?P<ios>\d+(?:\.\d+)*)\.zip$",
    re.IGNORECASE,
)


def parse_asset(name: str):
    m = NAME_RE.match(name)
    if not m:
        return None
    body = m.group("body")
    ios = m.group("ios")
    if "." not in body:
        return None
    family, num = body.rsplit(".", 1)
    if not num.isdigit():
        return None
    return f"{family},{num}", ios


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--tag", required=True)
    args = ap.parse_args()

    raw = subprocess.check_output(
        ["gh", "release", "view", args.tag, "-R", args.repo, "--json", "assets"],
        text=True,
    )
    assets = json.loads(raw)["assets"]
    devices: dict = {}
    for a in assets:
        name = a["name"]
        if not name.endswith(".zip"):
            continue
        parsed = parse_asset(name)
        if not parsed:
            continue
        pt, ios = parsed
        size = a.get("size") or 0
        url = f"https://github.com/{args.repo}/releases/download/{args.tag}/{name}"
        latest = f"https://github.com/{args.repo}/releases/latest/download/{name}"
        devices.setdefault(pt, {"versions": {}, "defaultIos": ios})
        devices[pt]["versions"][ios] = {
            "url": url,
            "latestUrl": latest,
            "size": size,
            "file": name,
        }
        cur = devices[pt].get("defaultIos") or ios
        try:
            if [int(x) for x in ios.split(".")] > [int(x) for x in str(cur).split(".")]:
                devices[pt]["defaultIos"] = ios
        except Exception:
            devices[pt]["defaultIos"] = ios

    base = f"https://github.com/{args.repo}/releases/latest/download/"
    manifest = {
        "baseUrl": base,
        "releaseTag": args.tag,
        "repo": args.repo,
        "source": "github-release",
        "devices": devices,
    }
    gha_index = {
        "ok": True,
        "source": "github-release",
        "repo": args.repo,
        "tag": args.tag,
        "baseUrl": base,
        "devices": {
            pt: {
                "versions": sorted(
                    info["versions"].keys(),
                    key=lambda v: [int(x) for x in v.split(".")],
                    reverse=True,
                ),
                "defaultIos": info.get("defaultIos"),
            }
            for pt, info in sorted(devices.items())
        },
    }

    td = Path(tempfile.mkdtemp(prefix="rd-idx-"))
    man = td / "manifest.json"
    idx = td / "gha-index.json"
    man.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    idx.write_text(json.dumps(gha_index, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[rebuild] {len(devices)} devices from release {args.tag}", flush=True)
    subprocess.run(
        ["gh", "release", "upload", args.tag, "-R", args.repo, str(man), str(idx), "--clobber"],
        check=True,
    )
    print("[rebuild] uploaded manifest.json + gha-index.json", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
