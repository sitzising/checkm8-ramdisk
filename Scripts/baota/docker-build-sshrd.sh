#!/usr/bin/env bash
# Docker(Ubuntu 22.04) + SSHRD_Script_Lite 云端离线构建
# 用法: docker-build-sshrd.sh <ProductType> <IOS> [BUILDID] [OUT_IOS]
#   OUT_IOS = 发布 zip 文件名版本（默认与 IOS 相同），如 IOS=15.0 OUT=15.0
set -euo pipefail
ROOT="${CHECKM8_ROOT:-/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down}"
OUT="${ROOT}/ramdisks"
BUILD="${ROOT}/build"
LITE_REPO="${LITE_REPO:-https://github.com/mast3rz3ro/SSHRD_Script_Lite.git}"
DK_REPO="${DK_REPO:-https://github.com/dkxuanye/SSHRD.git}"
PT="${1:?productType e.g. iPhone10,2}"
IOS="${2:?ios e.g. 16.0}"
BUILDID="${3:-}"
OUT_IOS="${4:-$IOS}"
# 禁止点号 ProductType 路径（须 iPhone/iPad/iPod + 逗号）
if [[ ! "$PT" =~ ^(iPhone|iPad|iPod)[0-9]+,[0-9]+$ ]]; then
  echo "[FAIL] ProductType must be like iPhone10,2 / iPad6,11 (comma), got: $PT"
  exit 9
fi
LOG="${ROOT}/docker-build-$(echo "$PT" | tr ',/' '__')-${OUT_IOS}.log"
mkdir -p "$OUT" "$BUILD"
exec > >(tee -a "$LOG") 2>&1
echo "======== $(date) docker Lite build $PT @ $IOS (out=$OUT_IOS buildid=${BUILDID:-auto}) ========"
df -h / | tail -1

if [[ ! -d "${BUILD}/SSHRD_dkxuanye/.git" ]]; then
  timeout 60 git clone --depth 1 "$DK_REPO" "${BUILD}/SSHRD_dkxuanye" || echo "[warn] dkxuanye clone skipped"
else
  (cd "${BUILD}/SSHRD_dkxuanye" && timeout 30 git pull --ff-only) || true
fi

IMG=ubuntu:22.04
docker pull "$IMG"
docker rm -f ac-sshrd-build 2>/dev/null || true

HOST_LITE="${BUILD}/SSHRD_Script_Lite"
MOUNT_LITE=""
if [[ -d "$HOST_LITE/.git" || -x "$HOST_LITE/sshrd_lite.sh" ]]; then
  MOUNT_LITE="-v ${HOST_LITE}:/lite:ro"
fi

docker run --rm --name ac-sshrd-build \
  -v "${OUT}:/out/ramdisks" \
  -v "${BUILD}/lite-cache:/work" \
  $MOUNT_LITE \
  -e PT="$PT" -e IOS="$IOS" -e BUILDID="$BUILDID" -e OUT_IOS="$OUT_IOS" -e LITE_REPO="$LITE_REPO" \
  "$IMG" bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ca-certificates zip python3 libusb-1.0-0 libssl3 \
  || apt-get install -y -qq git curl ca-certificates zip python3 libusb-1.0-0 libssl1.1
mkdir -p /out/ramdisks /work
if [[ ! -x /lite/sshrd_lite.sh ]]; then
  echo "[info] host Lite missing, clone into /work/lite"
  if [[ ! -d /work/lite/.git ]]; then
    git clone --recursive "$LITE_REPO" /work/lite
  else
    (cd /work/lite && git pull --ff-only) || true
    (cd /work/lite && git submodule update --init --recursive) || true
  fi
  LITE=/work/lite
else
  echo "[info] copy host Lite to /work/lite"
  rm -rf /work/lite
  cp -a /lite /work/lite
  LITE=/work/lite
