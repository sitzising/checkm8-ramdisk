#!/usr/bin/env bash
# =============================================================================
# A12/A13 · 把 ICH 文件夹打成客户端可下载的 zip
#
# 输入:  /www/wwwroot/tool.a-cheng.cn/ramdisk/a12-down/incoming/
# 输出:  .../ramdisks/{机型}.zip
#
# 用法:
#   bash publish-a12.sh
#   bash publish-a12.sh iPad11,1
#   bash publish-a12.sh /path/to/folder iPad11,1
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_os_check.sh"
require_supported_os || exit 1

ROOT="${A12_ROOT:-/www/wwwroot/tool.a-cheng.cn/ramdisk/a12-down}"
INCOMING="${INCOMING:-${ROOT}/incoming}"
OUT="${OUT:-${ROOT}/ramdisks}"
LOG="${LOG:-${ROOT}/publish-a12.log}"

mkdir -p "$INCOMING" "$OUT" "$ROOT"
exec > >(tee -a "$LOG") 2>&1

echo "======== $(date) A12 ICH 发布 ========"
echo "INCOMING=$INCOMING → OUT=$OUT"

cp -f "${SCRIPT_DIR}/a12-ramdisk.php" "${ROOT}/ramdisk.php"

REQUIRED=(iBoot.patched.bin ramdisk.img4 kernelcache.img4 devicetree.img4 trustcache.img4)
OPTIONAL=(ANE.img4 AOP.img4 AVE.img4 GFX.img4 ISP.img4 SIO.img4 sep-fw.img4 sptm.img4 txm.img4 logo.img4)

is_ich_dir() {
  local d="$1"
  [[ -f "$d/iBoot.patched.bin" && -f "$d/ramdisk.img4" && -f "$d/kernelcache.img4" ]]
}

pack_dir() {
  local src="$1" key="$2"
  key="${key// /}"
  [[ -n "$key" ]] || return 1
  if ! is_ich_dir "$src"; then
    echo "[SKIP] 非 ICH 布局: $src（需要 iBoot.patched.bin + ramdisk/kernelcache.img4）"
    return 1
  fi

  local miss=()
  for f in "${REQUIRED[@]}"; do
    [[ -f "$src/$f" ]] || miss+=("$f")
  done
  ((${#miss[@]})) && echo "[WARN] $key 缺少: ${miss[*]}"

  local zip="${OUT}/${key}.zip" tmp
  tmp="$(mktemp -d)"
  for f in "${REQUIRED[@]}" "${OPTIONAL[@]}"; do
    [[ -f "$src/$f" ]] && cp -f "$src/$f" "$tmp/"
  done
  shopt -s nullglob
  for f in "$src"/*.img4 "$src"/*.IMG4 "$src"/*.bin; do
    local b; b="$(basename "$f")"
    [[ -f "$tmp/$b" ]] || cp -f "$f" "$tmp/" 2>/dev/null || true
  done
  shopt -u nullglob

  (cd "$tmp" && zip -q -r "$zip" .)
  rm -rf "$tmp"

  if [[ "$key" == *","* ]]; then
    cp -f "$zip" "${OUT}/${key//,/.}.zip" 2>/dev/null || true
  elif [[ "$key" == *"."* ]]; then
    cp -f "$zip" "${OUT}/${key//./,}.zip" 2>/dev/null || true
  fi
  echo "[OK] $zip ($(du -h "$zip" | awk '{print $1}'))"
}

if [[ $# -ge 1 ]]; then
  if [[ -d "$1" ]]; then
    pack_dir "$1" "${2:-$(basename "$1")}"
    exit 0
  fi
  name="$1"
  if [[ -d "${INCOMING}/${name}" ]]; then
    pack_dir "${INCOMING}/${name}" "${2:-$name}"
    exit 0
  fi
  if [[ -f "${INCOMING}/${name}.zip" ]]; then
    tmp="$(mktemp -d)"
    unzip -q -o "${INCOMING}/${name}.zip" -d "$tmp"
    if is_ich_dir "$tmp"; then
      pack_dir "$tmp" "${2:-$name}"
    else
      sub=""
      while IFS= read -r d; do
        if is_ich_dir "$d"; then sub="$d"; break; fi
      done < <(find "$tmp" -maxdepth 3 -type d)
      [[ -n "$sub" ]] && pack_dir "$sub" "${2:-$name}"
    fi
    rm -rf "$tmp"
    exit 0
  fi
  echo "[ERR] 找不到: $1"
  exit 1
fi

count=0
shopt -s nullglob
for d in "${INCOMING}"/*/; do
  [[ -d "$d" ]] || continue
  name="$(basename "$d")"
  [[ "$name" == .* ]] && continue
  pack_dir "$d" "$name" && count=$((count + 1)) || true
done
for z in "${INCOMING}"/*.zip; do
  [[ -f "$z" ]] || continue
  name="$(basename "$z" .zip)"
  tmp="$(mktemp -d)"
  unzip -q -o "$z" -d "$tmp"
  target=""
  if is_ich_dir "$tmp"; then
    target="$tmp"
  else
    while IFS= read -r d; do
      if is_ich_dir "$d"; then target="$d"; break; fi
    done < <(find "$tmp" -maxdepth 3 -type d)
  fi
  if [[ -n "$target" ]] && pack_dir "$target" "$name"; then
    count=$((count + 1))
  else
    echo "[SKIP] zip 内无 ICH: $z"
  fi
  rm -rf "$tmp"
done
shopt -u nullglob

echo "已发布 ${count} 个 → $OUT"
echo "测试: https://tool.a-cheng.cn/ramdisk/a12-down/ramdisk.php?key=iPad11,1"
echo "======== $(date) 完成 ========"
