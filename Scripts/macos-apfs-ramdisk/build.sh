#!/usr/bin/env bash
# =============================================================================
# macOS · checkm8 SSH Ramdisk（iOS 16.4 / 16.7.x · APFS）
#
# 背景：iOS 16.1+ ramdisk 为 APFS，Linux/Docker 无法可靠构建；必须在 macOS 上跑。
# 基于：https://github.com/mast3rz3ro/SSHRD_Script_Lite（原生 Darwin 工具链）
#
# 覆盖节点（发布 zip 名）：
#   16.4     → 建议给 iPhone 8 / 8 Plus（也可给 X）
#   16.7.8   → iPhone X 最高区间（覆盖约 16.4 ~ 16.7.x）；无精确版时自动升到该机最高 16.7.x
#
# 用法：
#   # 单条（OUT 默认=IOS）
#   bash macos-build-apfs-ramdisk.sh iPhone10,6 16.7.8
#   bash macos-build-apfs-ramdisk.sh iPhone10,1 16.4
#
#   # 指定发布 zip 名：实际用 16.7.10 构建，产出 16.7.8.zip
#   bash macos-build-apfs-ramdisk.sh iPhone10,6 16.7.10 16.7.8
#
#   # 默认矩阵：A11 × 16.4 + 16.7.8（无固件自动跳过）
#   bash macos-build-apfs-ramdisk.sh
#
#   # 自定义
#   ONLY_PRODUCTS="iPhone10,6 iPhone10,3" ONLY_IOS="16.7.8" bash macos-build-apfs-ramdisk.sh
#   PAIRS_FILE=Scripts/macos-apfs-ramdisk/pairs.txt bash build.sh
#
# 环境变量：
#   CHECKM8_ROOT   工作根（默认 ~/checkm8-ramdisk-mac）
#   SKIP_EXISTING=1  已有足够大的 zip 则跳过（GHA 建议 0）
#   USE_GASTER=0/1   强制 gaster 解密（默认：有 wiki 密钥则不用）
#   BOARD=d221ap     覆盖默认板型
#   PRECHECK_IPSW=1  构建前查 ipsw.me
#   DRY_RUN=1        只打印任务
#   ARTIFACT_DIR     若设置，成功后复制扁平 zip 到此目录（供 GHA upload）
# =============================================================================
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "[FAIL] 本脚本必须在 macOS 上运行（需要 APFS / hdiutil）"
  echo "       当前: $(uname -s)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
ROOT="${CHECKM8_ROOT:-$HOME/checkm8-ramdisk-mac}"
BUILD="${ROOT}/build"
OUT="${ROOT}/ramdisks"
LITE_DIR="${BUILD}/SSHRD_Script_Lite"
LITE_REPO="${LITE_REPO:-https://github.com/mast3rz3ro/SSHRD_Script_Lite.git}"
LOG="${ROOT}/macos-build-apfs.log"
OK_LIST="${ROOT}/ok.list"
FAIL_LIST="${ROOT}/fail.list"
SKIP_LIST="${ROOT}/skip.list"
SKIP_EXISTING="${SKIP_EXISTING:-1}"
PRECHECK_IPSW="${PRECHECK_IPSW:-1}"
DRY_RUN="${DRY_RUN:-0}"
ARTIFACT_DIR="${ARTIFACT_DIR:-}"

mkdir -p "$BUILD" "$OUT" "$ROOT"
: >"$OK_LIST"
: >"$FAIL_LIST"
: >"$SKIP_LIST"
exec > >(tee -a "$LOG") 2>&1

echo "======== $(date) macOS APFS Ramdisk 构建 ========"
echo "ROOT=$ROOT"
echo "macOS $(sw_vers -productVersion 2>/dev/null || true)  arch=$(uname -m)"

# 依赖检查
need_bins=(git curl python3 zip unzip)
missing=()
for b in "${need_bins[@]}"; do
  command -v "$b" >/dev/null 2>&1 || missing+=("$b")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "[FAIL] 缺少: ${missing[*]}"
  echo "       建议: xcode-select --install"
  echo "             brew install python3"
  exit 1
fi
command -v hdiutil >/dev/null 2>&1 || {
  echo "[FAIL] 缺少 hdiutil（非完整 macOS？）"
  exit 1
}

