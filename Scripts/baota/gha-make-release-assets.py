#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Normalize Actions-collected ramdisk zips into Release assets + manifest.json.

Input zip names (any of):
  iPhone10-6_15.0.zip
  iPhone10.6-15.0.zip
  iPhone10,6_15.0.zip
  nested paths from download-artifact

Output (flat, GitHub Release-friendly):
  iPhone10.6-15.0.zip
  manifest.json   — devices[pt].versions[ios] = { url, size }
  SHA256SUMS.txt
  RELEASE_NOTES.md
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

NAME_RE = re.compile(
    r"^(?P<body>.+?)[_-](?P<ios>\d+(?:\.\d+)*)\.zip$",
    re.IGNORECASE,
)


def parse_zip_name(name: str) -> tuple[str, str] | None:
    m = NAME_RE.match(name)
    if not m:
        return None
    body = m.group("body").replace(",", "-").replace(".", "-")
    ios = m.group("ios")
    parts = body.split("-")
    if len(parts) < 2:
        return None
    num = parts[-1]
    family = "-".join(parts[:-1])
    return f"{family},{num}", ios


def asset_name(pt: str, ios: str) -> str:
    return f"{pt.replace(',', '.')}-{ios}.zip"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="indir", required=True, help="collected zips root")
    ap.add_argument("--out", dest="outdir", required=True, help="release-assets dir")
    ap.add_argument("--repo", required=True, help="owner/repo")
    ap.add_argument("--tag", required=True, help="release tag")
    ap.add_argument("--run-url", default="", help="Actions run URL for notes")
    args = ap.parse_args()

    indir = Path(args.indir)
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    devices: dict[str, dict] = {}
    copied = 0
    for z in sorted(indir.rglob("*.zip")):
        if z.name.lower() in {"checkm8-ramdisks-bundle.zip"}:
            continue
        parsed = parse_zip_name(z.name)
        if not parsed:
            print(f"[skip] unrecognized: {z}", flush=True)
            continue
        pt, ios = parsed
        dest_name = asset_name(pt, ios)
        dest = outdir / dest_name
        shutil.copy2(z, dest)
        size = dest.stat().st_size
        url = f"https://github.com/{args.repo}/releases/download/{args.tag}/{dest_name}"
        latest_url = (
            f"https://github.com/{args.repo}/releases/latest/download/{dest_name}"
        )
        devices.setdefault(pt, {"versions": {}, "defaultIos": ios})
        devices[pt]["versions"][ios] = {
            "url": url,
            "latestUrl": latest_url,
            "size": size,
            "file": dest_name,
        }
        # prefer highest as default
        cur = devices[pt].get("defaultIos") or ios
        try:
            if [int(x) for x in ios.split(".")] > [int(x) for x in str(cur).split(".")]:
                devices[pt]["defaultIos"] = ios
        except Exception:
            devices[pt]["defaultIos"] = ios
        copied += 1
        print(f"[ok] {z.name} → {dest_name} ({size // (1024*1024)} MB)", flush=True)

    if copied == 0:
        print("No release assets produced", flush=True)
        return 1

    base_latest = f"https://github.com/{args.repo}/releases/latest/download/"
    manifest = {
        "baseUrl": base_latest,
        "releaseTag": args.tag,
        "repo": args.repo,
        "source": "github-release",
        "devices": devices,
    }
    (outdir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    lines = []
    for f in sorted(outdir.iterdir()):
        if f.is_file() and f.name != "SHA256SUMS.txt":
            lines.append(f"{sha256_file(f)}  {f.name}")
    (outdir / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")

    # compact index for UI list
    gha_index = {
        "ok": True,
        "source": "github-release",
        "repo": args.repo,
        "tag": args.tag,
        "baseUrl": base_latest,
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
    (outdir / "gha-index.json").write_text(
        json.dumps(gha_index, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    notes = []
    notes.append(f"# Checkm8 Ramdisks `{args.tag}`\n")
    notes.append("A7–A11 SSH ramdisk packs (SSHRD_Script_Lite). **Individual zips** — no 5GB bundle.\n")
    if args.run_url:
        notes.append(f"- Build run: {args.run_url}\n")
    notes.append(f"- Manifest: `{base_latest}manifest.json`\n")
    notes.append(f"- Index: `{base_latest}gha-index.json`\n")
    notes.append(f"- Asset name: `iPhone10.6-16.0.zip` → ProductType `iPhone10,6` @ `16.0`\n")
    notes.append(f"\n## Devices ({len(devices)})\n")
    for pt, info in sorted(devices.items()):
        vers = sorted(
            info["versions"].keys(),
            key=lambda v: [int(x) for x in v.split(".")],
            reverse=True,
        )
        notes.append(f"- `{pt}`: {', '.join(vers)}\n")
    (outdir / "RELEASE_NOTES.md").write_text("".join(notes), encoding="utf-8")

    print(f"[done] {copied} assets → {outdir}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
