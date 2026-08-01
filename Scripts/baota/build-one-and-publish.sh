#!/usr/bin/env bash
# 构建单个机型并刷新 manifest.json
# 用法: bash build-one-and-publish.sh iPhone10,2 15.7.1
set -euo pipefail

PT="${1:-iPhone10,2}"
IOS="${2:-15.7.1}"
ROOT="${CHECKM8_ROOT:-/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPAT="${ROOT}/build/compat-lib"
LOG="${ROOT}/build-one-$(echo "$PT" | tr ',/' '__')-${IOS}.log"

export LD_LIBRARY_PATH="${COMPAT}:${LD_LIBRARY_PATH:-}"
export SKIP_DEPS="${SKIP_DEPS:-1}"

mkdir -p "$ROOT/ramdisks" "$ROOT/build"
exec > >(tee -a "$LOG") 2>&1

echo "======== $(date) build-one $PT @ $IOS ========"
df -h / | tail -1

# 部署 API
cp -f "${SCRIPT_DIR}/checkm8-ramdisk.php" "${ROOT}/ramdisk.php"

# 清理空间
yum clean all >/dev/null 2>&1 || true
rm -rf /tmp/gcc9ex /tmp/libstd.deb /tmp/libstd.rpm /var/cache/yum/* 2>/dev/null || true

bash "${SCRIPT_DIR}/cloud-build-checkm8.sh" "$PT" "$IOS"

# 同步 default 包
ZIP="${ROOT}/ramdisks/${PT}/${IOS}.zip"
if [[ -f "$ZIP" ]]; then
  cp -f "$ZIP" "${ROOT}/ramdisks/${PT}/default.zip"
  cp -f "$ZIP" "${ROOT}/ramdisks/${PT}.zip"
fi

# 生成 manifest.json
python3 - <<'PY'
import json, os, glob
root = os.environ.get("CHECKM8_ROOT", "/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down")
base = "https://tool.a-cheng.cn/ramdisk/checkm8-down/"
rd = os.path.join(root, "ramdisks")
devices = {}
for d in sorted(glob.glob(os.path.join(rd, "*"))):
    if not os.path.isdir(d):
        continue
    pt = os.path.basename(d)
    versions = {}
    for z in sorted(glob.glob(os.path.join(d, "*.zip"))):
        ver = os.path.splitext(os.path.basename(z))[0]
        if ver == "default":
            continue
        versions[ver] = f"ramdisks/{pt}/{ver}.zip"
    if not versions:
        continue
    # 优先 15.7.1
    default = "15.7.1" if "15.7.1" in versions else sorted(versions.keys(), reverse=True)[0]
    devices[pt] = {
        "defaultIos": default,
        "versions": versions,
        "url": f"ramdisks/{pt}.zip" if os.path.isfile(os.path.join(rd, pt + ".zip")) else f"ramdisks/{pt}/{default}.zip",
    }
# 顶层 zip
for z in sorted(glob.glob(os.path.join(rd, "*.zip"))):
    pt = os.path.splitext(os.path.basename(z))[0]
    if pt in devices:
        continue
    devices[pt] = {"defaultIos": "default", "url": f"ramdisks/{pt}.zip"}
out = {"baseUrl": base, "devices": devices, "updatedAt": __import__("datetime").datetime.utcnow().isoformat() + "Z"}
path = os.path.join(root, "manifest.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print("[OK] manifest:", path, "devices=", len(devices))
PY

echo "======== done ========"
ls -lah "${ROOT}/ramdisks/${PT}/" 2>/dev/null || true
curl -sS "https://tool.a-cheng.cn/ramdisk/checkm8-down/ramdisk.php?productType=${PT}&ios=${IOS}" | head -c 400; echo
curl -sI "https://tool.a-cheng.cn/ramdisk/checkm8-down/manifest.json" | head -5
