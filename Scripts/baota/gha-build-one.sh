#!/usr/bin/env bash
# GitHub Actions / 本地：单机型单覆盖节点构建（SSHRD_Script_Lite，不拉 gaster）
# 用法:
#   PRODUCT=iPhone10,6 IOS=15.0 OUT_IOS=15.0 bash Scripts/baota/gha-build-one.sh
#   bash Scripts/baota/gha-build-one.sh iPhone10,6 15.0 15.0 [BUILDID]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PT="${1:-${PRODUCT:-}}"
IOS_VER="${2:-}"
[[ -n "$IOS_VER" ]] || IOS_VER="${IOS:-}"
OUT_IOS="${3:-${OUT_IOS:-}}"
BUILDID="${4:-${BUILDID:-}}"

if [[ -z "$PT" || -z "$IOS_VER" ]]; then
  echo "usage: gha-build-one.sh <ProductType> <IOS> [OUT_IOS] [BUILDID]"
  exit 2
fi
PT="${PT//./,}"
OUT_IOS="${OUT_IOS:-$IOS_VER}"
IOS="$IOS_VER"

ROOT="${CHECKM8_ROOT:-${REPO_ROOT}/.checkm8-build}"
export CHECKM8_ROOT="$ROOT"
BUILD="${ROOT}/build"
OUT="${ROOT}/ramdisks"
LITE_DIR="${BUILD}/SSHRD_Script_Lite"
LITE_REPO="${LITE_REPO:-https://github.com/mast3rz3ro/SSHRD_Script_Lite.git}"

mkdir -p "$BUILD" "$OUT" "${ROOT}/Scripts"
# 把本仓库 baota 脚本挂到 CHECKM8_ROOT 约定路径（补丁脚本读此路径）
rm -rf "${ROOT}/Scripts/baota"
cp -a "${SCRIPT_DIR}" "${ROOT}/Scripts/baota"

echo "======== GHA build $PT @ $IOS (out=$OUT_IOS buildid=${BUILDID:-auto}) ========"
echo "ROOT=$ROOT"
df -h / | tail -1 || true

# 依赖（GitHub-hosted 已带 docker；勿 apt 装 docker.io 以免搞坏环境）
if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    git curl ca-certificates zip unzip xz-utils python3 libusb-1.0-0 \
    || true
fi

docker info >/dev/null 2>&1 || { echo "[ERR] docker not available"; exit 1; }

gha_out() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "$1" >> "$GITHUB_OUTPUT"
  fi
}

if [[ ! -d "${LITE_DIR}/.git" ]]; then
  echo "[git] clone SSHRD_Script_Lite…"
  git clone --recursive "$LITE_REPO" "$LITE_DIR"
else
  git -C "$LITE_DIR" pull --ff-only || true
  git -C "$LITE_DIR" submodule update --init --recursive || true
