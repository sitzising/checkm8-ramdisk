#!/usr/bin/env bash
# =============================================================================
# CentOS 7：为 SSHRD 自带的 pzb 提供较新的 libstdc++（需 GLIBCXX_3.4.21）
#
# 用法：
#   bash centos7-libstdcxx.sh
#   # 或在其它脚本里：
#   source ./centos7-libstdcxx.sh && enable_centos7_libstdcxx
# =============================================================================

_need_new_libstdcxx() {
  local lib="${1:-/lib64/libstdc++.so.6}"
  [[ -f "$lib" ]] || return 0
  if strings "$lib" 2>/dev/null | grep -q 'GLIBCXX_3\.4\.21'; then
    return 1
  fi
  return 0
}

_find_scl_libdir() {
  local d
  for d in \
    /opt/rh/devtoolset-11/root/usr/lib64 \
    /opt/rh/devtoolset-10/root/usr/lib64 \
    /opt/rh/devtoolset-9/root/usr/lib64 \
    /opt/rh/devtoolset-8/root/usr/lib64 \
    /opt/rh/devtoolset-7/root/usr/lib64
  do
    if [[ -e "${d}/libstdc++.so.6" ]] && strings "${d}/libstdc++.so.6" 2>/dev/null | grep -q 'GLIBCXX_3\.4\.21'; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

_rpm_name="devtoolset-9-libstdc++-devel-9.3.1-2.2.el7.x86_64.rpm"

# 国内镜像优先（vault.centos.org 在国内经常超时）
_rpm_urls() {
  cat <<EOF
https://mirrors.aliyun.com/centos-vault/7.9.2009/sclo/x86_64/rh/Packages/d/${_rpm_name}
https://mirrors.tuna.tsinghua.edu.cn/centos-vault/7.9.2009/sclo/x86_64/rh/Packages/d/${_rpm_name}
https://mirrors.cloud.tencent.com/centos-vault/7.9.2009/sclo/x86_64/rh/Packages/d/${_rpm_name}
https://mirrors.huaweicloud.com/centos-vault/7.9.2009/sclo/x86_64/rh/Packages/d/${_rpm_name}
https://vault.centos.org/7.9.2009/sclo/x86_64/rh/Packages/d/${_rpm_name}
https://dl.rockylinux.org/vault/centos/7.9.2009/sclo/x86_64/rh/Packages/d/${_rpm_name}
EOF
}

_write_aliyun_sclo_repo() {
  cat >/etc/yum.repos.d/centos7-sclo-rh-aliyun.repo <<'EOF'
[centos7-sclo-rh-aliyun]
name=CentOS-7 - SCLo rh (aliyun vault)
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/sclo/x86_64/rh/
gpgcheck=0
enabled=1

[centos7-sclo-rh-tuna]
name=CentOS-7 - SCLo rh (tuna vault)
baseurl=https://mirrors.tuna.tsinghua.edu.cn/centos-vault/7.9.2009/sclo/x86_64/rh/
gpgcheck=0
enabled=0
EOF
  echo "[libstdc++] 已写入临时 yum 源: /etc/yum.repos.d/centos7-sclo-rh-aliyun.repo"
}

_install_scl() {
  echo "[libstdc++] 尝试 yum 安装 SCL libstdc++…"
  _write_aliyun_sclo_repo
  yum clean all >/dev/null 2>&1 || true
  yum install -y --enablerepo=centos7-sclo-rh-aliyun \
    devtoolset-9-libstdc++-devel 2>&1 | tail -n 30 || true
  if ! _find_scl_libdir >/dev/null 2>&1; then
    yum install -y --enablerepo=centos7-sclo-rh-aliyun \
      devtoolset-9-gcc-c++ 2>&1 | tail -n 20 || true
  fi
}

_ensure_rpm2cpio() {
  if command -v rpm2cpio >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
    return 0
  fi
  echo "[libstdc++] 安装 rpm2cpio / cpio…"
  yum install -y cpio rpm2cpio 2>/dev/null || yum install -y cpio 2>/dev/null || true
  command -v rpm2cpio >/dev/null 2>&1 || command -v rpm >/dev/null 2>&1
}

_extract_rpm_to() {
  local rpm="$1" dest="$2"
  mkdir -p "$dest"
  if command -v rpm2cpio >/dev/null 2>&1; then
    (cd "$dest" && rpm2cpio "$rpm" | cpio -idmu)
    return $?
  fi
  # 兜底：rpm2cpio 不存在时用 rpm -ivh 到临时 root（不碰系统）
  if command -v rpm >/dev/null 2>&1; then
    rpm -ivh --nodeps --force --root="$dest" "$rpm" 2>/dev/null || \
      rpm2cpio "$rpm" > /dev/null 2>&1
    return $?
  fi
  return 1
}

_download_file() {
  local url="$1" out="$2"
  echo "[libstdc++] 下载: $url"
  if command -v curl >/dev/null 2>&1; then
    if curl -fL --connect-timeout 15 --max-time 300 --retry 2 --retry-delay 2 -o "$out" "$url"; then
      return 0
    fi
  fi
  if command -v wget >/dev/null 2>&1; then
    if wget -T 30 -t 2 -O "$out" "$url"; then
      return 0
    fi
  fi
  return 1
}

_copy_libstdcxx_from_tree() {
  local tree="$1" dest="$2"
  local found
  # 真文件优先（.so.6.0.xx），不要只拷软链
  found="$(find "$tree" \( -name 'libstdc++.so.6.*' -o -name 'libstdc++.so.6' \) 2>/dev/null \
    | while read -r p; do [[ -f "$p" && ! -L "$p" ]] && echo "$p"; done | head -n1 || true)"
  if [[ -z "$found" ]]; then
    found="$(find "$tree" -name 'libstdc++.so.6*' 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "$found" ]] || return 1

  mkdir -p "$dest"
  # 拷贝同目录下相关 so
  local dir
  dir="$(dirname "$found")"
  cp -a "${dir}"/libstdc++.so* "$dest/" 2>/dev/null || cp -f "$found" "$dest/"
  # 保证 libstdc++.so.6 存在
  if [[ ! -e "${dest}/libstdc++.so.6" ]]; then
    local real
    real="$(basename "$(ls -1 "${dest}"/libstdc++.so.6.* 2>/dev/null | head -n1)")"
    [[ -n "$real" ]] && ln -sfn "$real" "${dest}/libstdc++.so.6"
  fi
  # 若 .so.6 是坏软链，改指真实文件
  if [[ -L "${dest}/libstdc++.so.6" && ! -e "${dest}/libstdc++.so.6" ]]; then
    local real2
    real2="$(basename "$(ls -1 "${dest}"/libstdc++.so.6.* 2>/dev/null | head -n1)")"
    [[ -n "$real2" ]] && ln -sfn "$real2" "${dest}/libstdc++.so.6"
  fi
  echo "[libstdc++] 找到: $found → $dest"
  return 0
}

_install_compat_extract() {
  local dest="$1"
  mkdir -p "$dest"
  if [[ -e "${dest}/libstdc++.so.6" ]] && strings "${dest}/libstdc++.so.6" 2>/dev/null | grep -q 'GLIBCXX_3\.4\.21'; then
    echo "[libstdc++] 已有兼容库: $dest"
    return 0
  fi

  _ensure_rpm2cpio || true

  local tmp rpm ok=0
  tmp="$(mktemp -d)"
  rpm="${tmp}/${_rpm_name}"

  while read -r url; do
    [[ -n "$url" ]] || continue
    rm -f "$rpm"
    if _download_file "$url" "$rpm"; then
      local sz
      sz="$(stat -c%s "$rpm" 2>/dev/null || echo 0)"
      if [[ "$sz" -lt 100000 ]]; then
        echo "[libstdc++] 文件过小($sz)，跳过: $url"
        continue
      fi
      echo "[libstdc++] 解压 rpm (${sz} bytes)…"
      rm -rf "${tmp}/root"
      mkdir -p "${tmp}/root"
      if _extract_rpm_to "$rpm" "${tmp}/root"; then
        if _copy_libstdcxx_from_tree "${tmp}/root" "$dest"; then
          ok=1
          break
        fi
        echo "[libstdc++] rpm 已下但未找到 libstdc++.so.6*，列目录："
        find "${tmp}/root" -name '*stdc*' 2>/dev/null | head -n 40 || true
      else
        echo "[libstdc++] 解压失败（需要 rpm2cpio+cpio）。尝试: yum install -y cpio"
      fi
    else
      echo "[libstdc++] 下载失败: $url"
    fi
  done < <(_rpm_urls)

  rm -rf "$tmp"

  if [[ "$ok" -ne 1 ]]; then
    echo "[ERR] 无法获取较新 libstdc++。"
    echo "手动一键（推荐，阿里云镜像）："
    echo "  curl -fL -o /tmp/libstd.rpm \\"
    echo "    https://mirrors.aliyun.com/centos-vault/7.9.2009/sclo/x86_64/rh/Packages/d/${_rpm_name}"
    echo "  mkdir -p ${dest} && cd /tmp && rm -rf extr && mkdir extr && cd extr"
    echo "  yum install -y cpio && rpm2cpio /tmp/libstd.rpm | cpio -idmu"
    echo "  find . -name 'libstdc++.so.6*' -exec cp -a {} ${dest}/ \\;"
    echo "  cd ${dest} && ls -la && ln -sfn \$(ls libstdc++.so.6.* | head -1) libstdc++.so.6"
    return 1
  fi

  if strings "${dest}/libstdc++.so.6" 2>/dev/null | grep -q 'GLIBCXX_3\.4\.21'; then
    echo "[OK] 兼容 libstdc++ → $dest"
    strings "${dest}/libstdc++.so.6" | grep 'GLIBCXX_3\.4\.2' | tail -n 5
    return 0
  fi
  echo "[ERR] 解压后的库仍无 GLIBCXX_3.4.21"
  ls -la "$dest" || true
  return 1
}

enable_centos7_libstdcxx() {
  if ! _need_new_libstdcxx /lib64/libstdc++.so.6; then
    echo "[libstdc++] 系统库已含 GLIBCXX_3.4.21，无需处理"
    return 0
  fi

  local root="${CHECKM8_ROOT:-/www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down}"
  local compat="${COMPAT_LIBDIR:-${root}/build/compat-lib}"
  local libdir=""

  # 已有手搓 compat-lib（Ubuntu libstdc++.so）则直接用，避免反复 yum/devel rpm
  if [[ -e "${compat}/libstdc++.so.6" ]]; then
    export LD_LIBRARY_PATH="${compat}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    echo "[libstdc++] 使用已有兼容库: $compat"
    return 0
  fi

  echo "[libstdc++] 系统 /lib64/libstdc++.so.6 过旧（CentOS7 常见），开始准备兼容库…"

  libdir="$(_find_scl_libdir || true)"
  if [[ -z "$libdir" ]]; then
    _install_scl || true
    libdir="$(_find_scl_libdir || true)"
  fi

  if [[ -z "$libdir" ]]; then
    _install_compat_extract "$compat" || return 1
    libdir="$compat"
  fi

  export LD_LIBRARY_PATH="${libdir}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  echo "[libstdc++] LD_LIBRARY_PATH 已加入: $libdir"

  if [[ ! -e "${libdir}/libstdc++.so.6" ]]; then
    echo "[ERR] 兼容库无效: ${libdir}/libstdc++.so.6"
    return 1
  fi

  # 快速测 pzb（若已 clone）
  local pzb="${root}/build/SSHRD_Script_Lite/tools/Linux/pzb"
  if [[ -x "$pzb" ]]; then
    if "$pzb" 2>&1 | head -n 3 | grep -q GLIBCXX; then
      echo "[ERR] pzb 仍报 GLIBCXX，请检查: ldd $pzb"
      return 1
    fi
    echo "[OK] pzb 可加载（已不再报 GLIBCXX）"
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  set -euo pipefail
  enable_centos7_libstdcxx
  echo "当前 LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
fi
