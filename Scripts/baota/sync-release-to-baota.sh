#!/usr/bin/env bash
# 在宝塔服务器上：把 GitHub Release 全量同步到本地 ramdisks/（一次拉齐，避免首用户等待）
# 用法:
#   bash sync-release-to-baota.sh
#   bash sync-release-to-baota.sh ramdisk-20260802-0102
#   GH_MIRROR=https://ghfast.top/ bash sync-release-to-baota.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# 若脚本在 Scripts/baota 仓库副本里跑，目标目录可覆盖
DEST="${CHECKM8_DOWN:-$ROOT}"
TAG="${1:-latest}"
REPO="${GITHUB_REPO:-sitzising/checkm8-ramdisk}"
MIRROR="${GH_MIRROR:-https://ghfast.top/}"
MIRROR="${MIRROR%/}/"

if [[ ! -f "$DEST/gha-index.json" ]]; then
  echo "missing $DEST/gha-index.json — copy from Release first"
  exit 1
fi

python3 - <<'PY' "$DEST" "$REPO" "$TAG" "$MIRROR"
import json, os, sys, urllib.request
dest, repo, tag, mirror = sys.argv[1:5]
idx = json.load(open(os.path.join(dest, "gha-index.json"), encoding="utf-8"))
ua = {"User-Agent": "AC-Tools-Baota-Sync/1.0"}

def url_for(pt, ios):
    pt_dot = pt.replace(",", ".")
    name = f"{pt_dot}-{ios}.zip"
    if tag == "latest":
        origin = f"https://github.com/{repo}/releases/latest/download/{name}"
    else:
        origin = f"https://github.com/{repo}/releases/download/{tag}/{name}"
    return name, origin, mirror + origin

ok = fail = 0
for pt, info in sorted(idx.get("devices", {}).items()):
    for ios in info.get("versions", []):
        name, origin, proxied = url_for(pt, ios)
        pt_dot = pt.replace(",", ".")
        out_dir = os.path.join(dest, "ramdisks", pt_dot)
        os.makedirs(out_dir, exist_ok=True)
        out = os.path.join(out_dir, f"{ios}.zip")
        if os.path.isfile(out) and os.path.getsize(out) > 1_000_000:
            print(f"[skip] {pt} @{ios}")
            ok += 1
            continue
        print(f"[get] {pt} @{ios}")
        done = False
        for u in (proxied, origin):
            try:
                req = urllib.request.Request(u, headers=ua)
                with urllib.request.urlopen(req, timeout=600) as r, open(out + ".part", "wb") as f:
                    while True:
                        chunk = r.read(1024 * 1024)
                        if not chunk:
                            break
                        f.write(chunk)
                if os.path.getsize(out + ".part") < 1_000_000:
                    os.remove(out + ".part")
                    continue
                os.replace(out + ".part", out)
                done = True
                break
            except Exception as e:
                print(f"  ! {u}: {e}")
                if os.path.exists(out + ".part"):
                    os.remove(out + ".part")
        if done:
            ok += 1
        else:
            fail += 1
print(f"done ok={ok} fail={fail}")
sys.exit(1 if fail and not ok else 0)
PY
