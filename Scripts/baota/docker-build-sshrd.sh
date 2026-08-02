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

SCRIPT_HOST="$(cd "$(dirname "$0")" && pwd)"
docker run --rm -i --name ac-sshrd-build \
  -v "${OUT}:/out/ramdisks" \
  -v "${BUILD}/lite-cache:/work" \
  -v "${SCRIPT_HOST}:/baota:ro" \
  $MOUNT_LITE \
  -e PT="$PT" -e IOS="$IOS" -e BUILDID="$BUILDID" -e OUT_IOS="$OUT_IOS" -e LITE_REPO="$LITE_REPO" \
  -e USE_GASTER="${USE_GASTER:-0}" \
  -e BOARD="${BOARD:-}" \
  "$IMG" bash -s <<'INNER'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# xz-utils：解压 Linux_pack.tar.xz / sshtars 必需（缺 xz 会导致 tools/Linux/jq 缺失）
apt-get install -y -qq git curl ca-certificates zip unzip xz-utils python3 \
  libusb-1.0-0 libssl3 \
  || apt-get install -y -qq git curl ca-certificates zip unzip xz-utils python3 \
  libusb-1.0-0 libssl1.1
command -v xz >/dev/null || { echo "[FAIL] xz missing after apt"; exit 9; }
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
# 预拉工具包（避免脚本里静默失败后 jq 不存在）
if [[ ! -x ./tools/Linux/jq && ! -x ./tools/Linux/pzb.real ]]; then
  echo "[info] bootstrap Linux_pack.tar.xz"
  curl -fsSL -o Linux_pack.tar.xz \
    "https://raw.githubusercontent.com/mast3rz3ro/sshrd_tools/main/Linux_pack.tar.xz"
  tar -xJf Linux_pack.tar.xz
  rm -f Linux_pack.tar.xz
  chmod +x tools/Linux/* 2>/dev/null || true
fi
[[ -x ./tools/Linux/jq || -x ./tools/Linux/pzb || -x ./tools/Linux/pzb.real ]] \
  || { echo "[FAIL] tools/Linux still missing"; ls -la tools/Linux 2>/dev/null || true; exit 10; }

# 容器内安装 pzb wrapper（修复 -o 目录被忽略）
mkdir -p /tmp/ac-root/build
ln -sfn "$LITE" /tmp/ac-root/build/SSHRD_Script_Lite
CHECKM8_ROOT=/tmp/ac-root bash /baota/patch_pzb_wrapper.sh || true
head -n2 ./tools/Linux/pzb 2>/dev/null | grep -q AC_PZB_WRAPPER \
  && echo "[AC-PZB] wrapper ready" \
  || echo "[AC-PZB] WARN wrapper missing"
# 多板型机型必须 -m（例 iPhone8,1 → n71ap / n71map）
# 可用环境变量 BOARD=n71ap 覆盖；否则用默认表，失败再解析 Available models 重试
default_board() {
  # GSM/Global 板型不同，勿合并（例 10,1=d20ap / 10,4=d201ap）
  case "$1" in
    iPhone10,1) echo d20ap ;;
    iPhone10,4) echo d201ap ;;
    iPhone10,2) echo d21ap ;;
    iPhone10,5) echo d211ap ;;
    iPhone10,3) echo d22ap ;;
    iPhone10,6) echo d221ap ;;
    iPhone9,1) echo d10ap ;;
    iPhone9,3) echo d101ap ;;
    iPhone9,2) echo d11ap ;;
    iPhone9,4) echo d111ap ;;
    iPhone8,1) echo n71ap ;;
    iPhone8,2) echo n66ap ;;
    iPhone8,4) echo n69ap ;;
    iPhone7,1) echo n56ap ;;
    iPhone7,2) echo n61ap ;;
    iPhone6,1) echo n51ap ;;
    iPhone6,2) echo n53ap ;;
    iPad7,11) echo j171ap ;;
    iPad7,12) echo j171aap ;;
    iPad7,1) echo j120ap ;;
    iPad7,2) echo j121ap ;;
    iPad7,3) echo j207ap ;;
    iPad7,4) echo j208ap ;;
    iPad7,5) echo j71bap ;;
    iPad7,6) echo j72bap ;;
    iPad6,11) echo j71sap ;;
    iPad6,12) echo j71tap ;;
    iPad6,3) echo j127ap ;;
    iPad6,4) echo j128ap ;;
    iPad6,7) echo j98aap ;;
    iPad6,8) echo j99aap ;;
    iPad5,1) echo j96ap ;;
    iPad5,2) echo j97ap ;;
    iPad5,3) echo j81ap ;;
    iPad5,4) echo j82ap ;;
    iPad4,1) echo j71ap ;;
    iPad4,2) echo j72ap ;;
    iPad4,3) echo j73ap ;;
    iPad4,4) echo j85ap ;;
    iPad4,5) echo j86ap ;;
    iPad4,6) echo j87ap ;;
    iPad4,7) echo j85map ;;
    iPad4,8) echo j86map ;;
    iPad4,9) echo j87map ;;
    iPod9,1) echo n112ap ;;
    iPod7,1) echo n102ap ;;
    *) echo "" ;;
  esac
}
BOARD="${BOARD:-$(default_board "$PT")}"

# USE_GASTER=1 → sshrd_lite -g（无 wiki 密钥时用 gaster 解密）
EXTRA=()
if [[ "${USE_GASTER:-0}" == "1" ]]; then
  echo "[info] USE_GASTER=1 — sshrd_lite -g"
  EXTRA+=(-g)
  if [[ ! -x ./tools/Linux/gaster && -f ./tools/Linux/gaster ]]; then
    chmod +x ./tools/Linux/gaster || true
  fi
fi
if [[ -n "$BOARD" ]]; then
  echo "[info] BOARD=$BOARD (-m)"
  EXTRA+=(-m "$BOARD")
fi

run_sshrd() {
  local -a cmd=(./sshrd_lite.sh -p "$PT" -s "$IOS")
  [[ -n "${BUILDID:-}" ]] && cmd+=(-b "$BUILDID")
  cmd+=("${EXTRA[@]}")
  echo "[run] ${cmd[*]}"
  "${cmd[@]}"
}

LOG_TRY=/tmp/sshrd-try.log
set +e
run_sshrd 2>&1 | tee "$LOG_TRY"
code=${PIPESTATUS[0]}
set -e
if [[ $code -ne 0 ]] && grep -q "Available models" "$LOG_TRY"; then
  # 例: Available models for 'iPhone8,1': 'n71ap' 'n71map'
  mapfile -t ALTS < <(grep "Available models" "$LOG_TRY" | tail -n1 | grep -oE '[a-z0-9]+ap' | uniq)
  for alt in "${ALTS[@]}"; do
    [[ -n "$alt" && "$alt" != "$BOARD" ]] || continue
    echo "[retry] auto -m $alt (from Available models)"
    EXTRA=()
    [[ "${USE_GASTER:-0}" == "1" ]] && EXTRA+=(-g)
    EXTRA+=(-m "$alt")
    set +e
    run_sshrd 2>&1 | tee "$LOG_TRY"
    code=${PIPESTATUS[0]}
    set -e
    [[ $code -eq 0 ]] && break
  done
fi
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
INNER

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
