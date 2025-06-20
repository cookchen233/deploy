#!/bin/bash

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
