#!/bin/bash
set -euo pipefail

# Check if api_server and order_id are provided
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <api_server> <order_id>"
    exit 1
fi

API_SERVER="$1"
ORDER_ID="$2"

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Please rerun using sudo or as root user."
    exit 1
fi

# Ensure bc utility is installed (used for progress calculations)
if ! command -v bc >/dev/null 2>&1; then
    echo "Installing bc utility..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 && apt-get install -y bc >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y bc >/dev/null 2>&1
    fi
fi

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

# -----------------------------
# Ensure Git installation
ensure_git() {
    local p_start=${1:-3}
    local p_end=${2:-8}
    if command -v git >/dev/null 2>&1; then
        echo "git already installed."
        return 0
    fi
    update_progress "installing_git" "$p_start" "$p_end" 30 &
    local gid=$!
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 && apt-get install -y git >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        YUM_TOOL="$(command -v dnf || command -v yum)"
        $YUM_TOOL install -y git >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm git >/dev/null 2>&1
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y git >/dev/null 2>&1
    else
        echo "Unknown package manager. Attempting to install git via get-git script..."
        curl -fsSL https://get.gitcdn.xyz | bash >/dev/null 2>&1 || true
    fi
    kill $gid 2>/dev/null; wait $gid 2>/dev/null || true
    if ! command -v git >/dev/null 2>&1; then
        echo "Git installation failed."; return 1; fi
    echo "git installed successfully."; return 0
}

# -----------------------------
# Reliable Docker installation
# -----------------------------
install_docker() {
    local p_start=${1:-10}
    local p_end=${2:-40}

    # Early exit if Docker CLI exists *and* the daemon is healthy. Otherwise attempt to recover
    if command -v docker >/dev/null 2>&1; then
        echo "Docker binary exists. Verifying that the daemon is running..."
        if systemctl is-active --quiet docker && docker info >/dev/null 2>&1; then
            echo "Docker daemon already running."
            return 0
        fi

        echo "Docker daemon is not running, attempting to start it..."
        # Try to (re)enable and start the service. Do *not* fail the script yet ‑ we will re-install if this does not work.
        systemctl daemon-reexec || true
        systemctl enable docker >/dev/null 2>&1 || true
        systemctl start docker >/dev/null 2>&1 || true
        sleep 3
        if systemctl is-active --quiet docker && docker info >/dev/null 2>&1; then
            echo "Docker daemon started successfully after manual start."
            return 0
        else
            echo "Docker daemon still not running – continuing with reinstallation routine..."
        fi
    fi

    # Show progress asynchronously
    update_progress "installing_docker" "$p_start" "$p_end" 180 &
    local progress_pid=$!

    # Helper to finish progress
    finish() { kill $progress_pid 2>/dev/null; wait $progress_pid 2>/dev/null || true; }
    trap finish EXIT

    # Detect package manager and install
    if command -v apt-get >/dev/null 2>&1; then
        echo "Using apt-get path..."
        # Try quick path
        if apt-get update -y && apt-get install -y docker.io; then
            echo "docker.io installed via default repo."
            # Refresh command lookup cache
            hash -r
            if ! command -v docker >/dev/null 2>&1; then
                echo "docker binary still missing after docker.io. Attempting remedial steps..."
                # Some Ubuntu versions install only docker.io binary. Create symlink if present
                if command -v docker.io >/dev/null 2>&1; then
                    ln -sf $(command -v docker.io) /usr/local/bin/docker || true
                    hash -r
                fi
            fi
            # If still missing try snap
            if ! command -v docker >/dev/null 2>&1 && command -v snap >/dev/null 2>&1; then
                echo "Installing Docker via snap as fallback..."
                snap install docker || true
                snap connect docker:network-control || true
                snap connect docker:network-observe || true
                snap connect docker:firewall-control || true
                hash -r
            fi
            # Final fallback to convenience script
            if ! command -v docker >/dev/null 2>&1; then
                echo "Final fallback: running get.docker.com script..."
                curl -fsSL https://get.docker.com | sh
            fi
        else
            echo "Switching to official Docker repo..."
            apt-get remove -y docker docker-engine docker.io containerd runc || true
            apt-get install -y ca-certificates curl gnupg lsb-release
            install -m 0755 -d /etc/apt/keyrings
            for i in {1..3}; do
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && break || {
                    echo "GPG fetch failed ($i). Retrying in 5s..."; sleep 5; }
            done
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
            apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        fi
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        local YUM_TOOL="$(command -v dnf || command -v yum)"
        echo "Using $YUM_TOOL path..."
        $YUM_TOOL remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine || true
        $YUM_TOOL -y install yum-utils curl
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        $YUM_TOOL -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    elif command -v pacman >/dev/null 2>&1; then
        echo "Using pacman path..."
        pacman -Sy --noconfirm docker docker-compose
    elif command -v zypper >/dev/null 2>&1; then
        echo "Using zypper path..."
        zypper refresh && zypper install -y docker docker-compose
    else
        echo "Unknown package manager, falling back to convenience script..."
        curl -fsSL https://get.docker.com | sh
    fi

    # Enable and start service where possible
    systemctl enable --now docker 2>/dev/null || service docker start 2>/dev/null || true

    finish
    trap - EXIT

    # Final check
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker installation failed after all attempts."
        return 1
    fi
    echo "Docker installed successfully."
    systemctl enable docker.socket
    systemctl start docker.socket
    systemctl daemon-reexec
    systemctl restart docker
    return 0
}

