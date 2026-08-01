#!/bin/bash
set -euo pipefail
RD=/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down
LITE=$RD/build/SSHRD_Script_Lite
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG=$RD/rebuild-kairos-iPhone10_2.log
echo "======== $(date) kairos rebuild iPhone10,2 @ 20A362 ========" | tee "$LOG"
cd "$LITE"
export LD_LIBRARY_PATH="${RD}/build/compat-lib:${LD_LIBRARY_PATH:-}"
# Lite 默认 0x8015.shsh 的 BORD=0x6（X）；8 Plus 必须改成 0x4，否则票证板号错
if [[ -f misc/shsh/0x8015.shsh && -f "${SCRIPT_DIR}/personalize_shsh.py" ]]; then
  cp -f misc/shsh/0x8015.shsh misc/shsh/0x8015.shsh.bak-generic
  python3 "${SCRIPT_DIR}/personalize_shsh.py" \
    -i misc/shsh/0x8015.shsh.bak-generic \
    -o misc/shsh/0x8015.shsh \
    -p 'iPhone10,2' --bord 4 | tee -a "$LOG"
fi
rm -rf "2_ssh_ramdisk/iPhone10,2_d21ap_20A362" "2_ssh_ramdisk/temp_files"
# -y 1 = kairos（iOS15+ 更稳）；-b 锁定 20A362
./sshrd_lite.sh -p 'iPhone10,2' -b '20A362' -y 1 2>&1 | tee -a "$LOG"
OUT="2_ssh_ramdisk/iPhone10,2_d21ap_20A362"
test -f "$OUT/iBSS.img4"
./tools/Linux/img4tool -a "$OUT/iBSS.img4" 2>&1 | tee -a "$LOG" | head -30
mkdir -p "$RD/ramdisks/iPhone10,2" "$RD/ramdisks/iPhone10.2"
(
  cd "$OUT"
  rm -f "$RD/ramdisks/iPhone10,2/16.0.zip"
  zip -9 "$RD/ramdisks/iPhone10,2/16.0.zip" \
    iBSS.img4 iBEC.img4 ramdisk.img4 devicetree.img4 kernelcache.img4 trustcache.img4 logo.img4
)
cp -f "$RD/ramdisks/iPhone10,2/16.0.zip" "$RD/ramdisks/iPhone10,2/default.zip"
cp -f "$RD/ramdisks/iPhone10,2/16.0.zip" "$RD/ramdisks/iPhone10,2.zip"
cp -f "$RD/ramdisks/iPhone10,2/16.0.zip" "$RD/ramdisks/iPhone10.2/16.0.zip"
cp -f "$RD/ramdisks/iPhone10,2/16.0.zip" "$RD/ramdisks/iPhone10.2/default.zip"
cp -f "$RD/ramdisks/iPhone10,2/16.0.zip" "$RD/ramdisks/iPhone10.2.zip"
ls -lah "$RD/ramdisks/iPhone10,2/16.0.zip" | tee -a "$LOG"
sha256sum "$OUT/iBSS.img4" "$OUT/iBEC.img4" | tee -a "$LOG"
echo DONE | tee -a "$LOG"
