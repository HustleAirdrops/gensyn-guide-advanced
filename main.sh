#!/bin/bash

# Check if running as root AAAAAAAAAAA
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Define log function
log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

# Color setup
if [ -t 1 ] && [ -n "$(tput colors)" ] && [ "$(tput colors)" -ge 8 ]; then
    BOLD=$(tput bold)
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    CYAN=$(tput setaf 6)
    NC=$(tput sgr0)
else
    BOLD=""
    RED=""
    GREEN=""
    YELLOW=""
    CYAN=""
    NC=""
fi

# Variables
SLICE_FILE="/etc/systemd/system/rl-swarm.slice"
SERVICE_FILE="/etc/systemd/system/rl-swarm.service"
RAM_REDUCTION_GB=2
REPO_URL="https://github.com/gensyn-ai/rl-swarm.git"
RUN_SCRIPT_URL="https://raw.githubusercontent.com/HustleAirdrops/gensyn-guide-advanced/main/run_rl_swarm.sh"
HOME_DIR="$HOME"  # This is /root for root user
RL_SWARM_DIR="$HOME_DIR/rl-swarm"

log "INFO" "Home directory set to: $HOME_DIR"
log "INFO" "RL Swarm directory set to: $RL_SWARM_DIR"

# Calculate CPU and RAM limits
cpu_cores=$(nproc)
cpu_limit_percentage=$(( (cpu_cores - 1) * 100 ))
[ "$cpu_limit_percentage" -lt 100 ] && cpu_limit_percentage=100
log "INFO" "CPU cores: $cpu_cores, CPU limit: $cpu_limit_percentage%"

total_gb=$(free -g | awk '/^Mem:/ {print $2}')
log "INFO" "Total RAM: ${total_gb}GB"
if [ "$total_gb" -le "$RAM_REDUCTION_GB" ]; then
    log "ERROR" "Insufficient RAM. At least $((RAM_REDUCTION_GB + 1))GB required."
    exit 1
fi
limit_gb=$((total_gb - RAM_REDUCTION_GB))
log "INFO" "RAM limit set to: ${limit_gb}GB"

# Create systemd slice for resource limits
log "INFO" "Creating systemd slice file at $SLICE_FILE"
cat > "$SLICE_FILE" <<EOF
[Slice]
Description=Slice for RL Swarm (RAM: ${limit_gb}G, CPU: ${cpu_limit_percentage}% of ${cpu_cores} cores)
MemoryMax=${limit_gb}G
CPUQuota=${cpu_limit_percentage}%
EOF
log "INFO" "Systemd slice file created"

# Install dependencies
log "INFO" "Updating package lists and installing dependencies"
apt-get update
apt-get install -y git python3-venv
log "INFO" "Dependencies installed"

# Stop and clean up existing service
log "INFO" "Stopping and cleaning up existing rl-swarm service"
systemctl stop rl-swarm.service 2>/dev/null || log "INFO" "No running rl-swarm service to stop"
systemctl disable rl-swarm.service 2>/dev/null || log "INFO" "No rl-swarm service to disable"
rm -f "$SERVICE_FILE"
systemctl daemon-reload
crontab -l | grep -v "/root/gensyn_monitoring.sh" | crontab - 2>/dev/null || log "INFO" "No crontab entry to remove"
screen -XS gensyn quit 2>/dev/null || log "INFO" "No screen session to terminate"
log "INFO" "Cleanup completed"

# Clone rl-swarm repository
log "INFO" "Cloning repository from $REPO_URL to $RL_SWARM_DIR"
rm -rf "$RL_SWARM_DIR"
git clone "$REPO_URL" "$RL_SWARM_DIR"
if [ $? -eq 0 ]; then
    log "INFO" "Repository cloned successfully"
else
    log "ERROR" "Failed to clone repository"
    exit 1
fi
cd "$RL_SWARM_DIR"

# Download and set up modified run_rl_swarm.sh
log "INFO" "Downloading run_rl_swarm.sh from $RUN_SCRIPT_URL"
wget -O run_rl_swarm.sh "$RUN_SCRIPT_URL"
chmod +x run_rl_swarm.sh
log "INFO" "run_rl_swarm.sh downloaded and made executable"

# Install unzip if missing
install_unzip() {
    if ! command -v unzip &> /dev/null; then
        log "INFO" "⚠️ 'unzip' not found, installing..."
        if command -v apt &> /dev/null; then
            apt update && apt install -y unzip
            if [ $? -eq 0 ]; then
                log "INFO" "unzip installed successfully"
            else
                log "ERROR" "Failed to install unzip with apt"
                exit 1
            fi
        elif command -v yum &> /dev/null; then
            yum install -y unzip
            if [ $? -eq 0 ]; then
                log "INFO" "unzip installed successfully"
            else
                log "ERROR" "Failed to install unzip with yum"
                exit 1
            fi
        elif command -v apk &> /dev/null; then
            apk add unzip
            if [ $? -eq 0 ]; then
                log "INFO" "unzip installed successfully"
            else
                log "ERROR" "Failed to install unzip with apk"
                exit 1
            fi
        else
            log "ERROR" "❌ Could not install 'unzip' (unknown package manager)."
            exit 1
        fi
    else
        log "INFO" "unzip is already installed"
    fi
}

