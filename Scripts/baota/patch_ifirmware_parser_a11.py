#!/usr/bin/env python3
import re
from pathlib import Path

paths = [
    Path("/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/build/SSHRD_Script_Lite/ifirmware_parser.sh"),
    Path("/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/build/SSHRD_Script_Lite/ifirmware_parser/ifirmware_parser.sh"),
]

new_block = r'''		# Parse kernelcache file
		# AC_FIX_KERNEL_RAMDISK: fix iPhone10,* truncation (iphone10 -> iphone1) + empty ramdisk
		kc_count=$(echo "$files_list" | tr ' ' '\n' | grep -c kernelcache || true)
		product_family=$(echo "$product_name" | awk -F, '{print tolower($1)}')
		kernel_file=''
	if [ "$kc_count" = '1' ]; then
		kernel_file=$(echo "$files_list" | tr ' ' '\n' | grep kernelcache | sed -n 1p)
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
    r"[ \t]*trustcache_file=\"\$ramdisk_file\"'\.trustcache'\n"
    r"[ \t]*return\n"
    r"fi\n",
    re.S,
)

for path in paths:
    if not path.is_file():
        print("missing", path)
        continue
    text = path.read_text(encoding="utf-8", errors="ignore")
    bak = Path(str(path) + ".bak_pre_acfix")
    if not bak.exists():
        bak.write_text(text, encoding="utf-8")
    if "AC_FIX_KERNEL_RAMDISK" in text:
        print("already", path)
        continue
    m = pat.search(text)
    if not m:
        print("NO MATCH", path)
        idx = text.find("Parse kernelcache")
        print(repr(text[idx:idx+400]))
        continue
    text = text[:m.start()] + new_block + text[m.end():]
    path.write_text(text, encoding="utf-8")
    print("patched", path)
PY