fi
cd "$LITE"
rm -rf "$LITE/2_ssh_ramdisk" "$LITE/1_prepare_ramdisk" 2>/dev/null || true
mkdir -p "$LITE/2_ssh_ramdisk"
chmod +x ./*.sh 2>/dev/null || true
# 若根目录 parser 缺失，从 submodule 拷贝（保持宿主机已打补丁的版本优先）
if [[ ! -s ./ifirmware_parser.sh ]] && [[ -s ./ifirmware_parser/ifirmware_parser.sh ]]; then
  cp -f ./ifirmware_parser/ifirmware_parser.sh ./
fi
if [[ -n "${BUILDID:-}" ]]; then
  echo "[run] ./sshrd_lite.sh -p $PT -s $IOS -b $BUILDID"
  set +e
  ./sshrd_lite.sh -p "$PT" -s "$IOS" -b "$BUILDID"
else
  echo "[run] ./sshrd_lite.sh -p $PT -s $IOS"
  set +e
  ./sshrd_lite.sh -p "$PT" -s "$IOS"
fi
code=$?
set -e
if [[ $code -ne 0 ]]; then
  echo "[FAIL] sshrd_lite exit=$code"
  exit $code
fi
src=$(find "$LITE/2_ssh_ramdisk" -maxdepth 1 -type d -name "${PT}_*" 2>/dev/null | head -n1 || true)
if [[ -z "$src" || ! -f "$src/iBSS.img4" ]]; then
  echo "[FAIL] no matching ${PT}_* output under 2_ssh_ramdisk"
  find "$LITE/2_ssh_ramdisk" -maxdepth 2 -type f -name "*.img4" 2>/dev/null | head
  exit 2
fi
base=$(basename "$src")
case "$base" in
  ${PT}_*) ;;
  *) echo "[FAIL] src basename mismatch: $base"; exit 3 ;;
esac
echo "[OK] src=$src"
# 必备产物
for need in iBSS.img4 iBEC.img4 ramdisk.img4 devicetree.img4 kernelcache.img4; do
  if [[ ! -f "$src/$need" ]]; then
    echo "[FAIL] missing $need in $src"
    exit 4
  fi
done
mkdir -p "/out/ramdisks/${PT}"
zip="/out/ramdisks/${PT}/${OUT_IOS}.zip"
tmpzip="/out/ramdisks/${PT}/.${OUT_IOS}.zip.partial"
rm -f "$tmpzip"
(cd "$src" && zip -q -r "$tmpzip" iBSS.img4 iBEC.img4 ramdisk.img4 devicetree.img4 kernelcache.img4 trustcache.img4 logo.img4 bootlogo.img4 2>/dev/null || zip -q -r "$tmpzip" .)
mv -f "$tmpzip" "$zip"
# default 由主控 refresh；此处先占位（不覆盖其它版本 zip）
cp -f "$zip" "/out/ramdisks/${PT}/default.zip"
# 顶层兼容副本
cp -f "$zip" "/out/ramdisks/${PT}.zip"
sync
ls -lah "$zip"
unzip -l "$zip" | head -20
# 只删 IPSW，绝不扫 /out
find "$LITE" -name "*.ipsw" -delete 2>/dev/null || true
find /work/lite -name "*.ipsw" -delete 2>/dev/null || true
rm -rf "$LITE/2_ssh_ramdisk" "$LITE/1_prepare_ramdisk" 2>/dev/null || true
'

# 轻量刷新 manifest（完整 coverage 由 build_a11_ramdisks.py 写入）
python3 - <<PY
import json, os, glob, datetime
root = "$ROOT"
base = "https://tool.a-cheng.cn/ramdisk/checkm8-down/"
rd = os.path.join(root, "ramdisks")
coverage = {
  "11.4.1": "iOS 11.0 ~ 11.4.1",
  "12.4.1": "iOS 12.0 ~ 12.4.1",
  "13.7": "iOS 13.0 ~ 13.7",
  "14.0": "iOS 14.0 ~ 14.8.1",
  "15.0": "iOS 15.0 ~ 15.7.x",
  "16.0": "iOS 16.0 ~ 16.3.1",
  "16.7.8": "iOS 16.4 ~ 16.7.x",
}
prefer_order = ["16.7.8", "16.0", "15.0", "14.0", "13.7", "12.4.1", "11.4.1"]
devices = {}
for d in sorted(glob.glob(os.path.join(rd, "*"))):
    if not os.path.isdir(d):
        continue
    pt = os.path.basename(d)
    if "." in pt and "," not in pt:
        continue
    versions = {}
    for z in sorted(glob.glob(os.path.join(d, "*.zip"))):
        ver = os.path.splitext(os.path.basename(z))[0]
        if ver == "default":
            continue
        if os.path.getsize(z) < 1000:
            continue
        versions[ver] = "ramdisks/%s/%s.zip" % (pt, ver)
    if not versions:
        continue
    default = None
    for p in prefer_order:
        if p in versions:
            default = p
            break
    if not default:
        default = sorted(versions.keys())[-1]
    devices[pt] = {
        "defaultIos": default,
        "versions": versions,
        "url": "ramdisks/%s/%s.zip" % (pt, default),
        "coverage": {k: coverage[k] for k in coverage if k in versions},
    }
out = {
    "baseUrl": base,
    "devices": devices,
    "updatedAt": datetime.datetime.utcnow().isoformat() + "Z",
    "note": "A11 coverage nodes via SSHRD_Script_Lite docker; comma ProductType only",
}
path = os.path.join(root, "manifest.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print("[OK] manifest devices=", len(devices))
PY

echo "======== done $PT @ $IOS -> ${OUT_IOS}.zip ========"
