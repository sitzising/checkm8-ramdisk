#!/usr/bin/env bash
set -eu
ROOT=/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down
cd "$ROOT"
chmod +x personalize-ramdisk.sh personalize_shsh.py 2>/dev/null || true
chmod +x Scripts/personalize-ramdisk.sh Scripts/personalize_shsh.py 2>/dev/null || true
ls -la personalize-ramdisk.sh personalize_shsh.py
ECID=000C6D3A0160002E
PT=iPhone10,2
VER=16.0
OUT="ramdisks/by-ecid/${ECID}/${PT}/${VER}.zip"
if [[ -f "$OUT" ]]; then
  mv -f "$OUT" "${OUT}.bad-ecid-expand-$(date +%Y%m%d%H%M%S)"
fi
bash ./personalize-ramdisk.sh "$PT" "$VER" "$ECID" 4
ls -la "$OUT"
python3 - <<'PY'
import zipfile, pathlib
z = pathlib.Path("/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/ramdisks/by-ecid/000C6D3A0160002E/iPhone10,2/16.0.zip")
print("exists", z.exists(), "size", z.stat().st_size if z.exists() else None)
with zipfile.ZipFile(z) as zf:
    d = zf.read("iBSS.img4")
im = d.find(b"IM4M")

def ri(tag):
    j = d.find(tag, im)
    p = j + 4
    return int.from_bytes(d[p + 2 : p + 2 + d[p + 1]], "big")

print("ECID", hex(ri(b"ECID")), "BORD", hex(ri(b"BORD")), "CHIP", hex(ri(b"CHIP")))
assert ri(b"BORD") == 4
assert ri(b"ECID") == 0x2131312312, "ECID must stay Lite generic"
print("OK BORD-only personalize")
PY
tail -20 personalize-ramdisk.log || true
