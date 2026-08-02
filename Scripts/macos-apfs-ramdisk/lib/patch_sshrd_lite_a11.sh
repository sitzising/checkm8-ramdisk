#!/usr/bin/env bash
# 给 SSHRD_Script_Lite/sshrd_lite.sh 打上 A11（t8015 / cpid 0x8015）专用 boot-args（幂等）
# boot-args: rd=md0 -v wdt=-1 cs_enforcement=0 amfi=0xff keepsyms=1
set -eu
ROOT="${CHECKM8_ROOT:-/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down}"
export CHECKM8_ROOT="$ROOT"
python3 - <<'PY'
import os
import re
from pathlib import Path

root = os.environ.get("CHECKM8_ROOT", "/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down")
path = Path(root) / "build/SSHRD_Script_Lite/sshrd_lite.sh"
text = path.read_text(encoding="utf-8", errors="ignore")
bak = path.with_suffix(path.suffix + ".bak_pre_a11")
if not bak.exists():
    bak.write_text(text, encoding="utf-8")

A11_ARGS = "rd=md0 -v wdt=-1 cs_enforcement=0 amfi=0xff keepsyms=1"
marker = "AC_A11_BOOTARGS_PATCH"
new_block = """\t\t# Set boot arguments
\t\t# %s
\t\tif [ \"$cpid\" = '0x8015' ]; then
\t\t\tboot_args='%s'
\t\t\techo \"[AC-A11] boot-args=$boot_args\"
\t\telif [ \"$cpid\" = '0x8960' ] || [ \"$cpid\" = '0x7000' ] || [ \"$cpid\" = '0x7001' ]; then
\t\t\tboot_args='rd=md0 debug=0x2014e -v wdt=-1 nand-enable-reformat=1 -restore -n'
\t\telse
\t\t\tboot_args='rd=md0 debug=0x2014e -v wdt=-1 -n'
\t\tfi
""" % (marker, A11_ARGS)

if marker in text:
    text = re.sub(
        r"(if \[ \"\$cpid\" = '0x8015' \]; then\n\t\t\tboot_args=')([^']*)(')",
        r"\1" + A11_ARGS + r"\3",
        text,
        count=1,
    )
else:
    m = re.search(
        r"[ \t]*# Set boot arguments\r?\n[ \t]*if \[ \"\$cpid\" = '0x8960' \].*?; fi\r?\n",
        text,
        re.S,
    )
    if not m:
        # already patched style without marker
        m2 = re.search(
            r"[ \t]*# Set boot arguments\r?\n.*?boot_args='rd=md0[^\n]*'\r?\n\t\tfi\r?\n",
            text,
            re.S,
        )
        if not m2:
            raise SystemExit("boot_args block not found")
        text = text[: m2.start()] + new_block + text[m2.end() :]
    else:
        text = text[: m.start()] + new_block + text[m.end() :]

# trustcache 打包日志（提示 sshtar + rtsc；实际 untar/pack 由 Lite 原逻辑完成）
if "AC-A11] packing trustcache" not in text:
    text = text.replace(
        "echo '[!] Found trustcache file :' \"$trustcache_file\"",
        "echo '[!] Found trustcache file :' \"$trustcache_file\"\n"
        "\t\techo '[AC-A11] packing trustcache (ssh.tar dropbear/sftp/bash + KPlooshFinder + boot-args)'",
        1,
    )

path.write_text(text, encoding="utf-8")
print("[ok] patched", path, "boot-args=", A11_ARGS)
PY
