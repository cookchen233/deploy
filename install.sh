#!/bin/bash
set -euo pipefail

# Check if api_server and UUID are provided
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <api_server> <uuid>"
    exit 1
fi
 
API_SERVER="$1"
UUID="$2"

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
    # Produce an integer progress value with ±5 variation, clamped between 0 and 100
    local base="$1"
    
    # Convert the base progress value (which may be a float) to an integer.
    local base_int=$(printf "%.0f" "$base")

    local variation=$((RANDOM % 11 - 5)) # -5 .. +5
    
    # Use the new integer variable for the calculation
    local value=$((base_int + variation))

    if (( value < 0 )); then value=0; fi
    if (( value > 100 )); then value=100; fi
    echo "$value"
}

# Function to send status update (run in background)
send_status() {
    local message="$1"
    local progress="$2"

    # Ensure progress is an integer and never moves backwards
    local adjusted_progress
    adjusted_progress=$(printf "%.0f" "$progress")

    # Force to 100% on explicit success
    if [[ "$message" == "success" ]]; then
        adjusted_progress=100
    fi

    # Monotonic progress across concurrent updates using file lock
    local progress_state_file="/tmp/progress_${UUID}"
    local lock_file="${progress_state_file}.lock"

    if command -v flock >/dev/null 2>&1; then
        (
            flock -x 200
            local last_progress=0
            if [[ -f "$progress_state_file" ]]; then
                last_progress=$(cat "$progress_state_file")
            fi
            if (( adjusted_progress < last_progress )); then
                adjusted_progress=$last_progress
            fi
            if (( adjusted_progress > 100 )); then
                adjusted_progress=100
            fi
            echo "$adjusted_progress" > "$progress_state_file"
        ) 200>"$lock_file"
    else
        # Fallback without flock (best-effort)
        local last_progress=0
        if [[ -f "$progress_state_file" ]]; then
            last_progress=$(cat "$progress_state_file")
        fi
        if (( adjusted_progress < last_progress )); then
            adjusted_progress=$last_progress
        fi
        if (( adjusted_progress > 100 )); then
            adjusted_progress=100
        fi
        echo "$adjusted_progress" > "$progress_state_file"
    fi

    # Reload the possibly updated value so that curl sends the locked value
    adjusted_progress=$(cat "$progress_state_file")

    local taskStatus=1
    if [[ "$message" == "success" ]]; then
        taskStatus=2
    elif [[ "$message" == "failed" ]]; then
        taskStatus=4
    fi

    curl -X POST "${API_SERVER}/api/vps/update/deployment/task" \
      -H "Content-Type: application/json" \
      -H "Cookie: bbsgo_token=b00aad0832a54ac680f5947036662361" \
      -d "{\"uuid\": \"${UUID}\", \"message\": \"${message}\", \"taskStatus\": ${taskStatus}, \"progress\": ${adjusted_progress}}" \
      >/dev/null 2>&1 &
}


# Background function to update progress during long operations
# Smoothly transition to a target progress if it is ahead of the current one
progress_transition() {
    # Smooth forward progress toward target by sending updates for every percentage point
    local status="$1"
    local target="$2"
    local duration="${3:-15}"

    local progress_state_file="/tmp/progress_${UUID}"
    local current=0
    if [[ -f "$progress_state_file" ]]; then
        current=$(cat "$progress_state_file")
    fi
    
    # Don't go backwards
    if (( target <= current )); then
        return
    fi
    
    # Always use update_progress to ensure we hit every percentage point
    update_progress "$status" "$current" "$target" "$duration"
}

