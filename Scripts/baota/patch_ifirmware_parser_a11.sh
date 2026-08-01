#!/usr/bin/env bash
# 修复 ifirmware_parser.sh：
# 1) 多 kernelcache 时用「首数字」会把 iphone10 截成 iphone1
# 2) dmg 数量≠5 时 ramdisk 为空 → trustcache 变成 .trustcache
set -eu
ROOT="${CHECKM8_ROOT:-/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down}"
export CHECKM8_ROOT="$ROOT"
python3 - <<'PY'
import os
import re
from pathlib import Path

root = os.environ.get("CHECKM8_ROOT", "/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down")
paths = [
    Path(root) / "build/SSHRD_Script_Lite/ifirmware_parser.sh",
    Path(root) / "build/SSHRD_Script_Lite/ifirmware_parser/ifirmware_parser.sh",
]

new_block = r'''		# Parse kernelcache file
		# AC_FIX_KERNEL_RAMDISK: iPhone10,* 多 kernel 时禁止用「首数字」截断（iphone10→iphone1）
		kc_count=$(echo "$files_list" | tr ' ' '\n' | grep -c kernelcache || true)
		product_family=$(echo "$product_name" | awk -F, '{print tolower($1)}')
		kernel_file=''
	if [ "$kc_count" = '1' ]; then
		kernel_file=$(echo "$files_list" | tr ' ' '\n' | grep kernelcache | sed -n 1p)
		echo "[AC-FIX] kernel_file=$kernel_file (family=$product_family kc_count=$kc_count)"
	elif [ "$kc_count" -ge 2 ]; then
		if [ "$product_name" = "iPad4,4" ] || [ "$product_name" = "iPad4,5" ] || [ "$product_name" = "iPad4,6" ]; then
			kernel_file=$(echo "$files_list" | tr ' ' '\n' | grep kernelcache | grep -i 'b$' | sed -n 1p)
		fi
		if [ -z "${kernel_file:-}" ]; then
			kernel_file=$(echo "$files_list" | tr ' ' '\n' | grep -i "kernelcache.*${product_family}$" | sed -n 1p)
		fi
		if [ -z "${kernel_file:-}" ]; then
			kernel_file=$(echo "$files_list" | tr ' ' '\n' | grep -i "kernelcache.*${product_family}" | sed -n 1p)
		fi
		if [ -z "${kernel_file:-}" ]; then
			kernel_file=$(echo "$files_list" | tr ' ' '\n' | grep kernelcache | sed -n 1p)
		fi
		kernel_file=$(echo "$kernel_file" | awk '{print $1}')
		echo "[AC-FIX] kernel_file=$kernel_file (family=$product_family kc_count=$kc_count)"
	else
		echo '[e] Cannot parse the kernel filename !'
		exit 1
	fi
	# AC_FIX2: never allow truncated A11 kernel names (iphone1 vs iphone10)
	case "${product_name}" in
		iPhone10,*|iphone10,*)
			if echo "${kernel_file:-}" | grep -Eqi 'kernelcache\.release\.iphone[0-9]$'; then
				fixed=$(echo "$files_list" | tr ' ' '\n' | grep -i 'kernelcache.release.iphone10$' | sed -n 1p)
				if [ -z "${fixed:-}" ]; then
					fixed=$(echo "$files_list" | tr ' ' '\n' | grep -i 'kernelcache.release.iphone10' | sed -n 1p)
				fi
				if [ -n "${fixed:-}" ]; then
					echo "[AC-FIX2] rewrite kernel_file '$kernel_file' -> '$fixed'"
					kernel_file="$fixed"
				fi
			fi
			;;
	esac
		devicetree_file=$(echo $files_list | tr ' ' '\n' | grep DeviceTree."$product_model" | sed '/plist/d' | awk -F 'DeviceTree.' '{print $2}' | sed -n 1p)
		devicetree_file='DeviceTree.'"$devicetree_file"
		dmg_count=$(echo "$files_list" | tr ' ' '\n' | grep -c '\.dmg$' || true)
		ramdisk_file=''
	if [ "$dmg_count" = "5" ]; then
		ramdisk_file=$(echo "$files_list" | tr ' ' '\n' | grep '\.dmg$' | sed -n 3p)
	fi
	if [ -z "${ramdisk_file:-}" ]; then
		for d in $(echo "$files_list" | tr ' ' '\n' | grep '\.dmg$'); do
			base=$(basename "$d")
			if echo "$files_list" | tr ' ' '\n' | grep -q "${base}.trustcache"; then
				ramdisk_file="$base"
			fi
		done
	fi
	if [ -z "${ramdisk_file:-}" ] && [ "${dmg_count:-0}" -ge 1 ]; then
		ramdisk_file=$(echo "$files_list" | tr ' ' '\n' | grep '\.dmg$' | sed -n '$p')
	fi
		ramdisk_file=$(basename "${ramdisk_file:-}")
		trustcache_file="${ramdisk_file}.trustcache"
		echo "[AC-FIX] ramdisk_file=$ramdisk_file trustcache_file=$trustcache_file dmg_count=$dmg_count"
		return
fi
'''

pat = re.compile(
    r"[ \t]*# Parse kernelcache file\n"
    r".*?"
    r"(?:trustcache_file=\"\$ramdisk_file\"'\.trustcache'|trustcache_file=\"\$\{ramdisk_file\}\.trustcache\")\n"
    r"[ \t]*(?:echo \"\[AC-FIX\] ramdisk_file=.*\n)?"
    r"[ \t]*return\n"
    r"fi\n",
    re.S,
)

for path in paths:
    if not path.is_file():
        print("[skip missing]", path)
        continue
    text = path.read_text(encoding="utf-8", errors="ignore")
    bak = Path(str(path) + ".bak_pre_acfix")
    if not bak.exists():
        bak.write_text(text, encoding="utf-8")
    if "AC_FIX_KERNEL_RAMDISK" in text and "AC_FIX2" in text:
        print("[ok already]", path)
        continue
    m = pat.search(text)
    if not m:
        print("[fail] block not found in", path)
        idx = text.find("Parse kernelcache file")
        print(repr(text[idx:idx + 220]) if idx >= 0 else "no anchor")
        continue
    text = text[: m.start()] + new_block + text[m.end() :]
    path.write_text(text, encoding="utf-8")
    print("[ok patched]", path)
PY
# strip CRLF if any
for f in \
  "$ROOT/build/SSHRD_Script_Lite/ifirmware_parser.sh" \
  "$ROOT/build/SSHRD_Script_Lite/ifirmware_parser/ifirmware_parser.sh"
do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" || true
done
