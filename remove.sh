#!/bin/bash
# ----------------------------------------------
# Robust Docker uninstallation script (cross-distro)
# ----------------------------------------------
set -euo pipefail

# Require root privileges
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root or with sudo." >&2
  exit 1
fi

log() { echo -e "[Docker-Remove] $*"; }

# Stop and disable services if they exist
for svc in docker containerd; do
  if systemctl list-unit-files | grep -q "${svc}.service"; then
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  fi
  service "$svc" stop 2>/dev/null || true
  pkill -f "$svc" 2>/dev/null || true
done

# Detect package manager and remove packages
remove_pkgs() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get purge -y docker\* containerd.io docker-compose-plugin docker-buildx-plugin || true
    apt-get autoremove -y || true
    rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    apt-get update -y || true
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    local YUM_TOOL="$(command -v dnf || command -v yum)"
    $YUM_TOOL remove -y docker\* containerd.io || true
    $YUM_TOOL autoremove -y || true
    rm -f /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Rns --noconfirm docker docker-compose containerd || true
  elif command -v zypper >/dev/null 2>&1; then
    zypper remove -y docker docker-compose containerd || true
  else
    log "Unknown package manager, attempting to delete binaries only."
  fi
}

remove_pkgs

# Delete residual data and configs
rm -rf /var/lib/docker /var/lib/containerd /etc/docker /run/docker 2>/dev/null || true
rm -rf "$HOME/.docker" 2>/dev/null || true

# Remove binaries that may have been installed manually
for bin in docker dockerd docker-compose containerd; do
  rm -f "/usr/local/bin/$bin" "/usr/bin/$bin" 2>/dev/null || true
done

# Final check
if command -v docker >/dev/null 2>&1; then
  log "❌ Docker still present. Manual cleanup needed."
  exit 1
fi

log "🎉 Docker successfully uninstalled."
exit 0

echo "开始卸载 Docker 及其所有组件..."

# 停止 Docker 服务
echo "停止 Docker 和 containerd 服务..."
sudo systemctl stop docker
sudo systemctl stop containerd

# 禁用服务启动项
echo "禁用服务..."
sudo systemctl disable docker
sudo systemctl disable containerd

# 杀死守护进程（如果有残留）
echo "杀死可能存在的 dockerd/containerd 进程..."
sudo killall dockerd containerd 2>/dev/null

# 卸载 Docker 相关软件包
echo "卸载 docker-ce 和相关组件..."
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin

# 清理 apt 源中 Docker 的源（如果添加过）
echo "移除 Docker APT 软件源..."
sudo add-apt-repository --remove "deb [arch=amd64] https://download.docker.com/linux/ubuntu noble stable" 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/docker.list
sudo apt-get update

# 删除文件和目录
echo "删除残余文件和配置..."
sudo rm -rf /var/lib/docker
sudo rm -rf /var/lib/containerd
sudo rm -rf /etc/docker
sudo rm -rf /run/docker
sudo rm -rf ~/.docker

# 删除可执行文件（如果还在）
echo "删除 dockerd 执行文件..."
sudo rm -f /usr/bin/docker /usr/bin/dockerd /usr/local/bin/docker

# 检查是否清理干净
echo "检查卸载结果..."
if ! command -v docker >/dev/null 2>&1; then
    echo "✅ Docker CLI 已卸载"
else
    echo "❌ Docker CLI 仍然存在，请手动检查 PATH"
fi

ps -ef | grep -i docker | grep -v grep

echo "🎉 Docker 卸载完成"
