#!/usr/bin/env bash
# =============================================================================
# 按本机 ECID + 机型 BORD 个性化已有 checkm8 SSHRD zip
#
# 用法:
#   bash personalize-ramdisk.sh iPhone10,2 16.0 000C6D3A0160002E 4
#   bash personalize-ramdisk.sh iPhone10,2 16.0 0xC6D3A0160002E
#
# 产出:
#   ramdisks/by-ecid/{ECID}/{ProductType}/{ios}.zip
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CHECKM8_ROOT:-/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down}"
LITE_DIR="${ROOT}/build/SSHRD_Script_Lite"
OUT_ROOT="${ROOT}/ramdisks"
LOG="${ROOT}/personalize-ramdisk.log"

PT="${1:-}"
IOS="${2:-}"
ECID_RAW="${3:-}"
BDID_RAW="${4:-}"

if [[ -z "$PT" || -z "$IOS" || -z "$ECID_RAW" ]]; then
  echo "用法: $0 <ProductType> <ios> <ECID> [BDID]"
  exit 2
fi

PT="${PT//./,}"
PT_DOT="${PT//,/.}"

norm_ecid() {
  local s="${1^^}"
  s="${s#0X}"
  s="$(echo "$s" | tr -d '[:space:]')"
  # pad to 16 hex
  while [[ ${#s} -lt 16 ]]; do s="0$s"; done
  if [[ ${#s} -gt 16 ]]; then s="${s: -16}"; fi
  echo "$s"
}

ECID="$(norm_ecid "$ECID_RAW")"
ECID_INT=$((16#$ECID))

declare -A BORD_MAP=(
  ["iPhone10,1"]=2 ["iPhone10,2"]=4 ["iPhone10,3"]=6
  ["iPhone10,4"]=10 ["iPhone10,5"]=12 ["iPhone10,6"]=14
  ["iPhone9,1"]=0 ["iPhone9,2"]=2 ["iPhone9,3"]=10 ["iPhone9,4"]=12
  ["iPhone8,1"]=4 ["iPhone8,2"]=6 ["iPhone8,4"]=2
)

BORD=""
if [[ -n "$BDID_RAW" ]]; then
  BORD=$((16#${BDID_RAW#0x}))
elif [[ -n "${BORD_MAP[$PT]:-}" ]]; then
  BORD="${BORD_MAP[$PT]}"
else
  echo "[ERR] 未知机型 BORD，请传第 4 参数 BDID"
  exit 1
fi

exec >>"$LOG" 2>&1
echo "======== $(date) personalize $PT @$IOS ECID=$ECID BORD=$BORD ========"

find_base_zip() {
  local c
  for c in \
    "${OUT_ROOT}/${PT}/${IOS}.zip" \
    "${OUT_ROOT}/${PT_DOT}/${IOS}.zip" \
    "${OUT_ROOT}/${PT}/default.zip" \
    "${OUT_ROOT}/${PT_DOT}/default.zip" \
    "${OUT_ROOT}/${PT}.zip" \
    "${OUT_ROOT}/${PT_DOT}.zip"
  do
    if [[ -f "$c" ]]; then echo "$c"; return 0; fi
  done
  return 1
}

# ios=default 时只找 default/机型 zip
if [[ "$IOS" == "default" ]]; then
  IOS=""
fi
BASE_ZIP="$(find_base_zip || true)"
if [[ -z "${BASE_ZIP:-}" ]]; then
  echo "[ERR] 找不到基础包，请先: bash build-checkm8.sh $PT ${IOS:-16.0}"
  exit 1
fi
# 个性化 zip 文件名：无版本号时用 default
ZIP_VER="${IOS:-default}"

IMG4TOOL=""
IMG4=""
for cand in \
  "${LITE_DIR}/tools/Linux/img4tool" \
  "${LITE_DIR}/tools/Linux/img4" \
  "$(command -v img4tool || true)" \
  "$(command -v img4 || true)"
do
  [[ -n "$cand" && -x "$cand" ]] || continue
  case "$(basename "$cand")" in
    img4tool) IMG4TOOL="$cand" ;;
    img4) IMG4="$cand" ;;
  esac
done

if [[ -z "$IMG4TOOL" && -z "$IMG4" ]]; then
  echo "[ERR] 未找到 img4tool/img4（请先 clone SSHRD_Script_Lite 到 build/）"
  exit 1
fi

CPID_SHSH=""
for c in 0x8015 0x8010 0x8011 0x8012 0x8000 0x8003 0x8001 0x7000 0x7001 0x8960; do
  if [[ -f "${LITE_DIR}/misc/shsh/${c}.shsh" ]]; then
    # prefer matching by product family later; A11 default 8015
    :
  fi
done
# map rough CPID by product
CPID="0x8015"
case "$PT" in
  iPhone10,*) CPID="0x8015" ;;
  iPhone9,*) CPID="0x8010" ;; # may be 8010; Lite uses board-specific via firmware
  iPhone8,*) CPID="0x8000" ;;
  iPhone7,*) CPID="0x7000" ;;
  iPhone6,*) CPID="0x8960" ;;
esac
# A10 is 0x8010/8011 — Lite keeps separate shsh; prefer file exists
if [[ "$PT" == iPhone9,* ]]; then
  if [[ -f "${LITE_DIR}/misc/shsh/0x8010.shsh" ]]; then CPID="0x8010"
  elif [[ -f "${LITE_DIR}/misc/shsh/0x8011.shsh" ]]; then CPID="0x8011"; fi
fi
if [[ "$PT" == iPhone8,* ]]; then
  if [[ -f "${LITE_DIR}/misc/shsh/0x8000.shsh" ]]; then CPID="0x8000"
  elif [[ -f "${LITE_DIR}/misc/shsh/0x8003.shsh" ]]; then CPID="0x8003"; fi
fi

SRC_SHSH="${LITE_DIR}/misc/shsh/${CPID}.shsh"
if [[ ! -f "$SRC_SHSH" ]]; then
  echo "[ERR] 无模板 shsh: $SRC_SHSH"
  exit 1
fi

WORK="${ROOT}/build/personalize/${ECID}_${PT_DOT}_${IOS}"
rm -rf "$WORK"
mkdir -p "$WORK/in" "$WORK/out" "$WORK/tmp"
unzip -qo "$BASE_ZIP" -d "$WORK/in"
# flatten
find "$WORK/in" -type f -iname '*.img4' -exec cp -f {} "$WORK/in/" \; 2>/dev/null || true

PATCHED_SHSH="$WORK/tmp/patched.shsh"
IM4M="$WORK/tmp/IM4M"
# 只改 BORD（1 字节原地）。不要写真机 ECID：5→7 字节会撑坏票证 ASN.1 → 发 iBSS 掉系统恢复。
python3 "${SCRIPT_DIR}/personalize_shsh.py" \
  -i "$SRC_SHSH" -o "$PATCHED_SHSH" \
  -p "$PT" --bord "$BORD" 

if [[ -n "$IMG4TOOL" ]]; then
  "$IMG4TOOL" -e -s "$PATCHED_SHSH" -m "$IM4M"
else
  echo "[ERR] 需要 img4tool 提取 IM4M"
  exit 1
fi
[[ -s "$IM4M" ]] || { echo "[ERR] IM4M 为空"; exit 1; }

tag_for() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    ibss.img4) echo ibss ;;
    ibec.img4) echo ibec ;;
    iboot.img4) echo ibot ;;
    ramdisk.img4) echo rdsk ;;
    devicetree.img4) echo rdtr ;;
    kernelcache.img4) echo rkrn ;;
    trustcache.img4) echo rtsc ;;
    logo.img4|bootlogo.img4) echo rlgo ;;
    *) echo "" ;;
  esac
}

