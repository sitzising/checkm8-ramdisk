#!/usr/bin/env python3
"""Diagnose whether iPhone10,2 ramdisk packs actually contain d21 (8 Plus) or d22 (X)."""
import paramiko

HOST = "tool.a-cheng.cn"
USER = "root"
PASSWORD = "XYP1004xyp"

REMOTE = r'''
set -eu
ROOT=/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down
LITE=$ROOT/build/SSHRD_Script_Lite
OUT="$LITE/2_ssh_ramdisk/iPhone10,2_d21ap_20A362"

echo "=== OUT ==="
ls -la "$OUT" | head -40

echo "=== img4tool ==="
"$LITE/tools/Linux/img4tool" -a "$OUT/iBSS.img4" 2>&1 | head -50

echo "=== product/board strings in iBSS ==="
python3 - <<'PY'
from pathlib import Path
import re
p = Path("/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/build/SSHRD_Script_Lite/2_ssh_ramdisk/iPhone10,2_d21ap_20A362/iBSS.img4")
d = p.read_bytes()
for pat in [b"iPhone10,1", b"iPhone10,2", b"iPhone10,3", b"iPhone10,4", b"iPhone10,5", b"iPhone10,6",
            b"d21ap", b"d22ap", b"d201ap", b"d211ap", b"D21", b"D22", b"iBSS.d21", b"iBSS.d22"]:
    print(pat.decode(), "YES" if pat in d else "no")
# list Firmware-ish names around build
root = Path("/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/build/SSHRD_Script_Lite")
for x in sorted(root.rglob("*iBSS*"))[:40]:
    print("FILE", x, x.stat().st_size)
for x in sorted(root.rglob("*d21*"))[:40]:
    print("D21", x)
for x in sorted(root.rglob("*d22*"))[:40]:
    print("D22", x)
PY

echo "=== sshrd product mapping snippets ==="
grep -n "iPhone10,2\|d21ap\|d22ap\|BoardConfig\|PRODUCT" "$LITE/sshrd_lite.sh" | head -60

echo "=== rebuild log: which IPSW / iBSS ==="
grep -nE "iPhone10|d21|d22|iBSS|IPSW|Downloading|Extract|BORD|Error|FAIL|20A362" \
  "$ROOT/rebuild-kairos-iPhone10_2.log" | tail -80
'''


def main() -> int:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASSWORD, timeout=20)
    stdin, stdout, stderr = ssh.exec_command(REMOTE, timeout=180)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    print(out)
    if err:
        print("===STDERR===")
        print(err[-3000:])
    print("exit", code)
    ssh.close()
    return code


if __name__ == "__main__":
    raise SystemExit(main())
