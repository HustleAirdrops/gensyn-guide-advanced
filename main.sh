#!/bin/bash

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Variables
SLICE_FILE="/etc/systemd/system/rl-swarm.slice"
SERVICE_FILE="/etc/systemd/system/rl-swarm.service"
RAM_REDUCTION_GB=2
REPO_URL="https://github.com/gensyn-ai/rl-swarm.git"
RUN_SCRIPT_URL="https://raw.githubusercontent.com/HustleAirdrops/gensyn-guide-advanced/main/run_rl_swarm.sh"
HOME_DIR="$HOME"
RL_SWARM_DIR="$HOME_DIR/rl-swarm"

# Calculate CPU and RAM limits
cpu_cores=$(nproc)
cpu_limit_percentage=$(( (cpu_cores - 1) * 100 ))
[ "$cpu_limit_percentage" -lt 100 ] && cpu_limit_percentage=100

total_gb=$(free -g | awk '/^Mem:/ {print $2}')
if [ "$total_gb" -le "$RAM_REDUCTION_GB" ]; then
    echo "Insufficient RAM. At least $((RAM_REDUCTION_GB + 1))GB required."
    exit 1
fi
limit_gb=$((total_gb - RAM_REDUCTION_GB))

# Create systemd slice for resource limits
cat > "$SLICE_FILE" <<EOF
[Slice]
Description=Slice for RL Swarm (RAM: ${limit_gb}G, CPU: ${cpu_limit_percentage}% of ${cpu_cores} cores)
MemoryMax=${limit_gb}G
CPUQuota=${cpu_limit_percentage}%
EOF

# Install dependencies
apt-get update
apt-get install -y git python3-venv

# Stop and clean up existing service
systemctl stop rl-swarm.service 2>/dev/null || true
systemctl disable rl-swarm.service 2>/dev/null || true
rm -f "$SERVICE_FILE"
systemctl daemon-reload
crontab -l | grep -v "/root/gensyn_monitoring.sh" | crontab - 2>/dev/null || true
screen -XS gensyn quit 2>/dev/null || true

# Clone rl-swarm repository
rm -rf "$RL_SWARM_DIR"
git clone "$REPO_URL" "$RL_SWARM_DIR"
cd "$RL_SWARM_DIR"

# Download and set up modified run_rl_swarm.sh
wget -O run_rl_swarm.sh "$RUN_SCRIPT_URL"
chmod +x run_rl_swarm.sh

# Copy existing credentials (if any)
for file in userApiKey.json userData.json swarm.pem; do
    [ -f "$HOME_DIR/rl-swarm/modal-login/temp-data/$file" ] && cp "$HOME_DIR/rl-swarm/modal-login/temp-data/$file" "$HOME_DIR/"
    [ -f "$HOME_DIR/$file" ] && cp "$HOME_DIR/$file" "$RL_SWARM_DIR/"
done

# Create Python virtual environment
python3 -m venv .venv

# Create systemd service
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
    systemctl daemon-reload
    systemctl enable rl-swarm.service
    systemctl start rl-swarm.service
    journalctl -u rl-swarm -f -o cat
else
    echo "Failed to create service file."
    exit 1
fi
