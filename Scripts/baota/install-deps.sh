#!/usr/bin/env bash
# =============================================================================
# 安装构建依赖（仅支持 Ubuntu 20.04+ / Debian 11+ / Rocky·Alma 8+）
# 不支持 CentOS 7。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_os_check.sh"
require_supported_os || exit 1

echo "======== 安装依赖 ========"
echo "OS: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    git curl wget zip unzip ca-certificates \
    python3 python3-pip \
    build-essential pkg-config \
    libusb-1.0-0-dev libssl-dev \
    jq aria2 \
    || apt-get install -y git curl wget zip unzip ca-certificates python3
  apt-get install -y git-lfs 2>/dev/null || true
  git lfs install 2>/dev/null || true

elif command -v dnf >/dev/null 2>&1; then
  dnf install -y epel-release 2>/dev/null || true
  dnf install -y \
    git curl wget zip unzip ca-certificates \
    python3 python3-pip \
    gcc gcc-c++ make pkgconf-pkg-config \
    libusb-devel openssl-devel \
    jq aria2 \
    || dnf install -y git curl wget zip unzip python3
  dnf install -y git-lfs 2>/dev/null || true
  git lfs install 2>/dev/null || true

elif command -v yum >/dev/null 2>&1; then
  # Rocky/Alma 8 仍可能有 yum 包装；CentOS7 已在上面拦截
  yum install -y epel-release 2>/dev/null || true
  yum install -y git curl wget zip unzip ca-certificates python3 python3-pip \
    gcc gcc-c++ make libusb-devel openssl-devel jq aria2 \
    || yum install -y git curl wget zip unzip python3
else
  echo "[ERR] 未找到 apt/dnf/yum"
  exit 1
fi

for bin in git curl zip python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[ERR] 缺少: $bin"; exit 1; }
done

# 确认 libstdc++ 够新（Ubuntu20+/Rocky8 通常 OK）
if ! strings /usr/lib/x86_64-linux-gnu/libstdc++.so.6 2>/dev/null | grep -q 'GLIBCXX_3\.4\.21' \
  && ! strings /lib64/libstdc++.so.6 2>/dev/null | grep -q 'GLIBCXX_3\.4\.21'; then
  echo "[WARN] 未检测到 GLIBCXX_3.4.21，SSHRD 的 pzb 可能失败。请换 Ubuntu 22.04。"
fi

echo "[OK] git=$(command -v git)"
echo "[OK] curl=$(command -v curl)"
echo "[OK] zip=$(command -v zip)"
echo "[OK] python3=$(command -v python3)"
echo "======== 依赖安装完成 ========"
