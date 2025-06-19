#!/bin/bash

# Pull the 3x-ui Docker image
echo "Pulling 3x-ui Docker image..."
docker pull ghcr.io/mhsanaei/3x-ui:latest

# Run the 3x-ui Docker container
echo "Starting 3x-ui Docker container..."
docker run -d --name 3x-ui --restart unless-stopped -p 2053:2053 ghcr.io/mhsanaei/3x-ui:latest

# Check if the container started successfully
if [ $? -eq 0 ]; then
    echo "3x-ui container started successfully."
    # Notify the API about successful deployment
    curl -X POST "${API_SERVER}/api/vps/deploy/status" -H "Content-Type: application/json" -d '{"orderId": "ORDER_ID_PLACEHOLDER", "status": "success"}'
else
    echo "Failed to start 3x-ui container."
    # Notify the API about failed deployment
    curl -X POST "${API_SERVER}/api/vps/deploy/status" -H "Content-Type: application/json" -d '{"orderId": "ORDER_ID_PLACEHOLDER", "status": "failed"}'
fi

# Note: When deploying this script to VPS, replace ORDER_ID_PLACEHOLDER with actual order ID
# and YOUR_API_SERVER with your actual API server address

