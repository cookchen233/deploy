#!/bin/bash

# Check if order_id and api_server are provided
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <order_id> <api_server>"
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
    apt-get update >/dev/null 2>&1 || { echo "Failed to update apt"; send_status "failed" 10; exit 1; }
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common >/dev/null 2>&1 || { echo "Failed to install prerequisites"; send_status "failed" 10; exit 1; }

    # Retry curl for GPG key up to 3 times with 10s timeout and 5s delay
    GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
    for attempt in {1..10}; do
        echo "Attempting to fetch GPG key ($attempt/3)..."
        if curl -fsSL --connect-timeout 10 --retry 2 --retry-delay 2 "$GPG_URL" > /tmp/docker.gpg; then
            apt-key add /tmp/docker.gpg >/dev/null 2>&1 && break
            echo "Failed to add GPG key, attempt $attempt/3"
        else
            echo "Curl failed: $(cat /tmp/docker.gpg 2>/dev/null || echo 'No output')"
        fi
        send_status "installing_docker" 15
        sleep 1
        if [ $attempt -eq 10 ]; then
            echo "Failed to fetch Docker GPG key after 3 attempts."
            kill $progress_pid 2>/dev/null
            wait $progress_pid 2>/dev/null
            send_status "failed" 30
            exit 1
        fi
    done
    rm -f /tmp/docker.gpg

    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" >/dev/null 2>&1 || { echo "Failed to add Docker repository"; send_status "failed" 30; exit 1; }
    apt-get update >/dev/null 2>&1 || { echo "Failed to update apt after adding repo"; send_status "failed" 30; exit 1; }
    apt-get install -y docker-ce >/dev/null 2>&1 || { echo "Failed to install docker-ce"; send_status "failed" 30; exit 1; }
    systemctl start docker >/dev/null 2>&1 || { echo "Failed to start Docker"; send_status "failed" 30; exit 1; }
    systemctl enable docker >/dev/null 2>&1 || { echo "Failed to enable Docker"; send_status "failed" 30; exit 1; }
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