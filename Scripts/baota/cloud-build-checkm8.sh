#!/usr/bin/env bash
COMPAT_LIB="${CHECKM8_ROOT:-/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down}/build/compat-lib"
export LD_LIBRARY_PATH="${COMPAT_LIB}:${LD_LIBRARY_PATH:-}"
# =============================================================================
# 宝塔云服务器 · 不插手机构建 checkm8 SSHRD（iPhone X 及以下）
#
# 基于：https://github.com/mast3rz3ro/SSHRD_Script_Lite
# 特点：无需连接设备，指定 ProductType + iOS 即可生成 img4
#
# 目录：
#   /www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/
#     Scripts/baota/     ← 可把本脚本放这里或 a12-down 同目录共用
#     build/             ← 源码与临时文件
#     ramdisks/          ← 对外 zip
#     ramdisk.php
#
# 用法：
#   bash cloud-build-checkm8.sh iPhone10,6 15.7.1
#   bash cloud-build-checkm8.sh iPhone10,6 15.7.1 iPhone9,3 15.7.1
#   PRODUCTS="iPhone10,6 iPhone10,3" IOS=15.7.1 bash cloud-build-checkm8.sh
#
# Linux 限制：不要用 16.1+，推荐 15.7.x / 16.0
# =============================================================================
set -euo pipefail

ROOT="${CHECKM8_ROOT:-/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down}"
BUILD="${ROOT}/build"
OUT="${ROOT}/ramdisks"
LITE_DIR="${BUILD}/SSHRD_Script_Lite"
LITE_REPO="${LITE_REPO:-https://github.com/mast3rz3ro/SSHRD_Script_Lite.git}"
LOG="${ROOT}/cloud-build-checkm8.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$BUILD" "$OUT" "$ROOT"
exec > >(tee -a "$LOG") 2>&1

echo "======== $(date) 云端 checkm8 SSHRD 构建 ========"
echo "ROOT=$ROOT"

# 依赖（支持 CentOS 7 yum / Ubuntu apt）
if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
  if [[ -f "${SCRIPT_DIR}/install-deps.sh" ]]; then
    bash "${SCRIPT_DIR}/install-deps.sh" || true
  fi
fi
for bin in git curl zip; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[ERR] 缺少: $bin"; exit 1; }
done

# CentOS 7：pzb 需要 GLIBCXX_3.4.21（优先用已准备的 compat-lib）
COMPAT_DIR="${CHECKM8_ROOT:-/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down}/build/compat-lib"
if [[ -e "${COMPAT_DIR}/libstdc++.so.6" ]]; then
  export LD_LIBRARY_PATH="${COMPAT_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  echo "[libstdc++] 使用 compat-lib: $COMPAT_DIR"
