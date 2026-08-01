#!/usr/bin/env python3
"""Decrypt iPhone10,2 d21 iBSS on server and check product strings + sizes."""
import paramiko

HOST = "tool.a-cheng.cn"
USER = "root"
PASSWORD = "XYP1004xyp"

REMOTE = r'''
set -eu
ROOT=/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down
LITE=$ROOT/build/SSHRD_Script_Lite
PREP="$LITE/1_prepare_ramdisk/iPhone10,2_d21ap_20A362"
TMP=/tmp/ac-verify-d21
rm -rf "$TMP"; mkdir -p "$TMP"
IMG4="$LITE/tools/Linux/img4"
# keys from json via python
eval $(python3 - <<'PY'
import json
from pathlib import Path
j=json.loads(Path("/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/build/SSHRD_Script_Lite/misc/firmware_keys/iPhone10,2_20A362.json").read_text())
for k,v in j.items():
  if "#ibss" in k:
    print(f'IBSS_IV={v["iv"]}')
    print(f'IBSS_KEY={v["key"]}')
  if "#ibec" in k:
    print(f'IBEC_IV={v["iv"]}')
    print(f'IBEC_KEY={v["key"]}')
PY
)
echo "IV=$IBSS_IV"
"$IMG4" -i "$PREP/iBSS.d21.RELEASE.im4p" -o "$TMP/iBSS.dec" -k "${IBSS_IV}${IBSS_KEY}"
"$IMG4" -i "$PREP/iBEC.d21.RELEASE.im4p" -o "$TMP/iBEC.dec" -k "${IBEC_IV}${IBEC_KEY}"
ls -la "$TMP"
python3 - <<'PY'
from pathlib import Path
tmp=Path('/tmp/ac-verify-d21')
for name in ['iBSS.dec','iBEC.dec']:
  d=(tmp/name).read_bytes()
  print(name, 'size', len(d))
  for s in [b'iPhone10,1',b'iPhone10,2',b'iPhone10,3',b'iPhone10,6',b'd21',b'd22',b'iBoot',b'SecureROM']:
    print(' ', s.decode(), 'YES' if s in d else 'no')
  # first bytes
  print('  head', d[:16].hex())
# compare to packed payload
pack=Path('/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/build/SSHRD_Script_Lite/2_ssh_ramdisk/iPhone10,2_d21ap_20A362/iBSS.img4').read_bytes()
# extract raw from IM4P roughly: after type/desc
a=pack.find(b'IM4P'); b=pack.find(b'IM4M')
print('packed im4p region', b-a)
print('packed has iPhone10,3', b'iPhone10,3' in pack[a:b])
print('dec has iPhone10,3', b'iPhone10,3' in (tmp/'iBSS.dec').read_bytes())
print('dec has iPhone10,2', b'iPhone10,2' in (tmp/'iBSS.dec').read_bytes())
PY
'''


def main() -> int:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username=USER, password=PASSWORD, timeout=20)
    stdin, stdout, stderr = ssh.exec_command(REMOTE, timeout=120)
    print(stdout.read().decode("utf-8", "replace"))
    err = stderr.read().decode("utf-8", "replace")
    if err:
        print("STDERR", err[-2500:])
    code = stdout.channel.recv_exit_status()
    print("exit", code)
    ssh.close()
    return code


if __name__ == "__main__":
    raise SystemExit(main())
