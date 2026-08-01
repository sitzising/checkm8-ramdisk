#!/usr/bin/env python3
import paramiko

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect("tool.a-cheng.cn", username="root", password="XYP1004xyp", timeout=20)
cmd = r"""
ROOT=/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down
find "$ROOT/ramdisks" -name '*.zip' | head -60
echo '---PHP---'
ls -la "$ROOT"/*.php 2>/dev/null | head
echo '---TICKETS---'
python3 - <<'PY'
import glob, zipfile, hashlib, os
root='/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down'
for c in sorted(glob.glob(root+'/ramdisks/**/*.zip', recursive=True)):
    try:
        with zipfile.ZipFile(c) as z:
            ns=[n for n in z.namelist() if n.lower().endswith('ibss.img4')]
            if not ns: continue
            d=z.read(ns[0])
        im=d.find(b'IM4M'); i=d.find(b'IM4P')
        def ri(tag):
            j=d.find(tag, im); p=j+4
            return int.from_bytes(d[p+2:p+2+d[p+1]], 'big')
        rel=c.replace(root,'')
        print(rel, 'sz', len(d), 'im4p', hashlib.sha256(d[i:im]).hexdigest()[:12],
              'ECID', hex(ri(b'ECID')), 'BORD', hex(ri(b'BORD')))
    except Exception as e:
        print('err', c, e)
PY
echo '---BUILD LOG---'
ls -lt "$ROOT"/*.log "$ROOT"/build/*.log 2>/dev/null | head -10
tail -40 "$ROOT"/personalize-ramdisk.log 2>/dev/null || true
# check BuildManifest model used if work dir remains
find "$ROOT/build" -name 'BuildManifest.plist' 2>/dev/null | head -5
"""
stdin, stdout, stderr = ssh.exec_command(cmd, timeout=180)
print(stdout.read().decode("utf-8", "replace"))
err = stderr.read().decode("utf-8", "replace")
if err:
    print("STDERR", err[-3000:])
print("exit", stdout.channel.recv_exit_status())
ssh.close()