# Unzip files from HOME
unzip_files() {
    log "INFO" "Searching for ZIP file in $HOME_DIR"
    ZIP_FILE=$(find "$HOME_DIR" -maxdepth 1 -type f -name "*.zip" | head -n 1)
    
    if [ -n "$ZIP_FILE" ]; then
        log "INFO" "📂 Found ZIP file: $ZIP_FILE"
        log "INFO" "Listing contents of $ZIP_FILE"
        unzip -l "$ZIP_FILE"
        
        install_unzip
        log "INFO" "Unzipping $ZIP_FILE to $HOME_DIR"
        if unzip -o "$ZIP_FILE" -d "$HOME_DIR"; then
            log "INFO" "Successfully unzipped $ZIP_FILE"
        else
            log "ERROR" "Failed to unzip $ZIP_FILE"
            exit 1
        fi
      
        # Check and move expected files
        if [ -f "$HOME_DIR/swarm.pem" ]; then
            mv "$HOME_DIR/swarm.pem" "$RL_SWARM_DIR/swarm.pem"
            chmod 600 "$RL_SWARM_DIR/swarm.pem"
            log "INFO" "✅ Moved swarm.pem to $RL_SWARM_DIR/swarm.pem"
        else
            log "WARN" "⚠️ swarm.pem not found in $HOME_DIR"
        fi

        if [ -f "$HOME_DIR/userData.json" ]; then
            mkdir -p "$RL_SWARM_DIR/modal-login/temp-data"
            mv "$HOME_DIR/userData.json" "$RL_SWARM_DIR/modal-login/temp-data/"
            log "INFO" "✅ Moved userData.json to $RL_SWARM_DIR/modal-login/temp-data/"
        else
            log "WARN" "⚠️ userData.json not found in $HOME_DIR"
        fi

        if [ -f "$HOME_DIR/userApiKey.json" ]; then
            mkdir -p "$RL_SWARM_DIR/modal-login/temp-data"
            mv "$HOME_DIR/userApiKey.json" "$RL_SWARM_DIR/modal-login/temp-data/"
            log "INFO" "✅ Moved userApiKey.json to $RL_SWARM_DIR/modal-login/temp-data/"
        else
            log "WARN" "⚠️ userApiKey.json not found in $HOME_DIR"
        fi

        log "INFO" "Listing files in $HOME_DIR after unzip"
        ls -l "$HOME_DIR"

        if [ -f "$RL_SWARM_DIR/swarm.pem" ] || [ -f "$RL_SWARM_DIR/modal-login/temp-data/userData.json" ] || [ -f "$RL_SWARM_DIR/modal-login/temp-data/userApiKey.json" ]; then
            log "INFO" "✅ Successfully processed files from $ZIP_FILE"
        else
            log "WARN" "⚠️ No expected files (swarm.pem, userData.json, userApiKey.json) found in $ZIP_FILE"
        fi
    else
        log "WARN" "⚠️ No ZIP file found in $HOME_DIR, proceeding without unzipping"
    fi
}

# Run unzip function
unzip_files

# Copy existing credentials (if any)
log "INFO" "Copying existing credentials to $RL_SWARM_DIR"
for file in userApiKey.json userData.json swarm.pem; do
    if [ -f "$RL_SWARM_DIR/modal-login/temp-data/$file" ]; then
        cp "$RL_SWARM_DIR/modal-login/temp-data/$file" "$HOME_DIR/"
        log "INFO" "Copied $file from $RL_SWARM_DIR/modal-login/temp-data/ to $HOME_DIR/"
    fi
    if [ -f "$HOME_DIR/$file" ]; then
        cp "$HOME_DIR/$file" "$RL_SWARM_DIR/"
        log "INFO" "Copied $file from $HOME_DIR/ to $RL_SWARM_DIR/"
    fi
done

# Create Python virtual environment
log "INFO" "Creating Python virtual environment in $RL_SWARM_DIR/.venv"
python3 -m venv .venv
log "INFO" "Virtual environment created"

# Create systemd service
log "INFO" "Creating systemd service file at $SERVICE_FILE"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=RL Swarm Service
After=network.target

[Service]
Type=exec
Slice=rl-swarm.slice
WorkingDirectory=$RL_SWARM_DIR
ExecStart=/bin/bash -c 'source $RL_SWARM_DIR/.venv/bin/activate && exec $RL_SWARM_DIR/run_rl_swarm.sh'
Restart=always
RestartSec=30
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF

# Start and enable service
if [ -f "$SERVICE_FILE" ]; then
    log "INFO" "Reloading systemd daemon"
    systemctl daemon-reload
    log "INFO" "Enabling rl-swarm service"
    systemctl enable rl-swarm.service
    log "INFO" "Starting rl-swarm service"
    systemctl start rl-swarm.service
    log "INFO" "Tailing service logs"
    journalctl -u rl-swarm -f -o cat
else
    log "ERROR" "Failed to create service file at $SERVICE_FILE"
    exit 1
fi