fi
chmod +x "${LITE_DIR}"/*.sh 2>/dev/null || true
# Lite 根目录需要 parser（补丁打在 submodule 时同步一份）
if [[ ! -s "${LITE_DIR}/ifirmware_parser.sh" && -s "${LITE_DIR}/ifirmware_parser/ifirmware_parser.sh" ]]; then
  cp -f "${LITE_DIR}/ifirmware_parser/ifirmware_parser.sh" "${LITE_DIR}/ifirmware_parser.sh"
fi

# A11 补丁（幂等；对非 A11 也无害）
bash "${ROOT}/Scripts/baota/patch_sshrd_lite_a11.sh" || true
bash "${ROOT}/Scripts/baota/patch_ifirmware_parser_a11.sh" || true
if [[ ! -s "${LITE_DIR}/ifirmware_parser.sh" && -s "${LITE_DIR}/ifirmware_parser/ifirmware_parser.sh" ]]; then
  cp -f "${LITE_DIR}/ifirmware_parser/ifirmware_parser.sh" "${LITE_DIR}/ifirmware_parser.sh"
fi

# 可选：按机型改 BORD
if [[ -f "${ROOT}/Scripts/baota/personalize_shsh.py" ]]; then
  shsh_cpid="0x8015"
  case "$PT" in
    iPhone10,*) shsh_cpid="0x8015" ;;
    iPhone9,*)  shsh_cpid="0x8010" ;;
    iPhone8,4)  shsh_cpid="0x8003" ;;
    iPhone8,*)  shsh_cpid="0x8000" ;;
    iPhone7,*)  shsh_cpid="0x7000" ;;
    iPhone6,*)  shsh_cpid="0x8960" ;;
    iPad7,*|iPod9,*) shsh_cpid="0x8010" ;;
    iPad6,*) shsh_cpid="0x8000" ;;
    iPad5,*) shsh_cpid="0x7000" ;;
    iPad4,*) shsh_cpid="0x8960" ;;
  esac
  sh="${LITE_DIR}/misc/shsh/${shsh_cpid}.shsh"
  if [[ -f "$sh" ]]; then
    bak="${sh}.bak-generic"
    [[ -f "$bak" ]] || cp -f "$sh" "$bak"
    python3 "${ROOT}/Scripts/baota/personalize_shsh.py" -i "$bak" -o "$sh" -p "$PT" \
      && echo "[shsh] patched BORD for $PT" \
      || echo "[shsh] WARN: patch skipped"
  fi
fi

# 预检：无固件则软退出（job 标 skip，不失败整条流水线）
if [[ "${PRECHECK_IPSW:-1}" == "1" ]]; then
  url="https://api.ipsw.me/v4/device/${PT}?type=ipsw"
  if ! curl -fsSL --connect-timeout 20 --max-time 60 "$url" \
      | grep -qoE "\"version\"[[:space:]]*:[[:space:]]*\"${IOS}\""; then
    echo "[SKIP] $PT 无 iOS $IOS（ipsw.me）"
    gha_out "skip=true"
    mkdir -p "${OUT}/${PT}"
    echo "no_ipsw" > "${OUT}/${PT}/${OUT_IOS}.skipped"
    exit 0
  fi
fi

# 预拉 BuildID + TheAppleWiki 固件密钥（Lite 在线拉 keys 常失败）
export CHECKM8_ROOT="$ROOT"
BUILDID="$(
  CHECKM8_ROOT="$ROOT" PT="$PT" IOS="$IOS" BUILDID="$BUILDID" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["CHECKM8_ROOT"], "Scripts", "baota"))
from build_a11_ramdisks import ensure_keys, fetch_buildid

pt = os.environ["PT"]
ios = os.environ["IOS"]
build = (os.environ.get("BUILDID") or "").strip()
if not build:
    build = fetch_buildid(pt, ios) or ""
if not build:
    print("[FAIL] no buildid for %s @ %s" % (pt, ios), file=sys.stderr)
    sys.exit(3)
if not ensure_keys(pt, build, ios):
    print("[FAIL] firmware keys missing for %s %s @%s" % (pt, build, ios), file=sys.stderr)
    sys.exit(4)
print(build)
PY
)"
echo "[keys] ready buildid=$BUILDID -> ${LITE_DIR}/misc/firmware_keys/${PT}_${BUILDID}.json"
ls -lah "${LITE_DIR}/misc/firmware_keys/${PT}_${BUILDID}.json"

# iOS 16.1+ APFS：Linux 默认跳过（可用 FORCE_APFS=1 强行试）
IFS=. read -r maj min _ <<< "${IOS}."
maj="${maj:-0}"; min="${min:-0}"
if (( maj > 16 || (maj == 16 && min >= 1) )); then
  if [[ "${FORCE_APFS:-0}" != "1" ]]; then
    echo "[SKIP] iOS $IOS 需要 APFS，Linux runner 默认跳过（FORCE_APFS=1 可强试）"
    gha_out "skip=true"
    mkdir -p "${OUT}/${PT}"
    echo "needs_apfs" > "${OUT}/${PT}/${OUT_IOS}.skipped"
    exit 0
  fi
  echo "[WARN] FORCE_APFS=1 — 尝试构建 $IOS（Linux 多半失败）"
fi

export CHECKM8_ROOT="$ROOT"
bash "${ROOT}/Scripts/baota/docker-build-sshrd.sh" "$PT" "$IOS" "$BUILDID" "$OUT_IOS"

zip="${OUT}/${PT}/${OUT_IOS}.zip"
if [[ ! -f "$zip" ]]; then
  echo "[FAIL] missing $zip"
  exit 1
fi
sz="$(stat -c%s "$zip" 2>/dev/null || wc -c < "$zip")"
if [[ "$sz" -lt 1000000 ]]; then
  echo "[FAIL] zip too small: $sz"
  exit 1
fi

# 给 Actions 上传用的扁平目录
STAGE="${REPO_ROOT}/ramdisk-artifact"
mkdir -p "$STAGE"
cp -f "$zip" "${STAGE}/${PT//,/-}_${OUT_IOS}.zip"
ls -lah "$zip" "${STAGE}/"
gha_out "artifact_zip=${STAGE}/${PT//,/-}_${OUT_IOS}.zip"
echo "======== OK $PT @ $OUT_IOS ========"