# Ensure Git is installed
echo "Ensuring Git is installed..."
if ! ensure_git 3 8; then
    send_status "failed" 8
    exit 1
fi

# Ensure Docker is installed using reliable function
echo "Ensuring Docker is installed..."
if ! install_docker 10 40; then
    send_status "failed" 40
    exit 1
fi
echo "Checking for Docker installation..."
send_status "checking_docker" 10
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not found, installing..."
    update_progress "installing_docker" 10 30 120 &
    progress_pid=$!

    if command -v apt-get >/dev/null 2>&1; then
        # Debian / Ubuntu path
        echo "Attempting to install docker.io from default Ubuntu repositories..."
        if apt-get update -y >/dev/null 2>&1 && apt-get install -y docker.io >/dev/null 2>&1; then
            echo "docker.io installed from default repo."
        else
            echo "docker.io package unavailable or failed. Falling back to official Docker repository."
            apt-get remove -y docker docker-engine docker.io containerd runc >/dev/null 2>&1 || true
            apt-get install -y ca-certificates curl gnupg lsb-release >/dev/null 2>&1
            mkdir -p /etc/apt/keyrings
            # Retry downloading GPG key up to 3 times
            for i in {1..3}; do
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && break
                echo "GPG key download failed (attempt $i). Retrying in 5s..."; sleep 5
            done
            if [ ! -s /etc/apt/keyrings/docker.gpg ]; then
                echo "Failed to download GPG key after retries, falling back to convenience script."
                curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
            else
                echo \
                  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
                  $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
                apt-get update -y >/dev/null 2>&1
                apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
            fi
        fi
    elif command -v yum >/dev/null 2>&1; then
        # CentOS / RHEL path
        yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine >/dev/null 2>&1 || true
        yum install -y yum-utils >/dev/null 2>&1
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null 2>&1
        yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
    else
        # Generic fallback
        echo "Unknown package manager, using Docker convenience script."
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    fi

    # Enable and start docker service
    (systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true)

    # Verify daemon is now active
    if ! systemctl is-active --quiet docker || ! docker info >/dev/null 2>&1; then
        echo "Docker daemon failed to start after installation. Collecting logs..."
        journalctl -xeu docker.service | tail -n 50 || true
        send_status "failed" 30
        exit 1
    fi

    kill $progress_pid 2>/dev/null; wait $progress_pid 2>/dev/null || true

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
# Final safety-net: ensure the Docker daemon is alive before any image operations
ensure_docker_running() {
    local timeout=${1:-30}  # seconds to wait in total
    local waited=0

    # Fast path: already healthy
    if systemctl is-active --quiet docker && docker info >/dev/null 2>&1; then
        return 0
    fi

    echo "Docker daemon not running, attempting restart..."
    systemctl daemon-reexec || true
    systemctl restart docker || true

    # Poll until healthy or timeout
    while (( waited < timeout )); do
        if systemctl is-active --quiet docker && docker info >/dev/null 2>&1; then
            echo "Docker daemon became healthy after ${waited}s."
            return 0
        fi
        sleep 2
        (( waited+=2 ))
    done

    echo "Docker daemon is still unhealthy after ${timeout}s. Showing recent logs..."
    journalctl -xeu docker.service | tail -n 50 || true
    return 1
}

# -----------------------------
# Main logic continues
# -----------------------------

if ! ensure_docker_running; then
    send_status "failed" 45
    exit 1
fi

send_status "checking_image" 50
if ! docker image inspect swr.cn-north-4.myhuaweicloud.com/ddn-k8s/ghcr.io/mhsanaei/3x-ui:v2.3.10 >/dev/null 2>&1; then
    echo "Pulling 3x-ui Docker image..."
    send_status "pulling_image" 70
    if ! docker pull swr.cn-north-4.myhuaweicloud.com/ddn-k8s/ghcr.io/mhsanaei/3x-ui:v2.3.10; then
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
if docker run -d --name 3x-ui --restart unless-stopped -p 2053:2053 swr.cn-north-4.myhuaweicloud.com/ddn-k8s/ghcr.io/mhsanaei/3x-ui:v2.3.10 >/dev/null 2>&1; then
    echo "3x-ui container started successfully."
    send_status "success" 100
else
    echo "Failed to start 3x-ui container."
    send_status "failed" 90
    exit 1
fi