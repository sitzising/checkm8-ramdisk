#!/usr/bin/env bash
# =============================================================================
# checkm8（iPhone X 及以下）· 云端批量构建 SSHRD → zip（无需插手机）
#
# 基于: https://github.com/mast3rz3ro/SSHRD_Script_Lite
# 要求: Ubuntu 20.04+ / Debian 11+ / Rocky·Alma 8+（禁止 CentOS 7）
# Linux 勿用 iOS 16.1+（APFS）
#
# 用法:
#   bash build-checkm8.sh
#   ONLY_PRODUCTS="iPhone10,6" ONLY_IOS="15.7.1 16.0" bash build-checkm8.sh
#   bash build-checkm8.sh iPhone10,6 15.7.1          # 单条
#   bash build-checkm8.sh iPhone10,6 15.7.1 iPhone9,3 15.7.1
#
# 环境变量:
#   SKIP_EXISTING=1  PRECHECK_IPSW=1  SKIP_DEPS=0  DRY_RUN=1
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_os_check.sh"
require_supported_os || exit 1

ROOT="${CHECKM8_ROOT:-/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down}"
BUILD="${ROOT}/build"
OUT="${ROOT}/ramdisks"
LITE_DIR="${BUILD}/SSHRD_Script_Lite"
LITE_REPO="${LITE_REPO:-https://github.com/mast3rz3ro/SSHRD_Script_Lite.git}"
LOG="${ROOT}/build-checkm8.log"
OK_LIST="${ROOT}/ok.list"
FAIL_LIST="${ROOT}/fail.list"
SKIP_LIST="${ROOT}/skip.list"
CACHE_DIR="${BUILD}/ipsw-me-cache"
SKIP_EXISTING="${SKIP_EXISTING:-1}"
PRECHECK_IPSW="${PRECHECK_IPSW:-1}"

mkdir -p "$BUILD" "$OUT" "$ROOT" "$CACHE_DIR"
: > "$OK_LIST"
: > "$FAIL_LIST"
: > "$SKIP_LIST"
exec > >(tee -a "$LOG") 2>&1

echo "======== $(date) checkm8 Ramdisk 构建 ========"
echo "ROOT=$ROOT  PRECHECK_IPSW=$PRECHECK_IPSW"

ALL_PRODUCTS=(
  iPhone10,6 iPhone10,3 iPhone10,1 iPhone10,2 iPhone10,4 iPhone10,5
  iPhone9,1 iPhone9,2 iPhone9,3 iPhone9,4
  iPad7,5 iPad7,6 iPad7,11 iPad7,12
  iPod9,1
  iPhone8,1 iPhone8,2 iPhone8,4
  iPad6,11 iPad6,12
  iPhone7,1 iPhone7,2
  iPad5,1 iPad5,2 iPad5,3 iPad5,4
  iPod7,1
  iPhone6,1 iPhone6,2
  iPad4,1 iPad4,2 iPad4,3 iPad4,4 iPad4,5 iPad4,6 iPad4,7 iPad4,8 iPad4,9
)

ALL_IOS=(
  12.5.7 13.7 14.8.1
  15.0 15.1 15.2 15.3.1 15.4.1 15.5 15.6.1
  15.7 15.7.1 15.7.2 15.7.5 15.7.6 15.7.7 15.7.8 15.7.9
  15.8 15.8.1 15.8.2 15.8.3
  16.0 16.0.2 16.0.3
)

