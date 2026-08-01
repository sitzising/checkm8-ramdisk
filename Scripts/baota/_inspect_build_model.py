#!/usr/bin/env python3
import paramiko

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect("tool.a-cheng.cn", username="root", password="XYP1004xyp", timeout=20)
cmd = r"""
set -e
ROOT=/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down
echo "=== logs ==="
ls -lt "$ROOT"/*iPhone10* "$ROOT"/*kairos* "$ROOT"/*rebuild* 2>/dev/null | head -20
echo "=== kairos log tail ==="
tail -120 "$ROOT/rebuild-kairos-iPhone10_2.log" 2>/dev/null || echo no-kairos-log
echo "=== grep model ==="
grep -Ehn "MODEL|d201|d221|D201|D221|BORD|replace|iPhone10|BoardConfig|ibss" \
  "$ROOT/rebuild-kairos-iPhone10_2.log" \
  "$ROOT/rebuild-iPhone10_2-iboot64.log" \
  "$ROOT/docker-build-iPhone10_2-16.0.log" \
  "$ROOT/rebuild-iPhone10_2-20A362.log" 2>/dev/null | tail -80
echo "=== BuildManifest strings ==="
python3 - <<'PY'
from pathlib import Path
import re
p=Path('/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/build/SSHRD_Script_Lite/BuildManifest.plist')
print('exists', p.exists(), 'size', p.stat().st_size if p.exists() else 0)
if p.exists():
  t=p.read_text('utf-8','replace')
  for pat in ['iPhone10,2','iPhone10,3','iPhone10,6','D201AP','D221AP','d201ap','d221ap','BoardConfig']:
    print(pat, t.find(pat))
  # extract first DeviceClass / SupportedProductType near ibss
  m=re.search(r'iBSS[^.]{0,40}\.im4p', t)
  print('ibss path sample', m.group(0) if m else None)
  # all unique ibss paths
  paths=sorted(set(re.findall(r'Firmware/dfu/iBSS\.[^<]+', t)))
  print('ibss paths', paths[:10])
PY
echo "=== rebuild script on server ==="
ls -la "$ROOT"/Scripts/rebuild*.sh "$ROOT"/rebuild*.sh 2>/dev/null || true
head -80 "$ROOT/Scripts/rebuild-kairos-iphone10_2.sh" 2>/dev/null || head -80 "$ROOT/rebuild-kairos-iphone10_2.sh" 2>/dev/null || true
"""
stdin, stdout, stderr = ssh.exec_command(cmd, timeout=90)
print(stdout.read().decode("utf-8", "replace"))
err = stderr.read().decode("utf-8", "replace")
if err:
    print("STDERR", err[-4000:])
print("exit", stdout.channel.recv_exit_status())
ssh.close()
