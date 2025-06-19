#!/bin/bash

# Check if order_id and api_server are provided
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <order_id> <api_server>"
    exit 1
fi

ORDER_ID="$1"
API_SERVER="$2"

# Check if 3x-ui image exists, pull only if missing
echo "Checking for 3x-ui Docker image..."
if ! docker image inspect ghcr.io/mhsanaei/3x-ui:latest >/dev/null 2>&1; then
    echo "Pulling 3x-ui Docker image..."
    if ! docker pull ghcr.io/mhsanaei/3x-ui:latest; then
        echo "Failed to pull 3x-ui image."
        curl -X POST "${API_SERVER}/api/vps/deploy/status" -H "Content-Type: application/json" -d "{\"orderId\": \"${ORDER_ID}\", \"status\": \"failed\"}"
        exit 1
    fi
else
    echo "3x-ui image already exists."
fi

# Stop and remove existing 3x-ui container if running
if docker ps -a --filter "name=3x-ui" -q | grep -q .; then
    echo "Stopping and removing existing 3x-ui container..."
    docker stop 3x-ui >/dev/null 2>&1 && docker rm 3x-ui >/dev/null 2>&1
fi

# Run the 3x-ui Docker container
echo "Starting 3x-ui Docker container..."
if docker run -d --name 3x-ui --restart unless-stopped -p 2053:2053 ghcr.io/mhsanaei/3x-ui:latest; then
    echo "3x-ui container started successfully."
    curl -X POST "${API_SERVER}/api/vps/deploy/status" -H "Content-Type: application/json" -d "{\"orderId\": \"${ORDER_ID}\", \"status\": \"success\"}"
else
    echo "Failed to start 3x-ui container."
    curl -X POST "${API_SERVER}/api/vps/deploy/status" -H "Content-Type: application/json" -d "{\"orderId\": \"${ORDER_ID}\", \"status\": \"failed\"}"
    exit 1
fi