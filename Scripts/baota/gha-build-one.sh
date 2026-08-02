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
# 注意：宝塔上 SCRIPT_DIR 可能已是 $ROOT/Scripts/baota，禁止 rm 自己
SCRIPT_DIR_ABS="$(cd "$SCRIPT_DIR" && pwd)"
TARGET_BAOTA="${ROOT}/Scripts/baota"
TARGET_ABS="$(mkdir -p "$(dirname "$TARGET_BAOTA")" && cd "$(dirname "$TARGET_BAOTA")" && pwd)/baota"
if [[ "$SCRIPT_DIR_ABS" != "$TARGET_ABS" ]]; then
  rm -rf "$TARGET_BAOTA"
  cp -a "$SCRIPT_DIR_ABS" "$TARGET_BAOTA"
else
  echo "[info] Scripts/baota already at CHECKM8_ROOT — skip self-copy"
fi

echo "======== GHA build $PT @ $IOS (out=$OUT_IOS buildid=${BUILDID:-auto}) ========"
echo "ROOT=$ROOT"
df -h / | tail -1 || true

# 依赖（GitHub-hosted 已带 docker；勿 apt 装 docker.io 以免搞坏环境）
if [[ "${SKIP_DEPS:-0}" != "1" ]] && command -v apt-get >/dev/null 2>&1; then
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

