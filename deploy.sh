#!/bin/bash

# Check if api_server and order_id are provided
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <api_server> <order_id>"
    exit 1
fi

API_SERVER="$1"
ORDER_ID="$2"

# ---------- global safety & helpers ----------
# Exit on error, undefined var or failed pipe
set -Eeuo pipefail

# Require root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "Please run this script as root (e.g., sudo $0 <api_server> <order_id>)"
    exit 1
fi

# Clear command hash cache (important after installing new binaries)
hash -r

# Helper – wait until dockerd is responsive (max 30s)
wait_for_dockerd() {
    local timeout=30
    until docker info >/dev/null 2>&1; do
        ((timeout--)) || return 1
        sleep 1
    done
    return 0
}
# ---------------------------------------------

# Install Docker using official script with retry; return 0 on success, 1 on failure
install_docker_official() {
    local retries=5
    local wait=5
    local count=0
    while true; do
        if curl -fsSL https://get.docker.com | sh; then
            return 0
        fi
        count=$((count+1))
        if [ "$count" -ge "$retries" ]; then
            return 1
        fi
        echo "[WARN] Docker install failed, retry $count/$retries after ${wait}s..."
        sleep "$wait"
    done
}


# Function to generate random progress variation (±5%)
random_progress() {
    local base="$1"
    local variation=$((RANDOM % 11 - 5)) # Random number between -5 and 5
    echo "$base + $variation" | bc
}

# Function to send status update (run in background)
send_status() {
    local status="$1"
    local progress="$2"
    local adjusted_progress=$(random_progress "$progress")
    curl -X POST "${API_SERVER}/api/vps/deploy/status" -H "Content-Type: application/json" -d "{\"orderId\": \"${ORDER_ID}\", \"status\": \"${status}\", \"progress\": ${adjusted_progress}}" >/dev/null 2>&1 &
}

# Background function to update progress during long operations
update_progress() {
    local status="$1"
    local start_progress="$2"
    local end_progress="$3"
    local duration="$4"
    local steps=10
    local interval=$(echo "$duration / $steps" | bc)
    local step_size=$(echo "($end_progress - $start_progress) / $steps" | bc -l)

    for ((i=1; i<=steps; i++)); do
        local current_progress=$(echo "$start_progress + $i * $step_size" | bc -l)
        send_status "$status" "$current_progress"
        sleep "$interval"
    done
}

# Check if Docker is installed
echo "Checking for Docker installation..."
send_status "checking_docker" 10
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not found, installing via official script..."
    # Simulate Docker installation progress (10% -> 60% over ~5 min)
    update_progress "installing_docker" 10 60 300 &
    progress_pid=$!

    if install_docker_official; then
        echo "Docker installation script completed."
    else
        echo "Official script still failing, attempting apt repository install..."
        if command -v apt-get >/dev/null 2>&1 && apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io; then
            echo "docker.io package installed as fallback."
        else
            echo "All Docker installation methods failed."
            send_status "failed" 30
            kill $progress_pid 2>/dev/null; wait $progress_pid 2>/dev/null
            exit 1
        fi
    fi

    # Enable and start docker service (non-fatal if already active)
    systemctl enable --now docker >/dev/null 2>&1 || true

    # Wait for dockerd socket to be ready (max 30s)
    if ! wait_for_dockerd; then
        echo "dockerd did not become ready in time."
        send_status "failed" 30
        kill $progress_pid 2>/dev/null; wait $progress_pid 2>/dev/null
        exit 1
    fi

    kill $progress_pid 2>/dev/null; wait $progress_pid 2>/dev/null
    send_status "installing_docker" 60
    echo "Docker installed and ready."
else
    echo "Docker is already installed."
fi

# Check if 3x-ui image exists, pull only if missing
echo "Checking for 3x-ui Docker image..."
send_status "checking_image" 70
if ! docker image inspect swr.cn-north-4.myhuaweicloud.com/ddn-k8s/ghcr.io/mhsanaei/3x-ui:v2.3.10 >/dev/null 2>&1; then
    echo "Pulling 3x-ui Docker image..."
    # Simulate image pull progress 70→80 over ~2 min while pulling
    update_progress "pulling_image" 70 80 120 &
    img_progress_pid=$!
    if ! docker pull swr.cn-north-4.myhuaweicloud.com/ddn-k8s/ghcr.io/mhsanaei/3x-ui:v2.3.10; then
        echo "Failed to pull 3x-ui image."
        kill $img_progress_pid 2>/dev/null; wait $img_progress_pid 2>/dev/null
        send_status "failed" 75
        exit 1
    fi
    kill $img_progress_pid 2>/dev/null; wait $img_progress_pid 2>/dev/null
    send_status "pulling_image" 80
else
    echo "3x-ui image already exists."
fi

# Stop and remove existing 3x-ui container if running
if docker ps -a --filter "name=3x-ui" -q | grep -q .; then
    echo "Stopping and removing existing 3x-ui container..."
    send_status "cleaning_container" 90
    docker stop 3x-ui >/dev/null 2>&1 && docker rm 3x-ui >/dev/null 2>&1
fi

# Run the 3x-ui Docker container
echo "Starting 3x-ui Docker container..."
# Simulate container start 95→99 over 30s
update_progress "starting_container" 95 99 30 &
start_progress_pid=$!
if docker run -d --name 3x-ui --restart unless-stopped -p 2053:2053 swr.cn-north-4.myhuaweicloud.com/ddn-k8s/ghcr.io/mhsanaei/3x-ui:v2.3.10 >/dev/null 2>&1; then
    kill $start_progress_pid 2>/dev/null; wait $start_progress_pid 2>/dev/null
    echo "3x-ui container started successfully."
    send_status "success" 100
else
    kill $start_progress_pid 2>/dev/null; wait $start_progress_pid 2>/dev/null
    echo "Failed to start 3x-ui container."
    send_status "failed" 95
    exit 1
fi