update_progress() {
    local status="$1"
    local start_progress="$2"
    local end_progress="$3"
    local duration="$4"

    # Ensure numeric values
    start_progress=$(printf "%.0f" "$start_progress")
    end_progress=$(printf "%.0f" "$end_progress")
    if (( end_progress < start_progress )); then
        end_progress=$start_progress
    fi

    # For every individual percentage point
    local step_size=1
    # Calculate delay between percentage updates
    local interval=$(echo "scale=2; $duration / ($end_progress - $start_progress)" | bc -l)
    
    # Adjust interval if too small to avoid flooding
    if (( $(echo "$interval < 0.1" | bc -l) )); then
        interval="0.1"
    fi
    
    # Send progress update for EVERY number from start to end
    for ((current=$start_progress; current<=$end_progress; current++)); do
        send_status "$status" "$current"
        # Sleep proportionally
        if (( current < end_progress )); then  # Don't sleep after the last update
            sleep $interval
        fi
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
    systemctl daemon-reload
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
progress_transition "checking_docker" 15 6
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

    # Enable and start docker.socket & docker service for proper fd:// activation
    systemctl enable docker.socket >/dev/null 2>&1 || true
    systemctl start docker.socket >/dev/null 2>&1 || true
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true

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
    local timeout=${1:-60}  # seconds to wait in total
    local waited=0

    # Fast path: already healthy
    if systemctl is-active --quiet docker && docker info >/dev/null 2>&1; then
        return 0
    fi

    echo "Docker daemon not running, attempting restart..."
    systemctl daemon-reexec || true
    systemctl enable docker.socket >/dev/null 2>&1 || true
    systemctl restart docker.socket >/dev/null 2>&1 || true
    systemctl restart docker || true

    # Helper to apply override once
    apply_fd_override() {
        echo "Applying systemd override to remove fd:// listener."
        mkdir -p /etc/systemd/system/docker.service.d
        cat > /etc/systemd/system/docker.service.d/override.conf <<'OVR'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --containerd=/run/containerd/containerd.sock
OVR
        systemctl daemon-reload || true
        systemctl disable docker.socket >/dev/null 2>&1 || true
        systemctl stop docker.socket >/dev/null 2>&1 || true
        systemctl restart docker || true
    }

    local override_applied=0
    # Poll until healthy or timeout
    while (( waited < timeout )); do
        if systemctl is-active --quiet docker && docker info >/dev/null 2>&1; then
            echo "Docker daemon became healthy after ${waited}s."
            return 0
        fi
        # Detect fd:// error early
        if [[ $override_applied -eq 0 ]] && journalctl -u docker.service -n 20 2>/dev/null | grep -q "no sockets found via socket activation"; then
            apply_fd_override
            override_applied=1
            # give some time after override
            sleep 4
            continue
        fi
        sleep 2
        (( waited+=2 ))
    done

    echo "Docker daemon is still unhealthy after ${timeout}s. Attempting final fd:// fallback..."
    # Detect common fd:// socket-activation failure and create override without fd://
    if journalctl -u docker.service -n 100 2>/dev/null | grep -q "no sockets found via socket activation"; then
        echo "Applying systemd override to remove fd:// listener."
        mkdir -p /etc/systemd/system/docker.service.d
        cat > /etc/systemd/system/docker.service.d/override.conf <<'OVR'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --containerd=/run/containerd/containerd.sock
OVR
        systemctl daemon-reload || true
        systemctl disable docker.socket >/dev/null 2>&1 || true
        systemctl stop docker.socket >/dev/null 2>&1 || true
        systemctl restart docker || true
        # Re-check after override
        for i in {1..10}; do
            if systemctl is-active --quiet docker && docker info >/dev/null 2>&1; then
                echo "Docker daemon started successfully after fd:// override."
                return 0
            fi
            sleep 2
        done
    fi

    echo "Docker daemon is still unhealthy after all recovery attempts. Showing recent logs..."
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

progress_transition "checking_image" 50 12
if ! docker image inspect swr.cn-north-4.myhuaweicloud.com/ddn-k8s/ghcr.io/mhsanaei/3x-ui:v2.3.10 >/dev/null 2>&1; then
    echo "Pulling 3x-ui Docker image..."
    # Smooth progress: start from current recorded value (or 55 if already higher)
    current_pull=0
    progress_state_file="/tmp/progress_${UUID}"
    if [[ -f "$progress_state_file" ]]; then
        current_pull=$(cat "$progress_state_file")
    fi
    if (( current_pull < 55 )); then
        start_pull=$current_pull
    else
        start_pull=55
    fi
        # 创建一个获取进度的函数，采用非线性曲线，越接近目标值越慢
    calculate_next_delay() {
        local current=$1
        local target=$2
        
        # 计算距离目标的距离
        local distance=$((target - current))
        
        # 基础延迟时间（秒）
        local base_delay=0.05
        
        # 随着接近目标值，延迟增加
        # 当距离大时，基本是基础延迟
        # 当距离小时，延迟会逐渐增加
        local factor=$(echo "scale=4; 1 + (($target - $current) / 32) ^ -2" | bc -l)
        
        # 计算最终延迟，但不超过2秒
        local delay=$(echo "scale=4; $base_delay * $factor" | bc -l)
        if (( $(echo "$delay > 2" | bc -l) )); then
            delay=2
        fi
        
        echo $delay
    }

    # 启动一个后台进程来实时更新进度，同时在前台执行Docker拉取
    (
        # 获取当前进度
        current=0
        if [[ -f "$progress_state_file" ]]; then
            current=$(cat "$progress_state_file")
        fi
        
        target=89  # 目标进度
        
        # 如果当前进度小于目标，则开始更新
        if (( current < target )); then
            # 确保从当前进度的下一个开始
            current=$((current + 1))
            
            # 创建一个临时文件用于控制进度更新
            progress_control_file="/tmp/progress_control_${UUID}"
            echo "running" > "$progress_control_file"
            
            # 循环更新进度直到达到目标或拉取完成
            while [[ "$(cat "$progress_control_file")" == "running" ]] && (( current < target )); do
                send_status "pulling_image" "$current"
                
                # 计算下一个延迟时间
                delay=$(calculate_next_delay "$current" "$target")
                
                # 休眠相应时间
                sleep $delay
                
                # 更新进度
                current=$((current + 1))
            done
        fi
    ) &
    progress_updater_pid=$!
    
    # 在前台执行Docker拉取
    echo "Pulling Docker image (this may take a while)..."
    if ! docker pull swr.cn-north-4.myhuaweicloud.com/ddn-k8s/ghcr.io/mhsanaei/3x-ui:v2.3.10; then
        # Docker拉取失败，停止进度更新
        echo "failed" > "/tmp/progress_control_${UUID}"
        kill $progress_updater_pid 2>/dev/null
        echo "Failed to pull 3x-ui image."
        send_status "failed" 70
        exit 1
    fi
    
    # Docker拉取成功，通知进度更新终止
    echo "completed" > "/tmp/progress_control_${UUID}"
    
    # 等待后台进程处理完毕
    kill $progress_updater_pid 2>/dev/null; wait $progress_updater_pid 2>/dev/null || true
    
    echo "Docker image pull completed. Finishing progress updates..."
    
    # 获取当前进度
    current_progress=0
    if [[ -f "$progress_state_file" ]]; then
        current_progress=$(cat "$progress_state_file")
    fi
    
    # 如果进度尚未达到89，快速补足剩余进度
    if (( current_progress < 89 )); then
        # 快速完成剩余进度
        for ((i=current_progress+1; i<=89; i++)); do
            send_status "pulling_image" "$i"
            # 拉取已完成，加速进度更新
            sleep 0.05
        done
    fi
    
    # Allow progress to reach exactly 90%
    send_status "pulled_image" 90
else
    echo "3x-ui image already exists."
    # Send updates for each percentage point from current progress to 90%
    current=0
    if [[ -f "$progress_state_file" ]]; then
        current=$(cat "$progress_state_file")
    fi
    if (( current < 90 )); then
        update_progress "image_exists" "$current" 90 30
    fi
fi

# Stop and remove existing 3x-ui container if running
if docker ps -a --filter "name=3x-ui" -q | grep -q .; then
    echo "Stopping and removing existing 3x-ui container..."
    update_progress "cleaning_container" 90 95 30 &
    clean_pid=$!
    docker stop 3x-ui >/dev/null 2>&1 && docker rm 3x-ui >/dev/null 2>&1
    kill $clean_pid 2>/dev/null; wait $clean_pid 2>/dev/null || true
fi

# Run the 3x-ui Docker container
echo "Starting 3x-ui Docker container..."
update_progress "starting_container" 95 99 30 &
start_pid=$!
if docker run -d --name 3x-ui --restart unless-stopped -p 2053:2053 swr.cn-north-4.myhuaweicloud.com/ddn-k8s/ghcr.io/mhsanaei/3x-ui:v2.3.10 >/dev/null 2>&1; then
    kill $start_pid 2>/dev/null; wait $start_pid 2>/dev/null || true
    echo "3x-ui container started successfully."
    # Make sure we send 99% before sending 100%
    send_status "final_step" 99
    sleep 1
    send_status "success" 100
else
    kill $start_pid 2>/dev/null; wait $start_pid 2>/dev/null || true
    echo "Failed to start 3x-ui container."
    send_status "failed" 90
    exit 1
fi