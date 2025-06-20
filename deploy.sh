#!/bin/bash

# Check if api_server and order_id are provided
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <api_server> <order_id>"
    exit 1
fi

API_SERVER="$1"
ORDER_ID="$2"

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
    echo "Docker not found, installing Docker..."
    # Simulate Docker installation progress (10% -> 60% over ~5 min)
    update_progress "installing_docker" 10 60 300 &
    progress_pid=$!

    # 1. Fast-path: install docker.io from the default Ubuntu repositories.
    if apt-get update >/dev/null 2>&1 && apt-get install -y docker.io >/dev/null 2>&1; then
        echo "docker.io installed from Ubuntu repository."
    else
        echo "docker.io package failed, falling back to the official convenience script..."
        # 2. Fallback: use Docker's official one-liner which handles repos & GPG automatically.
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || { \
            echo "Convenience script install failed"; \
            send_status "failed" 30; \
            kill $progress_pid 2>/dev/null; wait $progress_pid 2>/dev/null; \
            exit 1; }
    fi

    # Ensure Docker service is running & enabled.
    systemctl start docker >/dev/null 2>&1 || true
    systemctl enable docker >/dev/null 2>&1 || true

    kill $progress_pid 2>/dev/null
    wait $progress_pid 2>/dev/null
    # Ensure progress jumps to 60% if installation completed sooner than expected
    send_status "installing_docker" 60
    if ! command -v docker >/dev/null 2>&1; then
        echo "Failed to install Docker."
        send_status "failed" 30
        exit 1
    fi
    echo "Docker installed successfully."
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