repack_one() {
  local src="$1" name base tag im4p out
  name="$(basename "$src")"
  tag="$(tag_for "$name")"
  [[ -n "$tag" ]] || { cp -f "$src" "$WORK/out/$name"; return 0; }
  base="${name%.*}"
  im4p="$WORK/tmp/${base}.im4p"
  out="$WORK/out/$name"

  if [[ -n "$IMG4TOOL" ]]; then
    if "$IMG4TOOL" -e -i "$src" -p "$im4p" 2>/dev/null; then
      if "$IMG4TOOL" -c "$out" -p "$im4p" -m "$IM4M" 2>/dev/null; then
        echo "[OK] repack $name tag=$tag"
        return 0
      fi
    fi
  fi

  # fallback: keep original (至少别中断)
  echo "[WARN] repack 失败，保留原文件: $name"
  cp -f "$src" "$out"
}

shopt -s nullglob
for f in "$WORK/in"/*.img4 "$WORK/in"/*.IMG4; do
  [[ -f "$f" ]] || continue
  # skip nested dupes if already flattened basename-only
  [[ "$(dirname "$f")" == "$WORK/in" ]] || continue
  repack_one "$f"
done
shopt -u nullglob

# ensure required
for need in iBSS.img4 iBEC.img4 ramdisk.img4 devicetree.img4 kernelcache.img4; do
  if [[ ! -f "$WORK/out/$need" && ! -f "$WORK/out/${need^^}" ]]; then
    # try case variants
    found="$(find "$WORK/out" -iname "$need" | head -n1 || true)"
    if [[ -z "$found" ]]; then
      echo "[ERR] 缺少 $need"
      exit 1
    fi
  fi
done

DEST_DIR="${OUT_ROOT}/by-ecid/${ECID}/${PT}"
mkdir -p "$DEST_DIR" "${OUT_ROOT}/by-ecid/${ECID}/${PT_DOT}"
DEST_ZIP="${DEST_DIR}/${ZIP_VER}.zip"
(
  cd "$WORK/out"
  rm -f "$DEST_ZIP"
  zip -9 -q "$DEST_ZIP" *.img4 *.IMG4 2>/dev/null || zip -9 -q "$DEST_ZIP" ./*
)
cp -f "$DEST_ZIP" "${OUT_ROOT}/by-ecid/${ECID}/${PT_DOT}/${ZIP_VER}.zip"
cp -f "$DEST_ZIP" "${DEST_DIR}/default.zip"

# verify
if [[ -x "$IMG4TOOL" ]]; then
  echo "[verify] iBSS ticket:"
  "$IMG4TOOL" -a "$WORK/out/iBSS.img4" 2>/dev/null | head -n 40 || true
fi

echo "[OK] $DEST_ZIP"
echo "$DEST_ZIP"
