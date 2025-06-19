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
    update_progress "installing_docker" 10 30 60 &
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
send_status "checking_image" 50
if ! docker image inspect ghcr.io/mhsanaei/3x-ui:latest >/dev/null 2>&1; then
    echo "Pulling 3x-ui Docker image..."
    send_status "pulling_image" 70
    if ! docker pull ghcr.io/mhsanaei/3x-ui:latest; then
        echo "Failed to pull 3x-ui image."
        send_status "failed" 70
        exit 1
    fi
else
    echo "3x-ui image already exists."
fi

# Stop and remove existing 3x-ui container if running
if docker ps -a --filter "name=3x-ui" -q | grep -q .; then
    echo "Stopping and removing existing 3x-ui container..."
    send_status "cleaning_container" 80
    docker stop 3x-ui >/dev/null 2>&1 && docker rm 3x-ui >/dev/null 2>&1
fi

# Run the 3x-ui Docker container
echo "Starting 3x-ui Docker container..."
send_status "starting_container" 90
if docker run -d --name 3x-ui --restart unless-stopped -p 2053:2053 ghcr.io/mhsanaei/3x-ui:latest >/dev/null 2>&1; then
    echo "3x-ui container started successfully."
    send_status "success" 100
else
    echo "Failed to start 3x-ui container."
    send_status "failed" 90
    exit 1
fi