# 宿主机也准备 tools + pzb wrapper（docker 会 copy Lite）
if [[ ! -x "${LITE_DIR}/tools/Linux/pzb" && ! -f "${LITE_DIR}/tools/Linux/pzb.real" ]]; then
  echo "[info] host bootstrap Linux_pack.tar.xz"
  (
    cd "$LITE_DIR"
    curl -fsSL -o Linux_pack.tar.xz \
      "https://raw.githubusercontent.com/mast3rz3ro/sshrd_tools/main/Linux_pack.tar.xz"
    tar -xJf Linux_pack.tar.xz
    rm -f Linux_pack.tar.xz
    chmod +x tools/Linux/* 2>/dev/null || true
  )
fi
bash "${ROOT}/Scripts/baota/patch_pzb_wrapper.sh" || true

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

# 预拉 BuildID + TheAppleWiki 固件密钥；缺密钥则改用 gaster -g 解密（Lite 官方支持）
export CHECKM8_ROOT="$ROOT"
USE_GASTER="${USE_GASTER:-0}"
KEYS_OK=0
META_DIR="$(mktemp -d)"
CHECKM8_ROOT="$ROOT" PT="$PT" IOS="$IOS" BUILDID="$BUILDID" META_DIR="$META_DIR" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["CHECKM8_ROOT"], "Scripts", "baota"))
import build_a11_ramdisks as m

m.log = lambda msg: print(msg, file=sys.stderr, flush=True)

pt = os.environ["PT"]
ios = os.environ["IOS"]
meta = os.environ["META_DIR"]
build = (os.environ.get("BUILDID") or "").strip()
if not build:
    build = m.fetch_buildid(pt, ios) or ""
if not build:
    print("[FAIL] no buildid for %s @ %s" % (pt, ios), file=sys.stderr)
    sys.exit(3)
keys_ok = "1" if m.ensure_keys(pt, build, ios) else "0"
if keys_ok == "1":
    print("[keys] ok", file=sys.stderr)
else:
    print("[keys] missing — will try gaster -g decrypt", file=sys.stderr)
open(os.path.join(meta, "buildid"), "w").write(build)
open(os.path.join(meta, "keys_ok"), "w").write(keys_ok)
PY
BUILDID="$(tr -d '\r\n' <"$META_DIR/buildid")"
KEYS_OK="$(tr -d '\r\n' <"$META_DIR/keys_ok")"
rm -rf "$META_DIR"
[[ -n "$BUILDID" ]] || { echo "[FAIL] empty buildid"; exit 3; }
if [[ "$KEYS_OK" == "1" ]]; then
  USE_GASTER=0
  echo "[keys] ready buildid=$BUILDID -> ${LITE_DIR}/misc/firmware_keys/${PT}_${BUILDID}.json"
  ls -lah "${LITE_DIR}/misc/firmware_keys/${PT}_${BUILDID}.json" || true
else
  USE_GASTER=1
  echo "[keys] USE_GASTER=1 buildid=$BUILDID"
fi

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

# iOS 11.x：Lite 在 Linux 上 HFS 改 ramdisk 极易失败 → 软跳过（用更高节点覆盖）
if (( maj < 12 )) && [[ "${FORCE_IOS11:-0}" != "1" ]]; then
  echo "[SKIP] iOS $IOS (<12) Linux/HFS 不稳定；请用 12.5.7/13.7+ 覆盖（FORCE_IOS11=1 可强试）"
  gha_out "skip=true"
  mkdir -p "${OUT}/${PT}"
  echo "ios11_unstable" > "${OUT}/${PT}/${OUT_IOS}.skipped"
  exit 0
fi

export CHECKM8_ROOT="$ROOT"
export USE_GASTER

# 覆盖节点失败时，换同区间更稳的小版本重建（zip 名仍用 OUT_IOS）
alt_ios_list() {
  case "$1" in
    15.0|15.0.*) echo "15.7.1 15.8.3 15.0.2 15.1" ;;
    14.0|14.0.*) echo "14.8.1 14.7.1 14.4.2" ;;
    13.7|13.7.*) echo "13.6 13.5.1 13.4.1" ;;
    12.5.7|12.5.*) echo "12.4.1 12.5.5" ;;
    *) echo "" ;;
  esac
}

try_docker_build() {
  local ios_try="$1" bid_try="$2"
  export USE_GASTER
  set +e
  bash "${ROOT}/Scripts/baota/docker-build-sshrd.sh" "$PT" "$ios_try" "$bid_try" "$OUT_IOS"
  local rc=$?
  set -e
  if [[ $rc -ne 0 && "$USE_GASTER" != "1" ]]; then
    echo "[retry] docker failed (rc=$rc) — retry with USE_GASTER=1 (ios=$ios_try)"
    export USE_GASTER=1
    set +e
    bash "${ROOT}/Scripts/baota/docker-build-sshrd.sh" "$PT" "$ios_try" "$bid_try" "$OUT_IOS"
    rc=$?
    set -e
  fi
  return "$rc"
}

try_docker_build "$IOS" "$BUILDID"
build_rc=$?

# 主版本失败 → 换备用小版本（发布名不变）
if [[ $build_rc -ne 0 || ! -f "${OUT}/${PT}/${OUT_IOS}.zip" ]]; then
  for alt in $(alt_ios_list "$OUT_IOS"); do
    [[ "$alt" == "$IOS" ]] && continue
    echo "[rebuild] try alt ios=$alt → out=$OUT_IOS"
    # 预检 alt 是否有固件
    if [[ "${PRECHECK_IPSW:-1}" == "1" ]]; then
      url="https://api.ipsw.me/v4/device/${PT}?type=ipsw"
      if ! curl -fsSL --connect-timeout 20 --max-time 60 "$url" \
          | grep -qoE "\"version\"[[:space:]]*:[[:space:]]*\"${alt}\""; then
        echo "[rebuild] skip alt $alt (no ipsw)"
        continue
      fi
    fi
    alt_meta="$(mktemp)"
    if ! CHECKM8_ROOT="$ROOT" PT="$PT" IOS="$alt" META="$alt_meta" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["CHECKM8_ROOT"], "Scripts", "baota"))
import build_a11_ramdisks as m
m.log = lambda msg: print(msg, file=sys.stderr, flush=True)
pt, ios = os.environ["PT"], os.environ["IOS"]
b = m.fetch_buildid(pt, ios) or ""
if not b:
    sys.exit(1)
keys_ok = "1" if m.ensure_keys(pt, b, ios) else "0"
open(os.environ["META"], "w").write(b + "\n" + keys_ok + "\n")
PY
    then
      echo "[rebuild] alt $alt no buildid/keys resolve"
      rm -f "$alt_meta"
      continue
    fi
    alt_bid="$(sed -n '1p' "$alt_meta" | tr -d '\r\n')"
    alt_keys="$(sed -n '2p' "$alt_meta" | tr -d '\r\n')"
    rm -f "$alt_meta"
    [[ -n "$alt_bid" ]] || continue
    if [[ "$alt_keys" == "1" ]]; then
      export USE_GASTER=0
    else
      export USE_GASTER=1
    fi
    # 清掉半成品
    rm -rf "${LITE_DIR}/2_ssh_ramdisk" "${LITE_DIR}/1_prepare_ramdisk" 2>/dev/null || true
    try_docker_build "$alt" "$alt_bid"
    build_rc=$?
    if [[ $build_rc -eq 0 && -f "${OUT}/${PT}/${OUT_IOS}.zip" ]]; then
      echo "[rebuild] OK via alt ios=$alt → ${OUT_IOS}.zip"
      break
    fi
  done
fi

zip="${OUT}/${PT}/${OUT_IOS}.zip"
if [[ ! -f "$zip" ]]; then
  echo "[FAIL] build failed rc=${build_rc:-?} missing $zip"
  mkdir -p "${OUT}/${PT}"
  echo "build_failed" > "${OUT}/${PT}/${OUT_IOS}.skipped"
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