elif [[ -f "${SCRIPT_DIR}/centos7-libstdcxx.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/centos7-libstdcxx.sh"
  enable_centos7_libstdcxx || {
    echo "[ERR] 请先准备 compat-lib 或执行: bash ${SCRIPT_DIR}/centos7-libstdcxx.sh"
    exit 1
  }
fi


# 部署 PHP
if [[ -f "${SCRIPT_DIR}/../server/ramdisk.php" ]]; then
  cp -f "${SCRIPT_DIR}/../server/ramdisk.php" "${ROOT}/ramdisk.php"
elif [[ -f "${SCRIPT_DIR}/checkm8-ramdisk.php" ]]; then
  cp -f "${SCRIPT_DIR}/checkm8-ramdisk.php" "${ROOT}/ramdisk.php"
fi
# 修正 PHP 里的 base 路径（自动用脚本目录）
if [[ -f "${ROOT}/ramdisk.php" ]]; then
  # 确保有 ramdisks 子目录约定
  sed -i 's|/checkm8/|/ramdisk/checkm8-down/|g' "${ROOT}/ramdisk.php" 2>/dev/null || true
fi

# clone / update Lite
if [[ ! -d "${LITE_DIR}/.git" ]]; then
  echo "[git] clone SSHRD_Script_Lite…"
  git clone --recursive "$LITE_REPO" "$LITE_DIR"
else
  echo "[git] update…"
  git -C "$LITE_DIR" pull --ff-only || true
  git -C "$LITE_DIR" submodule update --init --recursive || true
fi
chmod +x "${LITE_DIR}"/*.sh 2>/dev/null || true

# 解析机型列表
declare -a JOBS=()
if [[ $# -ge 2 && $(( $# % 2 )) -eq 0 ]]; then
  while [[ $# -ge 2 ]]; do
    JOBS+=("$1|$2")
    shift 2
  done
elif [[ -n "${PRODUCTS:-}" && -n "${IOS:-}" ]]; then
  for p in $PRODUCTS; do
    JOBS+=("${p}|${IOS}")
  done
else
  # 默认：常见机型 × 15.7.1（可改）
  IOS_DEFAULT="${IOS:-15.7.1}"
  for p in iPhone10,6 iPhone10,3 iPhone10,1 iPhone10,4 iPhone9,3 iPhone9,4 iPhone8,1 iPhone8,2; do
    JOBS+=("${p}|${IOS_DEFAULT}")
  done
  echo "[提示] 未传参数，默认构建常用机型 @ ${IOS_DEFAULT}"
  echo "       自定义: bash cloud-build-checkm8.sh iPhone10,6 15.7.1"
fi

pack_one() {
  local pt="$1" ver="$2"
  local pt_lower
  pt_lower="$(echo "$pt" | tr '[:upper:]' '[:lower:]')"
  echo "-------- 构建 $pt @ $ver --------"
  cd "$LITE_DIR"

  # Lite: ./sshrd_lite.sh -p 'iphone10,6' -s '15.7.1'
  set +e
  ./sshrd_lite.sh -p "$pt_lower" -s "$ver"
  local code=$?
  set -e
  if [[ $code -ne 0 ]]; then
    echo "[FAIL] $pt $ver (exit=$code)"
    return 1
  fi

  # 找产物目录（不同 fork 名称不一）
  local src=""
  for cand in \
    "${LITE_DIR}/sshramdisk" \
    "${LITE_DIR}/SSHRD" \
    "${LITE_DIR}/ramdisk" \
    "${LITE_DIR}/final_ramdisk" \
    "${LITE_DIR}/output"
  do
    if [[ -d "$cand" ]] && compgen -G "${cand}/iBSS.img4" > /dev/null 2>&1; then
      src="$cand"
      break
    fi
    if [[ -d "$cand" ]] && compgen -G "${cand}/*/iBSS.img4" > /dev/null 2>&1; then
      src="$(dirname "$(find "$cand" -name iBSS.img4 | head -n1)")"
      break
    fi
  done
  # 再广搜一层
  if [[ -z "$src" ]]; then
    local f
    f="$(find "$LITE_DIR" -name 'iBSS.img4' 2>/dev/null | head -n1 || true)"
    [[ -n "$f" ]] && src="$(dirname "$f")"
  fi

  if [[ -z "$src" || ! -f "${src}/iBSS.img4" ]]; then
    echo "[FAIL] 未找到 iBSS.img4，请看 Lite 日志目录"
    find "$LITE_DIR" -name '*.img4' 2>/dev/null | head -n 20 || true
    return 1
  fi

  mkdir -p "${OUT}/${pt}"
  local zip="${OUT}/${pt}/${ver}.zip"
  local zip2="${OUT}/${pt}.zip"
  (cd "$src" && zip -q -r "$zip" \
    iBSS.img4 iBEC.img4 ramdisk.img4 devicetree.img4 kernelcache.img4 \
    trustcache.img4 bootlogo.img4 2>/dev/null || \
    zip -q -r "$zip" .)
  cp -f "$zip" "$zip2"
  echo "[OK] $zip"
  echo "[OK] $zip2 (默认包)"
  unzip -l "$zip" | head -n 20
}

ok=0
fail=0
for job in "${JOBS[@]}"; do
  pt="${job%%|*}"
  ver="${job##*|}"
  if pack_one "$pt" "$ver"; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi
done

echo "======== 完成 ok=$ok fail=$fail ========"
echo "下载目录: $OUT"
echo "测试: https://tool.a-cheng.cn/ramdisk/checkm8-down/ramdisk.php?productType=iPhone10,6&ios=15.7.1"
echo
echo "说明：云服务器无需插手机；镜像按机型生成后供 Windows 客户端下载使用。"