# 命令行成对参数优先
declare -a JOBS=()
if [[ $# -ge 2 && $(( $# % 2 )) -eq 0 ]]; then
  while [[ $# -ge 2 ]]; do
    JOBS+=("$1|$2")
    shift 2
  done
fi

if [[ -n "${ONLY_PRODUCTS:-}" ]]; then
  # shellcheck disable=SC2206
  ALL_PRODUCTS=($ONLY_PRODUCTS)
fi
if [[ -n "${ONLY_IOS:-}" ]]; then
  # shellcheck disable=SC2206
  ALL_IOS=($ONLY_IOS)
fi

ipsw_versions_file() {
  local pt="$1" cache="${CACHE_DIR}/${pt}.versions.txt" json url
  if [[ -f "$cache" && -s "$cache" ]]; then
    echo "$cache"; return 0
  fi
  url="https://api.ipsw.me/v4/device/${pt}?type=ipsw"
  if ! json="$(curl -fsSL --connect-timeout 20 --max-time 60 "$url" 2>/dev/null)"; then
    echo "[!] ipsw.me 失败: $pt" >&2
    return 1
  fi
  printf '%s' "$json" | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' \
    | sed -E 's/.*"([^"]+)"/\1/' | sort -u > "$cache" || true
  [[ -s "$cache" ]] || { rm -f "$cache"; return 1; }
  echo "$cache"
}

version_exists_for_product() {
  local pt="$1" ver="$2" vf
  if ! vf="$(ipsw_versions_file "$pt")"; then
    return 0
  fi
  grep -qxF "$ver" "$vf"
}

if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
  bash "${SCRIPT_DIR}/install-deps.sh"
fi
for bin in git curl zip python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[ERR] 缺少 $bin"; exit 1; }
done

cp -f "${SCRIPT_DIR}/checkm8-ramdisk.php" "${ROOT}/ramdisk.php"

if [[ ! -d "${LITE_DIR}/.git" ]]; then
  echo "[git] clone SSHRD_Script_Lite…"
  git clone --recursive "$LITE_REPO" "$LITE_DIR"
else
  git -C "$LITE_DIR" pull --ff-only || true
  git -C "$LITE_DIR" submodule update --init --recursive || true
fi
chmod +x "${LITE_DIR}/sshrd_lite.sh" 2>/dev/null || true
[[ -x "${LITE_DIR}/sshrd_lite.sh" ]] || { echo "[ERR] 无 sshrd_lite.sh"; exit 1; }

# 启动前自检 pzb（Ubuntu 上应正常）
PZB="${LITE_DIR}/tools/Linux/pzb"
if [[ -x "$PZB" ]]; then
  if "$PZB" 2>&1 | head -n 5 | grep -q GLIBCXX; then
    echo "[ERR] pzb 报 GLIBCXX —— 当前系统过旧，请换 Ubuntu 22.04"
    exit 1
  fi
  echo "[OK] pzb 可运行"
fi

cleanup_ipsw() {
  echo "[清理] 删除 IPSW / 临时…"
  find "$LITE_DIR" "$BUILD" -type f \( -iname '*.ipsw' -o -iname '*.ipsw.partial' -o -iname '*.ipsw.tmp' \) -delete 2>/dev/null || true
  for d in work tmp tmpdir .tmp cache downloads ipsw IPSW 12rd sshramdisk SSHRD ramdisk final_ramdisk output; do
    rm -rf "${LITE_DIR}/${d}" 2>/dev/null || true
  done
  find /tmp -maxdepth 2 -type f -iname '*.ipsw' -mtime -2 -delete 2>/dev/null || true
  df -h "$ROOT" 2>/dev/null || df -h /
}

find_img4_dir() {
  local f
  f="$(find "$LITE_DIR" -name 'iBSS.img4' 2>/dev/null | head -n1 || true)"
  [[ -n "$f" ]] && dirname "$f"
}

zip_ramdisk() {
  local src="$1" pt="$2" ver="$3" zip flat tmp
  mkdir -p "${OUT}/${pt}"
  zip="${OUT}/${pt}/${ver}.zip"
  flat="${OUT}/${pt}.zip"
  tmp="$(mktemp -d)"
  for f in iBSS.img4 iBEC.img4 ramdisk.img4 devicetree.img4 kernelcache.img4 trustcache.img4 bootlogo.img4; do
    [[ -f "${src}/${f}" ]] && cp -f "${src}/${f}" "$tmp/"
  done
  shopt -s nullglob
  for f in "${src}"/*.img4 "${src}"/*.IMG4; do
    local b; b="$(basename "$f")"
    [[ -f "${tmp}/${b}" ]] || cp -f "$f" "$tmp/" 2>/dev/null || true
  done
  shopt -u nullglob
  if [[ ! -f "${tmp}/iBSS.img4" && ! -f "${tmp}/iBSS.IMG4" ]]; then
    rm -rf "$tmp"; echo "[FAIL] 缺 iBSS.img4"; return 1
  fi
  (cd "$tmp" && zip -q -r "$zip" .)
  cp -f "$zip" "$flat"
  rm -rf "$tmp"
  echo "[ZIP] $zip ($(du -h "$zip" | awk '{print $1}'))"
}

# 返回: 0 ok  2 skip  1 fail
build_one() {
  local pt="$1" ver="$2" pt_lower zip_path blog code src
  pt_lower="$(echo "$pt" | tr '[:upper:]' '[:lower:]')"
  zip_path="${OUT}/${pt}/${ver}.zip"

  if [[ "$SKIP_EXISTING" == "1" && -f "$zip_path" ]]; then
    local sz; sz="$(stat -c%s "$zip_path" 2>/dev/null || echo 0)"
    if [[ "$sz" -gt 1000000 ]]; then
      echo "[SKIP] 已有 $zip_path"
      echo "$pt|$ver|exists" >> "$OK_LIST"
      return 0
    fi
  fi

  if [[ "$PRECHECK_IPSW" == "1" ]] && ! version_exists_for_product "$pt" "$ver"; then
    echo "[SKIP] $pt 无 iOS $ver（ipsw.me）"
    echo "$pt|$ver|no_ipsw" >> "$SKIP_LIST"
    return 2
  fi

  echo "======== 构建 $pt @ iOS $ver ========"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[DRY] ./sshrd_lite.sh -p $pt_lower -s $ver"
    return 0
  fi

  cd "$LITE_DIR"
  find "$LITE_DIR" -type f -iname '*.ipsw' -delete 2>/dev/null || true

  # 按机型改写对应 CPID 的 shsh BORD（Lite 的 0x8015.shsh 默认是 X / BORD=6）
  if [[ -f "${SCRIPT_DIR}/personalize_shsh.py" ]]; then
    local shsh_cpid="0x8015"
    case "$pt" in
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
    local sh="misc/shsh/${shsh_cpid}.shsh"
    if [[ -f "$sh" ]]; then
      local bak="${sh}.bak-generic"
      [[ -f "$bak" ]] || cp -f "$sh" "$bak"
      if python3 "${SCRIPT_DIR}/personalize_shsh.py" -i "$bak" -o "$sh" -p "$pt"; then
        echo "[shsh] patched BORD for $pt ← $sh"
      else
        echo "[shsh] WARN: patch failed for $sh"
      fi
    fi
  fi

  blog="$(mktemp)"
  set +e
  ./sshrd_lite.sh -p "$pt_lower" -s "$ver" 2>&1 | tee "$blog"
  code=${PIPESTATUS[0]}
  set -e

  if grep -qE "Couldn't find any result|Please make sure to enter a valid product" "$blog" 2>/dev/null; then
    echo "[SKIP] 无固件 $pt $ver"
    echo "$pt|$ver|no_ipsw_parser" >> "$SKIP_LIST"
    rm -f "$blog"; cleanup_ipsw; return 2
  fi
  if [[ $code -ne 0 ]]; then
    echo "[FAIL] $pt $ver exit=$code"
    echo "$pt|$ver|build_fail" >> "$FAIL_LIST"
    rm -f "$blog"; cleanup_ipsw; return 1
  fi
  rm -f "$blog"

  src="$(find_img4_dir)"
  if [[ -z "$src" ]]; then
    echo "[FAIL] 无 iBSS.img4"
    echo "$pt|$ver|no_img4" >> "$FAIL_LIST"
    cleanup_ipsw; return 1
  fi
  if ! zip_ramdisk "$src" "$pt" "$ver"; then
    echo "$pt|$ver|zip_fail" >> "$FAIL_LIST"
    cleanup_ipsw; return 1
  fi
  echo "$pt|$ver|ok" >> "$OK_LIST"
  cleanup_ipsw
  return 0
}

# 组装任务
if ((${#JOBS[@]} == 0)); then
  if [[ "$PRECHECK_IPSW" == "1" ]]; then
    echo "预拉 ipsw.me 版本列表…"
    for pt in "${ALL_PRODUCTS[@]}"; do
      ipsw_versions_file "$pt" >/dev/null || true
    done
  fi
  for pt in "${ALL_PRODUCTS[@]}"; do
    for ver in "${ALL_IOS[@]}"; do
      if [[ "$PRECHECK_IPSW" == "1" ]] && ! version_exists_for_product "$pt" "$ver"; then
        echo "$pt|$ver|no_ipsw" >> "$SKIP_LIST"
        continue
      fi
      JOBS+=("${pt}|${ver}")
    done
  done
fi

total=${#JOBS[@]}
echo "计划任务: $total"
ok=0; fail=0; skip=0; n=0
for job in "${JOBS[@]}"; do
  n=$((n + 1))
  pt="${job%%|*}"
  ver="${job##*|}"
  echo
  echo ">>>> [$n/$total] $pt @ $ver"
  set +e
  build_one "$pt" "$ver"
  rc=$?
  set -e
  case $rc in
    0) ok=$((ok + 1)) ;;
    2) skip=$((skip + 1)) ;;
    *) fail=$((fail + 1)) ;;
  esac
done

echo
echo "======== $(date) 结束 ========"
echo "ok=$ok  skip=$skip  fail=$fail"
echo "ok.list=$OK_LIST  skip.list=$SKIP_LIST  fail.list=$FAIL_LIST"
echo "zip: $OUT"
echo "API: https://tool.a-cheng.cn/ramdisk/checkm8-down/ramdisk.php?productType=iPhone10,6&ios=15.7.1"
df -h "$ROOT" 2>/dev/null || true
