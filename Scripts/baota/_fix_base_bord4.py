#!/usr/bin/env python3
"""Re-personalize generic iPhone10,2 zips to BORD=4 (keep Lite ECID)."""
import paramiko

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect("tool.a-cheng.cn", username="root", password="XYP1004xyp", timeout=20)
cmd = r"""
set -e
ROOT=/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down
cd "$ROOT"
# Rebuild by-ecid again + also overwrite generic base from personalized template
bash ./personalize-ramdisk.sh iPhone10,2 16.0 000C6D3A0160002E 4
SRC=ramdisks/by-ecid/000C6D3A0160002E/iPhone10,2/16.0.zip
for dst in \
  ramdisks/iPhone10,2/16.0.zip \
  ramdisks/iPhone10,2/default.zip \
  ramdisks/iPhone10,2.zip \
  ramdisks/iPhone10.2/16.0.zip \
  ramdisks/iPhone10.2/default.zip \
  ramdisks/iPhone10.2.zip
do
  cp -f "$SRC" "$dst"
  echo copied "$dst"
done
python3 - <<'PY'
import zipfile, glob
for c in sorted(glob.glob('/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/ramdisks/**/16.0.zip', recursive=True)):
    if '10' not in c: continue
    with zipfile.ZipFile(c) as z:
        d=z.read('iBSS.img4')
    im=d.find(b'IM4M')
    def ri(tag):
        j=d.find(tag,im); p=j+4
        return int.from_bytes(d[p+2:p+2+d[p+1]],'big')
    print(c.split('ramdisks')[-1], 'ECID', hex(ri(b'ECID')), 'BORD', hex(ri(b'BORD')))
PY
"""
stdin, stdout, stderr = ssh.exec_command(cmd, timeout=300)
print(stdout.read().decode("utf-8", "replace"))
err = stderr.read().decode("utf-8", "replace")
if err:
    print("STDERR", err[-3000:])
print("exit", stdout.channel.recv_exit_status())
ssh.close()
