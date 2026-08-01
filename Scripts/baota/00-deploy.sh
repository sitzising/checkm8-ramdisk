#!/usr/bin/env bash
# =============================================================================
# 一键部署站点目录 + PHP API（上传 Scripts/baota 后首先执行）
#
#   bash 00-deploy.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_os_check.sh"
require_supported_os || exit 1

SITE="${SITE_ROOT:-/www/wwwroot/tool.a-cheng.cn}"
A12="${A12_ROOT:-${SITE}/ramdisk/a12-down}"
# 客户端 ActivateServerConfig.A12BaseUrl 指向 a12-up；与 a12-down 同步一份便于直链
A12UP="${A12_UP_ROOT:-${SITE}/ramdisk/a12-up}"
C8="${CHECKM8_ROOT:-${SITE}/ramdisk/checkm8-down}"
ACT="${ACTIVATE_ROOT:-${SITE}/ramdisk/activate}"

echo "======== 部署站点目录 ========"
echo "SITE=$SITE"

mkdir -p \
  "${A12}/Scripts/baota" \
  "${A12}/incoming" \
  "${A12}/ramdisks" \
  "${A12UP}" \
  "${C8}/Scripts/baota" \
  "${C8}/build" \
  "${C8}/ramdisks" \
  "${ACT}/tickets"

# 同步本目录脚本到两个站点（可只保留一份，这里两边各一份方便宝塔路径）
rsync -a --delete \
  --exclude 'build/' --exclude 'ramdisks/' --exclude 'incoming/' \
  --exclude '*.log' --exclude '*.list' \
  "${SCRIPT_DIR}/" "${A12}/Scripts/baota/" 2>/dev/null \
  || cp -a "${SCRIPT_DIR}/." "${A12}/Scripts/baota/"

rsync -a --delete \
  --exclude 'build/' --exclude 'ramdisks/' --exclude 'incoming/' \
  --exclude '*.log' --exclude '*.list' \
  "${SCRIPT_DIR}/" "${C8}/Scripts/baota/" 2>/dev/null \
  || cp -a "${SCRIPT_DIR}/." "${C8}/Scripts/baota/"

chmod +x "${A12}/Scripts/baota/"*.sh "${C8}/Scripts/baota/"*.sh 2>/dev/null || true

cp -f "${SCRIPT_DIR}/a12-ramdisk.php" "${A12}/ramdisk.php"
cp -f "${SCRIPT_DIR}/checkm8-ramdisk.php" "${C8}/ramdisk.php"
cp -f "${SCRIPT_DIR}/checkm8-get.php" "${C8}/get.php"
chmod +x "${C8}/Scripts/baota/personalize-ramdisk.sh" 2>/dev/null || true
chmod +x "${SCRIPT_DIR}/personalize-ramdisk.sh" 2>/dev/null || true

# a12-up：客户端直链目录（可与 a12-down/ramdisks 同步）
if [[ -f "${SCRIPT_DIR}/a12-ramdisk.php" ]]; then
  cp -f "${SCRIPT_DIR}/a12-ramdisk.php" "${A12UP}/ramdisk.php"
fi
# 若 a12-up 空且 a12-down/ramdisks 有 zip，建软链方便直链（不覆盖已有文件）
if [[ -d "${A12}/ramdisks" ]]; then
  shopt -s nullglob
  for z in "${A12}/ramdisks"/*.zip; do
    bn="$(basename "$z")"
    [[ -e "${A12UP}/${bn}" ]] || ln -sfn "$z" "${A12UP}/${bn}" 2>/dev/null \
      || cp -n "$z" "${A12UP}/${bn}" 2>/dev/null || true
  done
  shopt -u nullglob
fi

# A12/A13 激活票 API（优先同目录 activate/，再仓库 server-stubs）
STUB_TICKET=""
for cand in \
  "${SCRIPT_DIR}/activate/ticket.php" \
  "${SCRIPT_DIR}/../../server-stubs/ramdisk-activate/ticket.php" \
  "/tmp/baota-ac/activate/ticket.php"
do
  if [[ -f "$cand" ]]; then STUB_TICKET="$cand"; break; fi
done
if [[ -n "$STUB_TICKET" ]]; then
  cp -f "$STUB_TICKET" "${ACT}/ticket.php"
  chmod 644 "${ACT}/ticket.php" || true
  echo "[OK] activate API: https://tool.a-cheng.cn/ramdisk/activate/ticket.php?ecid=..."
else
  echo "[WARN] 未找到 ticket.php，请手动上传到 ${ACT}/ticket.php"
fi

# IPSW 列表中转（国内客户端拉固件列表）
mkdir -p "${SITE}/ipsw/cache"
if [[ -f "${SCRIPT_DIR}/ipsw/device.php" ]]; then
  cp -f "${SCRIPT_DIR}/ipsw/device.php" "${SITE}/ipsw/device.php"
  chmod 644 "${SITE}/ipsw/device.php" || true
  echo "[OK] IPSW 中转: https://tool.a-cheng.cn/ipsw/device.php?id=iPhone10,2"
fi

# 防目录列表（可选）
[[ -f "${A12}/ramdisks/index.html" ]] || echo 'Forbidden' > "${A12}/ramdisks/index.html"
[[ -f "${C8}/ramdisks/index.html" ]] || echo 'Forbidden' > "${C8}/ramdisks/index.html"
[[ -f "${ACT}/tickets/index.html" ]] || echo 'Forbidden' > "${ACT}/tickets/index.html"
[[ -f "${A12UP}/index.html" ]] || echo 'Forbidden' > "${A12UP}/index.html"

echo
echo "[OK] A12 目录:     $A12"
echo "     上传 ICH 到:  ${A12}/incoming/"
echo "     下载 zip:     ${A12}/ramdisks/  与  ${A12UP}/"
echo "     API: https://tool.a-cheng.cn/ramdisk/a12-down/ramdisk.php?key=iPad11,1"
echo "     直链: https://tool.a-cheng.cn/ramdisk/a12-up/{ProductType用点号}.zip"
echo
echo "[OK] 激活票:       $ACT"
echo "     放票:         ${ACT}/tickets/{ECID}.zip 或目录"
echo "     API: https://tool.a-cheng.cn/ramdisk/activate/ticket.php?ecid=..."
echo
echo "[OK] checkm8 目录: $C8"
echo "     成品 zip:     ${C8}/ramdisks/{ProductType}/{ios}.zip"
echo "     个性化:       ${C8}/ramdisks/by-ecid/{ECID}/{ProductType}/{ios}.zip"
echo "     API: https://tool.a-cheng.cn/ramdisk/checkm8-down/get.php?k=iPhone10.2/16.0&ecid=..."
echo "     部署后请: bash ${C8}/Scripts/baota/rebuild-kairos-iphone10_2.sh   # 或 build-checkm8.sh"
echo
echo "下一步:"
echo "  1) bash ${C8}/Scripts/baota/install-deps.sh"
echo "  2) A12:  bash ${A12}/Scripts/baota/publish-a12.sh"
echo "  3) X以下: bash ${C8}/Scripts/baota/build-checkm8.sh"
echo "======== 部署完成 ========"
