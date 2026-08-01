#!/usr/bin/env bash
# 系统检查：SSHRD 自带 Linux 工具需要较新的 glibc / libstdc++
# CentOS 7 / RHEL 7 明确不支持。
require_supported_os() {
  if [[ -f /etc/redhat-release ]] && grep -qE 'CentOS.*(release )?7|Red Hat Enterprise Linux.*(release )?7|Scientific Linux.*7' /etc/redhat-release 2>/dev/null; then
    cat <<'EOF'
[ERR] 不支持 CentOS 7 / RHEL 7。

  SSHRD 自带的 pzb 等工具需要 GLIBCXX_3.4.21+，CentOS7 系统库太旧，无法稳定构建。

  请新开一台云服务器（推荐）：
    · Ubuntu 22.04 LTS（宝塔官方支持最好）
    · Ubuntu 20.04 LTS
    · Debian 11 / 12
    · Rocky Linux 8/9 或 AlmaLinux 8/9

  然后重装宝塔，再上传本 Scripts/baota 目录。
EOF
    return 1
  fi

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
      centos:7*|rhel:7*)
        echo "[ERR] 不支持 ${PRETTY_NAME:-old OS}"
        return 1
        ;;
    esac
  fi
  return 0
}
