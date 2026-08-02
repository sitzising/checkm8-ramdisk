#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Identify & download checkm8 ramdisks from a GitHub Actions run.

Artifact naming (from build-checkm8-ramdisk.yml):
  ramdisk-iPhone10-6__16.0  →  ProductType iPhone10,6  /  iOS 16.0

Examples:
  # List what's available on the run (skip 5.5GB bundle)
  python sync-gha-ramdisks.py --run 30718007339 --list

  # Download one device's packs into baota layout
  python sync-gha-ramdisks.py --run 30718007339 --product iPhone10,6 --out ./checkm8-down

  # Download all individual ramdisk-* (not the bundle)
  python sync-gha-ramdisks.py --run 30718007339 --all --out ./checkm8-down

Requires: gh (authenticated), Python 3.8+
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

REPO_DEFAULT = "sitzising/checkm8-ramdisk"
NAME_RE = re.compile(
    r"^ramdisk-(?P<body>.+?)__(?P<ios>\d+(?:\.\d+)*)$",
    re.IGNORECASE,
)


def run_gh(args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    cmd = ["gh", *args]
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def fetch_artifacts(repo: str, run_id: str) -> list[dict]:
    # paginate manually via Link is handled by gh --paginate
    proc = run_gh(
        [
            "api",
            "--paginate",
            f"repos/{repo}/actions/runs/{run_id}/artifacts",
        ]
    )
    # --paginate may concatenate JSON objects; normalize
    text = proc.stdout.strip()
    arts: list[dict] = []
    if not text:
        return arts
    # gh --paginate returns concatenated JSON arrays/objects
    decoder = json.JSONDecoder()
    idx = 0
    while idx < len(text):
        while idx < len(text) and text[idx].isspace():
            idx += 1
        if idx >= len(text):
            break
        obj, end = decoder.raw_decode(text, idx)
        idx = end
        if isinstance(obj, dict) and "artifacts" in obj:
            arts.extend(obj["artifacts"])
        elif isinstance(obj, list):
            arts.extend(obj)
    return arts


def parse_artifact_name(name: str) -> tuple[str, str] | None:
    """ramdisk-iPhone10-6__16.0 → ('iPhone10,6', '16.0')"""
    m = NAME_RE.match(name.strip())
    if not m:
        return None
    body = m.group("body")
    ios = m.group("ios")
    # iPhone10-6 / iPad7-11 / iPod9-1 → restore comma ProductType
    # body uses '-' for the ProductType comma
    parts = body.split("-")
    if len(parts) < 2:
        return None
    # last segment is board number; rest is family (iPhone10, iPad7, …)
    num = parts[-1]
    family = "-".join(parts[:-1])
    # family itself may be iPhone10 (no extra dashes) — good
    # rare: nothing else
    pt = f"{family},{num}"
    return pt, ios


def build_index(artifacts: list[dict]) -> dict:
    """productType → { ios → {id, name, size} }"""
    devices: dict[str, dict] = {}
    for a in artifacts:
        name = a.get("name") or ""
        if not name.startswith("ramdisk-"):
            continue
        if a.get("expired"):
            continue
        parsed = parse_artifact_name(name)
        if not parsed:
            continue
        pt, ios = parsed
        entry = {
            "artifactId": a["id"],
            "name": name,
            "size": a.get("size_in_bytes") or 0,
        }
        devices.setdefault(pt, {})[ios] = entry
    return devices


def write_gha_index(out_root: Path, run_id: str, repo: str, devices: dict) -> Path:
    payload = {
        "ok": True,
        "source": f"https://github.com/{repo}/actions/runs/{run_id}",
        "repo": repo,
        "runId": run_id,
        "devices": {
            pt: {
                "versions": sorted(vers.keys(), key=lambda v: [int(x) for x in v.split(".")], reverse=True),
                "artifacts": {
                    ios: {
                        "id": meta["artifactId"],
                        "name": meta["name"],
                        "size": meta["size"],
                    }
                    for ios, meta in vers.items()
                },
            }
            for pt, vers in sorted(devices.items())
        },
    }
    path = out_root / "gha-index.json"
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return path


def download_artifact(repo: str, artifact_id: int, dest_dir: Path) -> Path:
    """Download artifact zip via gh api → returns path to downloaded zip bytes file."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    out_zip = dest_dir / f"artifact-{artifact_id}.zip"
    # gh api redirects to signed URL; use --jq empty and raw
    url = f"repos/{repo}/actions/artifacts/{artifact_id}/zip"
    with open(out_zip, "wb") as fh:
        proc = subprocess.run(
            ["gh", "api", url],
            check=True,
            stdout=fh,
            stderr=subprocess.PIPE,
        )
    if out_zip.stat().st_size < 1000:
        raise RuntimeError(f"artifact {artifact_id} too small / failed")
    return out_zip


def extract_ramdisk_zip(artifact_zip: Path, staging: Path) -> Path | None:
    """Actions artifact is a zip-of-zip; find inner *.zip with img4 or the payload zip."""
    staging.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(artifact_zip, "r") as zf:
        zf.extractall(staging)
    # Prefer a single .zip inside
    zips = list(staging.rglob("*.zip"))
    img4 = list(staging.rglob("*.img4")) + list(staging.rglob("*.IMG4"))
    if zips:
        # pick largest
        return max(zips, key=lambda p: p.stat().st_size)
    if img4:
        # re-zip contents for baota layout
        packed = staging / "_packed.zip"
        with zipfile.ZipFile(packed, "w", zipfile.ZIP_DEFLATED) as zf:
            for f in staging.rglob("*"):
                if f.is_file() and f.suffix.lower() in {".img4", ".im4p", ".trustcache", ".dmg"}:
                    zf.write(f, f.name)
        return packed
    return None


def place_into_baota(payload_zip: Path, out_root: Path, product_type: str, ios: str) -> Path:
    pt_dot = product_type.replace(",", ".")
    dest_dir = out_root / "ramdisks" / pt_dot
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"{ios}.zip"
    shutil.copy2(payload_zip, dest)
    return dest


def main() -> int:
    ap = argparse.ArgumentParser(description="Sync ramdisks from a GHA run")
    ap.add_argument("--repo", default=REPO_DEFAULT)
    ap.add_argument("--run", required=True, help="Actions run id, e.g. 30718007339")
    ap.add_argument("--list", action="store_true", help="Only print index")
    ap.add_argument("--product", action="append", default=[], help="ProductType filter (repeatable)")
    ap.add_argument("--ios", action="append", default=[], help="iOS filter (repeatable)")
    ap.add_argument("--all", action="store_true", help="Download all ramdisk-* artifacts")
    ap.add_argument("--out", default=".", help="Output root (writes ramdisks/ + gha-index.json)")
    ap.add_argument("--index-only", action="store_true", help="Write gha-index.json only")
    args = ap.parse_args()

    print(f"[gha] listing artifacts run={args.run} repo={args.repo}", flush=True)
    arts = fetch_artifacts(args.repo, args.run)
    devices = build_index(arts)
    if not devices:
        print("No ramdisk-* artifacts found (expired or wrong run).", file=sys.stderr)
        return 1

    out_root = Path(args.out).resolve()
    out_root.mkdir(parents=True, exist_ok=True)
    idx_path = write_gha_index(out_root, args.run, args.repo, devices)
    print(f"[gha] index → {idx_path}", flush=True)

    # pretty list
    for pt in sorted(devices.keys()):
        vers = sorted(devices[pt].keys(), key=lambda v: [int(x) for x in v.split(".")], reverse=True)
        print(f"  {pt}: {', '.join(vers)}")

    if args.list or args.index_only:
        return 0

    want_pts = {p.replace(".", ",") for p in args.product}
    want_ios = set(args.ios)
    if not args.all and not want_pts:
        print("Specify --product / --all, or use --list", file=sys.stderr)
        return 2

    jobs = []
    for pt, vers in devices.items():
        if want_pts and pt not in want_pts:
            continue
        for ios, meta in vers.items():
            if want_ios and ios not in want_ios:
                continue
            jobs.append((pt, ios, meta))

    print(f"[gha] downloading {len(jobs)} pack(s)…", flush=True)
    ok = 0
    for pt, ios, meta in jobs:
        print(f"  ↓ {pt} @{ios}  ({meta['name']}, {meta['size'] // (1024*1024)} MB)", flush=True)
        with tempfile.TemporaryDirectory(prefix="gha-rd-") as td:
            td_path = Path(td)
            try:
                art_zip = download_artifact(args.repo, meta["artifactId"], td_path / "dl")
                payload = extract_ramdisk_zip(art_zip, td_path / "ex")
                if not payload:
                    print(f"    ! no zip/img4 inside artifact", file=sys.stderr)
                    continue
                dest = place_into_baota(payload, out_root, pt, ios)
                print(f"    → {dest}", flush=True)
                ok += 1
            except Exception as ex:
                print(f"    ! {ex}", file=sys.stderr)
    print(f"[gha] done: {ok}/{len(jobs)} → {out_root / 'ramdisks'}", flush=True)
    return 0 if ok or not jobs else 1


if __name__ == "__main__":
    raise SystemExit(main())
