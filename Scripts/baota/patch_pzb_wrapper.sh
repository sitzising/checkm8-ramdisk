#!/usr/bin/env bash
# 给 tools/Linux/pzb 加包装：原版 Linux pzb 忽略 -o 目录，只写 CWD。
# 包装后：若 -o 含路径，先 cd 到目录再调用真实 pzb，并按目标文件名归位。
set -eu
ROOT="${CHECKM8_ROOT:-/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down}"
LITE="${ROOT}/build/SSHRD_Script_Lite"
PZB_DIR="${LITE}/tools/Linux"
PZB="${PZB_DIR}/pzb"

if [[ ! -e "$PZB" ]]; then
  echo "[pzb-wrap] missing $PZB — skip (bootstrap Linux_pack first)"
  exit 0
fi

if head -n 2 "$PZB" 2>/dev/null | grep -q 'AC_PZB_WRAPPER'; then
  echo "[pzb-wrap] already wrapped"
  exit 0
fi

if [[ ! -f "${PZB_DIR}/pzb.real" ]]; then
  cp -f "$PZB" "${PZB_DIR}/pzb.real"
fi
chmod +x "${PZB_DIR}/pzb.real"

cat > "$PZB" <<'EOF'
#!/usr/bin/env bash
# AC_PZB_WRAPPER — make -o DIRECTORY/file work on Linux pzb
set -e
REAL="$(cd "$(dirname "$0")" && pwd)/pzb.real"
OUT=""
ARGS=()
REMOTE=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then
    OUT="$a"
    prev=""
    continue
  fi
  if [[ "$a" == "-o" ]]; then
    prev="-o"
    continue
  fi
  if [[ "$prev" == "-g" ]]; then
    REMOTE="$a"
    prev=""
    ARGS+=("-g" "$a")
    continue
  fi
  if [[ "$a" == "-g" ]]; then
    prev="-g"
    continue
  fi
  ARGS+=("$a")
done
# 若 -g 用了上面分支已吃掉；补全未配对的 -g
if [[ "$prev" == "-g" ]]; then
  ARGS+=("-g")
fi

if [[ -z "$OUT" ]]; then
  exec "$REAL" "$@"
fi

dir="$(dirname "$OUT")"
base="$(basename "$OUT")"
mkdir -p "$dir"
remote_base="$(basename "${REMOTE:-BuildManifest.plist}")"

(
  cd "$dir"
  rm -f "./$base" "./$remote_base"
  set +e
  "$REAL" "${ARGS[@]}" -o "./$base"
  rc=$?
  set -e
  if [[ ! -s "./$base" ]]; then
    set +e
    "$REAL" "${ARGS[@]}"
    set -e
  fi
  if [[ ! -s "./$base" && -s "./$remote_base" ]]; then
    mv -f "./$remote_base" "./$base"
  fi
  if [[ ! -s "./$base" ]]; then
    # 兜底：刚写出的最大新文件
    newest="$(find . -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2- | sed 's|^\./||')"
    if [[ -n "$newest" && -s "./$newest" ]]; then
      mv -f "./$newest" "./$base"
    fi
  fi
  if [[ ! -s "./$base" ]]; then
    echo "[AC_PZB_WRAPPER] FAIL: could not produce $OUT" >&2
    exit 1
  fi
  exit 0
)
EOF
chmod +x "$PZB"
echo "[pzb-wrap] ok $PZB -> pzb.real"
