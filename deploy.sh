#!/bin/bash

# Check if order_id and api_server are provided
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <order_id> <api_server>"
    exit 1
fi

ORDER_ID="$1"
API_SERVER="$2"

# Function to send status update
send_status() {
    local status="$1"
    local progress="$2"
    curl -X POST "${API_SERVER}/api/vps/deploy/status" -H "Content-Type: application/json" -d "{\"orderId\": \"${ORDER_ID}\", \"status\": \"${status}\", \"progress\": ${progress}}" >/dev/null 2>&1
}

# Check if 3x-ui image exists, pull only if missing
echo "Checking for 3x-ui Docker image..."
send_status "checking_image" 20
if ! docker image inspect ghcr.io/mhsanaei/3x-ui:latest >/dev/null 2>&1; then
    echo "Pulling 3x-ui Docker image..."
    send_status "pulling_image" 50
    if ! docker pull ghcr.io/mhsanaei/3x-ui:latest; then
        echo "Failed to pull 3x-ui image."
        send_status "failed" 50
        exit 1
    fi
else
    echo "3x-ui image already exists."
fi

# Stop and remove existing 3x-ui container if running
if docker ps -a --filter "name=3x-ui" -q | grep -q .; then
    echo "Stopping and removing existing 3x-ui container..."
    send_status "cleaning_container" 70
    docker stop 3x-ui >/dev/null 2>&1 && docker rm 3x-ui >/dev/null 2>&1
fi

# Run the 3x-ui Docker container
echo "Starting 3x-ui Docker container..."
send_status "starting_container" 90
if docker run -d --name 3x-ui --restart unless-stopped -p 2053:2053 ghcr.io/mhsanaei/3x-ui:latest; then
    echo "3x-ui container started successfully."
    send_status "success" 100
else
    echo "Failed to start 3x-ui container."
    send_status "failed" 90
    exit 1
fi