# 默认机型：A11（唯一普遍能到 16.4/16.7 的 checkm8 手机）
DEFAULT_PRODUCTS=(
  iPhone10,1 iPhone10,2 iPhone10,3 iPhone10,4 iPhone10,5 iPhone10,6
)
# 覆盖节点：16.4 + 16.7.8（X 最高区间）
DEFAULT_IOS=(16.4 16.7.8)

default_board() {
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
    *) echo "" ;;
  esac
}

# ---- 解析任务 ----
declare -a JOBS=()

load_pairs_file() {
  local f="$1" line pt ios out
  [[ -f "$f" ]] || {
    echo "[FAIL] pairs file missing: $f"
    exit 1
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    if [[ "$line" == *"|"* ]]; then
      pt="${line%%|*}"
      rest="${line#*|}"
      ios="${rest%%|*}"
      out="${rest#*|}"
      [[ "$out" == "$rest" ]] && out="$ios"
      pt="${pt//./,}"
      JOBS+=("${pt}|${ios}|${out}")
    fi
  done <"$f"
}

if [[ -n "${PAIRS_FILE:-}" ]]; then
  load_pairs_file "$PAIRS_FILE"
elif [[ $# -ge 2 ]]; then
  # 成对：pt ios [out]  或  pt ios pt ios ...
  while [[ $# -ge 2 ]]; do
    pt="${1//./,}"
    ios="$2"
    out="$ios"
    shift 2
    if [[ $# -ge 1 && "$1" =~ ^[0-9]+\.[0-9] ]]; then
      # 歧义：若下一个像版本且再下一个不像机型，当作 OUT
      # 简化：三参数形式 bash script pt ios out
      :
    fi
    JOBS+=("${pt}|${ios}|${out}")
  done
elif [[ $# -eq 3 ]]; then
  JOBS+=("${1//./,}|$2|$3")
elif [[ -n "${ONLY_PRODUCTS:-}" || -n "${ONLY_IOS:-}" ]]; then
  # shellcheck disable=SC2206
  prods=(${ONLY_PRODUCTS:-${DEFAULT_PRODUCTS[*]}})
  # shellcheck disable=SC2206
  ioss=(${ONLY_IOS:-${DEFAULT_IOS[*]}})
  for p in "${prods[@]}"; do
    p="${p//./,}"
    for v in "${ioss[@]}"; do
      JOBS+=("${p}|${v}|${v}")
    done
  done
else
  # 默认矩阵（推荐）：本目录 pairs.txt
  if [[ -f "${SCRIPT_DIR}/pairs.txt" ]]; then
    load_pairs_file "${SCRIPT_DIR}/pairs.txt"
  elif [[ -f "${SCRIPT_DIR}/_macos_apfs_pairs.txt" ]]; then
    load_pairs_file "${SCRIPT_DIR}/_macos_apfs_pairs.txt"
  else
    for p in "${DEFAULT_PRODUCTS[@]}"; do
      for v in "${DEFAULT_IOS[@]}"; do
        JOBS+=("${p}|${v}|${v}")
      done
    done
  fi
fi

# 支持显式：script pt ios out
if [[ $# -eq 3 && ${#JOBS[@]} -eq 0 ]]; then
  JOBS=("${1//./,}|$2|$3")
fi

# 修正：若用户 `script pt ios out`（3 参），上面 2 参循环会吃掉
if [[ "${1:-}" =~ ^iP && $# -eq 3 ]]; then
  JOBS=("${1//./,}|$2|$3")
fi

echo "[info] jobs=${#JOBS[@]}"

# ---- 准备 Lite ----
if [[ ! -d "${LITE_DIR}/.git" ]]; then
  echo "[git] clone SSHRD_Script_Lite (shallow)…"
  git clone --depth 1 --recursive "$LITE_REPO" "$LITE_DIR"
else
  # GHA 有 cache 时跳过 pull，加快并行任务
  if [[ "${SKIP_LITE_PULL:-0}" == "1" || -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "[git] reuse existing Lite (skip pull)"
    git -C "$LITE_DIR" submodule update --init --recursive --depth 1 || true
  else
    echo "[git] update…"
    git -C "$LITE_DIR" pull --ff-only || true
    git -C "$LITE_DIR" submodule update --init --recursive || true
  fi
fi
chmod +x "${LITE_DIR}"/*.sh 2>/dev/null || true

if [[ ! -s "${LITE_DIR}/ifirmware_parser.sh" && -s "${LITE_DIR}/ifirmware_parser/ifirmware_parser.sh" ]]; then
  cp -f "${LITE_DIR}/ifirmware_parser/ifirmware_parser.sh" "${LITE_DIR}/ifirmware_parser.sh"
fi

# 挂补丁/密钥脚本到 CHECKM8_ROOT/Scripts/baota（优先本夹 lib/，否则 ../baota）
export CHECKM8_ROOT="$ROOT"
mkdir -p "${ROOT}/Scripts"
BAOTA_SRC=""
if [[ -f "${LIB_DIR}/patch_sshrd_lite_a11.sh" ]]; then
  BAOTA_SRC="$LIB_DIR"
elif [[ -f "${SCRIPT_DIR}/../baota/patch_sshrd_lite_a11.sh" ]]; then
  BAOTA_SRC="$(cd "${SCRIPT_DIR}/../baota" && pwd)"
fi
if [[ -n "$BAOTA_SRC" ]]; then
  rm -rf "${ROOT}/Scripts/baota"
  ln -sfn "$BAOTA_SRC" "${ROOT}/Scripts/baota"
fi

# A11 补丁（幂等）
if [[ -x "${ROOT}/Scripts/baota/patch_sshrd_lite_a11.sh" ]]; then
  bash "${ROOT}/Scripts/baota/patch_sshrd_lite_a11.sh" || true
fi
if [[ -x "${ROOT}/Scripts/baota/patch_ifirmware_parser_a11.sh" ]]; then
  bash "${ROOT}/Scripts/baota/patch_ifirmware_parser_a11.sh" || true
fi
# GHA：避免 hdiutil create -srcfolder 挂在 live APFS mount 上卡死
if [[ -x "${ROOT}/Scripts/baota/patch_sshrd_hdiutil_gha.sh" ]]; then
  bash "${ROOT}/Scripts/baota/patch_sshrd_hdiutil_gha.sh" || true
elif [[ -x "${LIB_DIR}/patch_sshrd_hdiutil_gha.sh" ]]; then
  CHECKM8_ROOT="$ROOT" bash "${LIB_DIR}/patch_sshrd_hdiutil_gha.sh" || true
fi
if [[ ! -s "${LITE_DIR}/ifirmware_parser.sh" && -s "${LITE_DIR}/ifirmware_parser/ifirmware_parser.sh" ]]; then
  cp -f "${LITE_DIR}/ifirmware_parser/ifirmware_parser.sh" "${LITE_DIR}/ifirmware_parser.sh"
fi

# Darwin 工具：Lite 自带 tools/Darwin；若缺则尝试官方包
if [[ ! -d "${LITE_DIR}/tools/Darwin" ]] || [[ -z "$(ls -A "${LITE_DIR}/tools/Darwin" 2>/dev/null || true)" ]]; then
  echo "[info] bootstrap Darwin tools (if published)…"
  (
    cd "$LITE_DIR"
    if curl -fsSL -o Darwin_pack.tar.xz \
      "https://raw.githubusercontent.com/mast3rz3ro/sshrd_tools/main/Darwin_pack.tar.xz"; then
      tar -xJf Darwin_pack.tar.xz && rm -f Darwin_pack.tar.xz
      chmod +x tools/Darwin/* 2>/dev/null || true
    else
      echo "[warn] Darwin_pack 下载失败 — 依赖 Lite 仓库自带 tools"
    fi
  ) || true
fi

# ipsw.me：解析版本是否存在；16.7.8 不存在则升到最高 16.7.x
resolve_ios() {
  local pt="$1" want="$2"
  local json url ver
  url="https://api.ipsw.me/v4/device/${pt}?type=ipsw"
  json="$(curl -fsSL --connect-timeout 20 --max-time 60 "$url" 2>/dev/null || true)"
  [[ -n "$json" ]] || {
    echo "$want"
    return 1
  }
  if printf '%s' "$json" | grep -qoE "\"version\"[[:space:]]*:[[:space:]]*\"${want}\""; then
    echo "$want"
    return 0
  fi
  # 16.7.8 等覆盖节点：取该机最高 16.7.x
  if [[ "$want" == 16.7.* || "$want" == "16.7" ]]; then
    ver="$(printf '%s' "$json" | grep -oE '"version"[[:space:]]*:[[:space:]]*"16\.7\.[0-9]+"' \
      | sed -E 's/.*"([^"]+)"/\1/' | sort -t. -k3,3n | tail -n1 || true)"
    if [[ -n "$ver" ]]; then
      echo "[resolve] $pt 无 $want → 使用 $ver" >&2
      echo "$ver"
      return 0
    fi
  fi
  # 16.4 精确缺失时试 16.4.x 最高
  if [[ "$want" == "16.4" ]]; then
    ver="$(printf '%s' "$json" | grep -oE '"version"[[:space:]]*:[[:space:]]*"16\.4(\.[0-9]+)?"' \
      | sed -E 's/.*"([^"]+)"/\1/' | sort -t. -k3,3n | tail -n1 || true)"
    if [[ -n "$ver" ]]; then
      echo "[resolve] $pt 无 16.4 → 使用 $ver" >&2
      echo "$ver"
      return 0
    fi
  fi
  echo "$want"
  return 1
}

fetch_buildid() {
  local pt="$1" ios="$2"
  python3 - "$pt" "$ios" <<'PY'
import json, sys, urllib.request
pt, ios = sys.argv[1], sys.argv[2]
url = "https://api.ipsw.me/v4/device/%s?type=ipsw" % pt
req = urllib.request.Request(url, headers={"User-Agent": "macos-apfs-build"})
with urllib.request.urlopen(req, timeout=60) as r:
    data = json.load(r)
for fw in data.get("firmwares") or []:
    if (fw.get("version") or "").strip() == ios:
        print((fw.get("buildid") or "").strip())
        sys.exit(0)
sys.exit(1)
PY
}

ensure_keys_if_possible() {
  local pt="$1" build="$2" ios="$3"
  if [[ -f "${ROOT}/Scripts/baota/build_a11_ramdisks.py" ]]; then
    CHECKM8_ROOT="$ROOT" PT="$pt" BUILDID="$build" IOS="$ios" python3 - <<'PY' 2>/dev/null || return 1
import os, sys
sys.path.insert(0, os.path.join(os.environ["CHECKM8_ROOT"], "Scripts", "baota"))
import build_a11_ramdisks as m
m.log = lambda msg: print(msg, file=sys.stderr, flush=True)
ok = m.ensure_keys(os.environ["PT"], os.environ["BUILDID"], os.environ["IOS"])
sys.exit(0 if ok else 1)
PY
    return $?
  fi
  return 1
}

pack_one() {
  local pt="$1" ios_req="$2" out_ios="$3"
  local ios board build use_gaster zip src base

  echo "-------- $pt  请求=$ios_req  发布=$out_ios --------"

  if [[ ! "$pt" =~ ^iP(hone|ad|od)[0-9]+,[0-9]+$ ]]; then
    echo "[FAIL] ProductType 须为 iPhone10,6 这种逗号形式"
    return 1
  fi

  zip="${OUT}/${pt}/${out_ios}.zip"
  if [[ "$SKIP_EXISTING" == "1" && -f "$zip" ]]; then
    local sz
    sz="$(stat -f%z "$zip" 2>/dev/null || echo 0)"
    if [[ "$sz" -gt 1000000 ]]; then
      echo "[skip] 已存在 $zip ($sz bytes)"
      echo "$pt $out_ios" >>"$SKIP_LIST"
      return 0
    fi
  fi

  ios="$(resolve_ios "$pt" "$ios_req" || true)"
  if [[ "$PRECHECK_IPSW" == "1" ]]; then
    if ! curl -fsSL --connect-timeout 20 --max-time 60 \
      "https://api.ipsw.me/v4/device/${pt}?type=ipsw" \
      | grep -qoE "\"version\"[[:space:]]*:[[:space:]]*\"${ios}\""; then
      echo "[SKIP] $pt 无 iOS $ios（ipsw.me）"
      echo "$pt $out_ios no_ipsw" >>"$SKIP_LIST"
      return 0
    fi
  fi

  build="$(fetch_buildid "$pt" "$ios" || true)"
  [[ -n "$build" ]] || {
    echo "[FAIL] 无 buildid $pt @$ios"
    return 1
  }
  echo "[info] buildid=$build"

  use_gaster="${USE_GASTER:-0}"
  if [[ "$use_gaster" != "1" ]]; then
    if ensure_keys_if_possible "$pt" "$build" "$ios"; then
      echo "[keys] ok"
      use_gaster=0
    else
      echo "[keys] missing → USE_GASTER=1"
      use_gaster=1
    fi
  fi

  board="${BOARD:-$(default_board "$pt")}"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry] $pt ios=$ios out=$out_ios board=$board gaster=$use_gaster build=$build"
    return 0
  fi

  # Do NOT patch SHSH BORD (breaks Windows gaster load). Board via -m d21ap.
  if [[ "${PATCH_SHSH_BORD:-0}" == "1" && -f "${ROOT}/Scripts/baota/personalize_shsh.py" ]]; then
    echo "[shsh] WARN PATCH_SHSH_BORD=1 — debug only"
    local shsh_cpid="0x8015" sh bak
    case "$pt" in
      iPhone10,*) shsh_cpid="0x8015" ;;
      iPhone9,*) shsh_cpid="0x8010" ;;
    esac
    sh="${LITE_DIR}/misc/shsh/${shsh_cpid}.shsh"
    if [[ -f "$sh" ]]; then
      bak="${sh}.bak-generic"
      [[ -f "$bak" ]] || cp -f "$sh" "$bak"
      python3 "${ROOT}/Scripts/baota/personalize_shsh.py" -i "$bak" -o "$sh" -p "$pt" || true
    fi
  else
    echo "[shsh] keep generic Lite ticket (no BORD byte-patch)"
  fi

  cd "$LITE_DIR"
  rm -rf "${LITE_DIR}/2_ssh_ramdisk" "${LITE_DIR}/1_prepare_ramdisk" 2>/dev/null || true
  mkdir -p "${LITE_DIR}/2_ssh_ramdisk"

  local -a cmd=(./sshrd_lite.sh -p "$pt" -s "$ios" -b "$build")
  [[ "$use_gaster" == "1" ]] && cmd+=(-g)
  [[ -n "$board" ]] && cmd+=(-m "$board")

  echo "[run] ${cmd[*]}"
  set +e
  # 心跳：超过 25 分钟无新日志则杀掉卡住的 hdiutil/sshrd（GHA 常见死锁）
  local try_log="/tmp/macos-sshrd-try.log"
  : >"$try_log"
  (
    stale=0
    last_sz=-1
    while sleep 60; do
      [[ -f "$try_log" ]] || exit 0
      sz="$(wc -c <"$try_log" 2>/dev/null || echo 0)"
      if [[ "$sz" -eq "$last_sz" ]]; then
        stale=$((stale + 1))
      else
        stale=0
        last_sz=$sz
      fi
      echo "[heartbeat] sshrd log=${sz}B stale=${stale}m $(date -u +%H:%M:%S)"
      if [[ "$stale" -ge 25 ]]; then
        echo "[heartbeat] FATAL: no log progress 25m — killing hdiutil/diskimages-helper/sshrd"
        killall -9 hdiutil diskimages-helper 2>/dev/null || true
        pkill -9 -f 'sshrd_lite.sh' 2>/dev/null || true
        exit 0
      fi
    done
  ) &
  local hb_pid=$!
  "${cmd[@]}" 2>&1 | tee "$try_log"
  local code=${PIPESTATUS[0]}
  kill "$hb_pid" 2>/dev/null || true
  wait "$hb_pid" 2>/dev/null || true
  set -e

  # 多板型提示时重试
  if [[ $code -ne 0 ]] && grep -q "Available models" /tmp/macos-sshrd-try.log 2>/dev/null; then
    local alt
    alt="$(grep "Available models" /tmp/macos-sshrd-try.log | tail -n1 | grep -oE '[a-z0-9]+ap' | head -n1 || true)"
    if [[ -n "$alt" && "$alt" != "$board" ]]; then
      echo "[retry] -m $alt"
      cmd=(./sshrd_lite.sh -p "$pt" -s "$ios" -b "$build")
      [[ "$use_gaster" == "1" ]] && cmd+=(-g)
      cmd+=(-m "$alt")
      set +e
      "${cmd[@]}"
      code=$?
      set -e
    fi
  fi

  # 密钥失败再试 gaster
  if [[ $code -ne 0 && "$use_gaster" != "1" ]]; then
    echo "[retry] USE_GASTER=1"
    cmd=(./sshrd_lite.sh -p "$pt" -s "$ios" -b "$build" -g)
    [[ -n "$board" ]] && cmd+=(-m "$board")
    set +e
    "${cmd[@]}"
    code=$?
    set -e
  fi

  if [[ $code -ne 0 ]]; then
    echo "[FAIL] sshrd_lite exit=$code"
    echo "$pt $out_ios build_fail" >>"$FAIL_LIST"
    return 1
  fi

  src="$(find "${LITE_DIR}/2_ssh_ramdisk" -maxdepth 1 -type d -name "${pt}_*" 2>/dev/null | head -n1 || true)"
  if [[ -z "$src" || ! -f "${src}/iBSS.img4" ]]; then
    echo "[FAIL] 无 ${pt}_* 产物"
    find "${LITE_DIR}/2_ssh_ramdisk" -maxdepth 2 -name "*.img4" 2>/dev/null | head || true
    echo "$pt $out_ios no_output" >>"$FAIL_LIST"
    return 1
  fi
  for need in iBSS.img4 iBEC.img4 ramdisk.img4 devicetree.img4 kernelcache.img4; do
    if [[ ! -f "${src}/${need}" ]]; then
      echo "[FAIL] missing $need"
      echo "$pt $out_ios missing_$need" >>"$FAIL_LIST"
      return 1
    fi
  done

  # alpine + intact Lite ticket
  if [[ -f "${ROOT}/Scripts/baota/finalize-github-pack.py" ]]; then
    echo "[finalize] $pt @ $out_ios alpine + Lite ticket"
    python3 "${ROOT}/Scripts/baota/finalize-github-pack.py" \
      --dir "$src" --product "$pt" --lite-dir "$LITE_DIR" \
      || { echo "[FAIL] finalize-github-pack"; echo "$pt $out_ios finalize_fail" >>"$FAIL_LIST"; return 1; }
  fi

  mkdir -p "${OUT}/${pt}"
  local tmpzip="${OUT}/${pt}/.${out_ios}.zip.partial"
  rm -f "$tmpzip"
  (
    cd "$src"
    zip -q -r "$tmpzip" iBSS.img4 iBEC.img4 ramdisk.img4 devicetree.img4 kernelcache.img4 \
      trustcache.img4 logo.img4 bootlogo.img4 2>/dev/null \
      || zip -q -r "$tmpzip" .
  )
  mv -f "$tmpzip" "$zip"
  cp -f "$zip" "${OUT}/${pt}/default.zip"
  # Release 友好扁平名：iPhone10.6-16.7.8.zip
  cp -f "$zip" "${OUT}/${pt//,/.}-${out_ios}.zip"
  ls -lah "$zip"
  unzip -l "$zip" | head -n 15
  echo "[OK] $zip"
  flat="${OUT}/${pt//,/.}-${out_ios}.zip"
  echo "[OK] $flat  (上传 Release 用)"
  echo "$pt $out_ios" >>"$OK_LIST"
  if [[ -n "$ARTIFACT_DIR" ]]; then
    mkdir -p "$ARTIFACT_DIR"
    cp -f "$flat" "${ARTIFACT_DIR}/"
    echo "[artifact] ${ARTIFACT_DIR}/$(basename "$flat")"
  fi
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "artifact_zip=${ARTIFACT_DIR:-$OUT}/$(basename "$flat")" >>"$GITHUB_OUTPUT"
  fi

  # 清理 IPSW 省磁盘
  find "$LITE_DIR" -name "*.ipsw" -delete 2>/dev/null || true
  rm -rf "${LITE_DIR}/2_ssh_ramdisk" "${LITE_DIR}/1_prepare_ramdisk" 2>/dev/null || true
  return 0
}

ok=0
fail=0
skip=0
for job in "${JOBS[@]}"; do
  IFS='|' read -r pt ios out <<<"$job"
  out="${out:-$ios}"
  if pack_one "$pt" "$ios" "$out"; then
    if grep -q "^${pt} ${out} " "$SKIP_LIST" 2>/dev/null || grep -qx "${pt} ${out}" "$SKIP_LIST" 2>/dev/null; then
      skip=$((skip + 1))
    else
      ok=$((ok + 1))
    fi
  else
    fail=$((fail + 1))
  fi
done

echo "======== 完成 ok=$ok fail=$fail skip~=$skip ========"
[[ "$fail" -eq 0 ]] || exit 1
echo "产物目录: $OUT"
echo "扁平包（可上传 GitHub Release ramdisk-20260802-0102）:"
ls -lah "${OUT}"/*-16.*.zip 2>/dev/null || true
echo
echo "上传示例:"
echo "  gh release upload ramdisk-20260802-0102 -R sitzising/checkm8-ramdisk \\"
echo "    ${OUT}/iPhone10.6-16.7.8.zip ${OUT}/iPhone10.1-16.4.zip --clobber"
echo "  # 然后重建索引:"
echo "  python3 Scripts/baota/gha-rebuild-release-index.py --repo sitzising/checkm8-ramdisk --tag ramdisk-20260802-0102"