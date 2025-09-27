#!/usr/bin/env bash
# rl-swarm launcher (v0.1.6) + autorestart + autologin + localtunnel + non-interactive defaults + CPU/GPU-aware torch
set -euo pipefail

# --- General arguments ---
ROOT=$PWD
# Determine effective home directory (handles sudo cases)
CURRENT_USER=$(whoami)
if [ "$CURRENT_USER" = "root" ] && [ -n "${SUDO_USER:-}" ]; then
  CURRENT_USER="$SUDO_USER"
  HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  HOME=${HOME:-/home/$CURRENT_USER}
fi
[ -z "$HOME" ] && HOME="$PWD"  # Fallback to PWD if HOME is unset
SWARM_DIR="$HOME/rl-swarm"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_MODAL_DATA_DIR="$ROOT/rl-swarm/modal-login/temp-data"

# --- Version ---
GENRL_TAG="0.1.6"

# --- Environment ---
export IDENTITY_PATH
export GENSYN_RESET_CONFIG
export CONNECT_TO_TESTNET=true
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120
export SWARM_CONTRACT="0xFaD7C5e93f28257429569B854151A1B8DCD404c2"
export PRG_CONTRACT="0x51D4db531ae706a6eC732458825465058fA23a35"

# Non-interactive defaults
export HUGGINGFACE_ACCESS_TOKEN="None"  # auto choose "N" for HF push
export MODEL_NAME="Gensyn/Qwen2.5-0.5B-Instruct"  # auto choose default model
export PRG_GAME=true  # Playing PRG game: true

# Path to RSA private key (auto-create by app if missing)
DEFAULT_IDENTITY_PATH="$HOME/swarm.pem"
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}
DOCKER=${DOCKER:-""}
GENSYN_RESET_CONFIG=${GENSYN_RESET_CONFIG:-""}
CPU_ONLY=${CPU_ONLY:-""}
ORG_ID=${ORG_ID:-""}

# --- Console colors ---
GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RED_TEXT="\033[31m"
RESET_TEXT="\033[0m"
echo_green() { echo -e "$GREEN_TEXT$1$RESET_TEXT"; }
echo_blue() { echo -e "$BLUE_TEXT$1$RESET_TEXT"; }
echo_red() { echo -e "$RED_TEXT$1$RESET_TEXT"; }

# --- Log function ---
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$1] $2"
}

# --- System limits ---
ulimit -n 65535 || true
echo_green ">> File descriptor limits: $(ulimit -n)"

# --- Auto-login helpers ---
SOURCE_DIR="/root/"
TEMP_DATA_DIR="$ROOT/rl-swarm/modal-login/temp-data"

# --- PIDs for cleanup ---
SERVER_PID=""
PYTHON_ACTUAL_PID=""
TEE_PID=""
TUNNEL_PID=""

cleanup() {
  echo_green ">> Shutting down trainer & cleaning up..."
  cd "$ROOT" || true
  # Kill background helpers
  pkill -f "DHT-" 2>/dev/null || true
  pkill -f "hivemind" 2>/dev/null || true
  pkill -f "lt --port" 2>/dev/null || true
  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    echo ">> Stopping modal-login server (PID: $SERVER_PID)..."
    kill -9 "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [ -n "${PYTHON_ACTUAL_PID:-}" ] && kill -0 "$PYTHON_ACTUAL_PID" 2>/dev/null; then
    echo ">> Stopping Python process (PID: $PYTHON_ACTUAL_PID)..."
    kill -9 "$PYTHON_ACTUAL_PID" 2>/dev/null || true
    wait "$PYTHON_ACTUAL_PID" 2>/dev/null || true
  fi
  if [ -n "${TEE_PID:-}" ] && kill -0 "$TEE_PID" 2>/dev/null; then
    echo ">> Stopping tee (PID: $TEE_PID)..."
    kill -9 "$TEE_PID" 2>/dev/null || true
    wait "$TEE_PID" 2>/dev/null || true
  fi
  if [ -n "${TUNNEL_PID:-}" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo ">> Stopping localtunnel (PID: $TUNNEL_PID)..."
    kill -9 "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
  fi
  echo_green ">> Cleanup complete."
}

errnotify() {
  echo_red ">> A critical error was detected while running rl-swarm. See $ROOT/rl-swarm/logs for logs."
}

install_unzip() {
  if ! command -v unzip &> /dev/null; then
    log "INFO" "⚠️ 'unzip' not found, installing..."
    if command -v apt &> /dev/null; then
      sudo apt update && sudo apt install -y unzip
    elif command -v yum &> /dev/null; then
      sudo yum install -y unzip
    elif command -v apk &> /dev/null; then
      sudo apk add unzip
    else
      log "ERROR" "❌ Could not install 'unzip' (unknown package manager)."
      exit 1
    fi
  fi
}

unzip_files() {
  local TEMP_DIR="/tmp/rl-swarm-unzip-$(date +%s)"
  local FOUND_ZIP=""
  local EFFECTIVE_HOME
  local SEARCH_DIRS
  local EXPECTED_FILES=("swarm.pem" "userData.json" "userApiKey.json")
  local MODAL_DATA_DIR="$PWD/rl-swarm/modal-login/temp-data"
  local KEY_DEST_DIR

  log "INFO" "🔍 Starting advanced ZIP file search at $(date '+%Y-%m-%d %H:%M:%S')..."

  # Debug: Log $HOME and $PWD
  log "INFO" "🔎 Current environment: PWD=$PWD, HOME=$HOME"

  # Determine effective home directory
  CURRENT_USER=$(whoami)
  if [ "$CURRENT_USER" = "root" ] && [ -n "${SUDO_USER:-}" ]; then
    CURRENT_USER="$SUDO_USER"
    EFFECTIVE_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    log "INFO" "🔎 Running as sudo, using effective user: $CURRENT_USER, home: $EFFECTIVE_HOME"
  else
    EFFECTIVE_HOME="$HOME"
    log "INFO" "🔎 Running as user: $CURRENT_USER, home: $EFFECTIVE_HOME"
  fi
  [ -z "$EFFECTIVE_HOME" ] && EFFECTIVE_HOME="$PWD"

  # Set KEY_DEST_DIR to effective home
  KEY_DEST_DIR="$EFFECTIVE_HOME"

  # Define search directories
  SEARCH_DIRS=(
    "$EFFECTIVE_HOME"
    "$PWD"
    "$EFFECTIVE_HOME/rl-swarm"
    "$PWD/rl-swarm"
    "$EFFECTIVE_HOME/modal-login"
    "$PWD/modal-login"
    "/home"  # Fallback to search all /home/* directories
  )

  # Check if unzip is installed
  install_unzip

  # Check if ZIP_FILE_PATH is set and points to a valid ZIP file
  if [ -n "${ZIP_FILE_PATH:-}" ] && [ -f "$ZIP_FILE_PATH" ]; then
    if unzip -l "$ZIP_FILE_PATH" >/dev/null 2>&1; then
      FOUND_ZIP="$ZIP_FILE_PATH"
      log "INFO" "✅ Found user-specified ZIP file: $FOUND_ZIP"
    else
      log "WARN" "⚠️ Specified ZIP file ($ZIP_FILE_PATH) is invalid, continuing search..."
    fi
  fi

  # If no valid ZIP_FILE_PATH, search directories
  if [ -z "$FOUND_ZIP" ]; then
    log "INFO" "🔎 Searching for ZIP files in: ${SEARCH_DIRS[*]}"
    for dir in "${SEARCH_DIRS[@]}"; do
      if [ -d "$dir" ]; then
        FOUND_ZIP=$(find "$dir" -maxdepth 1 -type f -name "*.zip" | head -n 1)
        if [ -n "$FOUND_ZIP" ] && unzip -l "$FOUND_ZIP" >/dev/null 2>&1; then
          log "INFO" "✅ Found ZIP file: $FOUND_ZIP"
          break
        fi
      fi
    done
  fi

  # If no ZIP file found, log warning and exit
  if [ -z "$FOUND_ZIP" ]; then
    log "WARN" "⚠️ No valid ZIP file found in searched directories, proceeding without unzipping."
    return 0
  fi

  # Validate ZIP contents for expected files
  log "INFO" "🔍 Checking contents of $FOUND_ZIP..."
  local ZIP_CONTENTS
  ZIP_CONTENTS=$(unzip -l "$FOUND_ZIP" | awk '{print $4}' | grep -E "$(IFS='|'; echo "${EXPECTED_FILES[*]}")" || true)
  if [ -z "$ZIP_CONTENTS" ]; then
    log "WARN" "⚠️ ZIP file ($FOUND_ZIP) does not contain expected files (${EXPECTED_FILES[*]}), proceeding without unzipping."
    return 0
  fi

  # Create temporary directory for extraction
  mkdir -p "$TEMP_DIR" || {
    log "ERROR" "❌ Failed to create temporary directory $TEMP_DIR."
    return 1
  }

  # Extract ZIP file
  log "INFO" "📂 Extracting $FOUND_ZIP to $TEMP_DIR..."
  if ! unzip -o "$FOUND_ZIP" -d "$TEMP_DIR" >/dev/null 2>&1; then
    log "ERROR" "❌ Failed to extract $FOUND_ZIP."
    rm -rf "$TEMP_DIR"
    return 1
  fi

  # Move expected files to their destinations
  for file in "${EXPECTED_FILES[@]}"; do
    if [ -f "$TEMP_DIR/$file" ]; then
      case "$file" in
        "swarm.pem")
          mv "$TEMP_DIR/$file" "$KEY_DEST_DIR/$file" || {
            log "ERROR" "❌ Failed to move $file to $KEY_DEST_DIR."
            rm -rf "$TEMP_DIR"
            return 1
          }
          chmod 600 "$KEY_DEST_DIR/$file" || {
            log "ERROR" "❌ Failed to set permissions for $KEY_DEST_DIR/$file."
            rm -rf "$TEMP_DIR"
            return 1
          }
          log "INFO" "✅ Moved $file to $KEY_DEST_DIR"
          ;;
        "userData.json" | "userApiKey.json")
          mkdir -p "$MODAL_DATA_DIR" || {
            log "ERROR" "❌ Failed to create $MODAL_DATA_DIR."
            rm -rf "$TEMP_DIR"
            return 1
          }
          mv "$TEMP_DIR/$file" "$MODAL_DATA_DIR/" || {
            log "ERROR" "❌ Failed to move $file to $MODAL_DATA_DIR."
            rm -rf "$TEMP_DIR"
            return 1
          }
          log "INFO" "✅ Moved $file to $MODAL_DATA_DIR"
          ;;
      esac
    fi
  done

  # Clean up temporary directory
  rm -rf "$TEMP_DIR"
  log "INFO" "✅ Successfully processed ZIP file: $FOUND_ZIP"

  # Set flag for extracted swarm.pem if needed
  [ -f "$KEY_DEST_DIR/swarm.pem" ] && JUST_EXTRACTED_PEM=true

  return 0
}

trap cleanup EXIT
trap errnotify ERR

# --- Banner ---
echo -e "\033[38;5;224m"
cat << "EOF"
    ██████  ██            ███████ ██     ██  █████  ██████  ███    ███
    ██   ██ ██            ██      ██     ██ ██   ██ ██   ██ ████  ████
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██
    ██   ██ ██                 ██ ██ ███ ██ ██   ██ ██   ██ ██  ██  ██
    ██   ██ ███████       ███████  ███ ███  ██   ██ ██   ██ ██      ██
    From Gensyn
EOF
echo -en "$RESET_TEXT"

# --- Docker permissions (if any) ---
if [ -n "$DOCKER" ]; then
  volumes=(
    /home/gensyn/rl_swarm/modal-login/temp-data
    /home/gensyn/rl_swarm/keys
    /home/gensyn/rl_swarm/configs
    /home/gensyn/rl_swarm/logs
  )
  for volume in "${volumes[@]}"; do
    sudo chown -R 1001:1001 "$volume" || true
  done
fi

# --- Logs dir ---
mkdir -p "$ROOT/rl-swarm/logs"

# --- Localtunnel helpers ---
install_localtunnel() {
  if command -v lt >/dev/null 2>&1; then
    echo_green ">> localtunnel already installed."
    return 0
  fi
  echo_green ">> Installing localtunnel..."
  npm install -g localtunnel >/dev/null 2>&1 || { echo_red ">> Failed to install localtunnel"; return 1; }
  echo_green ">> localtunnel installed."
  return 0
}

start_localtunnel() {
  local PORT=3000
  echo_green ">> Starting localtunnel on port $PORT..."
  lt --port "$PORT" > localtunnel_output.log 2>&1 &
  TUNNEL_PID=$!
  sleep 5
  local URL
  URL=$(grep -o "https://[^ ]*" localtunnel_output.log | head -n1 || true)
  if [ -n "${URL:-}" ]; then
    local PASS
    PASS=$(curl -s https://loca.lt/mytunnelpassword || true)
    echo_green ">> Public URL: ${URL}"
    [ -n "$PASS" ] && echo_green ">> Access password: ${PASS}"
    return 0
  else
    echo_red ">> Failed to get localtunnel URL."
    kill "$TUNNEL_PID" 2>/dev/null || true
    return 1
  fi
}

# --- CONNECT_TO_TESTNET flow (with autologin & localtunnel) ---
if [ "$CONNECT_TO_TESTNET" = true ]; then
  echo "Please login to create an Ethereum Server Wallet"
  cd "$ROOT/rl-swarm/modal-login"
  unzip_files
  # Node.js + NVM
  if ! command -v node >/dev/null 2>&1; then
    echo "Node.js not found. Installing NVM and latest Node.js..."
    export NVM_DIR="$HOME/.nvm"
    if [ ! -d "$NVM_DIR" ]; then
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    fi
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
    nvm install node
  else
    echo "Node.js is already installed: $(node -v)"
  fi
  # Yarn
  if ! command -v yarn >/dev/null 2>&1; then
    if grep -qi "ubuntu" /etc/os-release 2>/dev/null || uname -r | grep -qi "microsoft"; then
      echo "Detected Ubuntu/WSL. Installing Yarn via apt..."
      curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
      echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
      sudo apt update && sudo apt install -y yarn
    else
      echo "Installing Yarn globally via npm..."
      npm install -g --silent yarn
    fi
  fi
  # Patch .env
  ENV_FILE="$ROOT/rl-swarm/modal-login/.env"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "3s/.*/SWARM_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    sed -i '' "4s/.*/PRG_CONTRACT_ADDRESS=$PRG_CONTRACT/" "$ENV_FILE"
  else
    sed -i "3s/.*/SWARM_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    sed -i "4s/.*/PRG_CONTRACT_ADDRESS=$PRG_CONTRACT/" "$ENV_FILE"
  fi
  # Build & start modal server
  if [ -z "$DOCKER" ]; then
    yarn install --immutable
    echo "Building server"
    yarn build > "$ROOT/rl-swarm/logs/yarn.log" 2>&1
  fi
  yarn start >> "$ROOT/rl-swarm/logs/yarn.log" 2>&1 &
  SERVER_PID=$!
  echo "Started server process: $SERVER_PID"
  sleep 5
  # Auto credentials
  if [ -f "$SOURCE_DIR/userData.json" ] && [ -f "$SOURCE_DIR/userApiKey.json" ]; then
    echo_green ">> Found credentials at $SOURCE_DIR, skipping manual login..."
    mkdir -p "$DEST_MODAL_DATA_DIR"
    cp -f "$SOURCE_DIR/userData.json" "$DEST_MODAL_DATA_DIR"
    cp -f "$SOURCE_DIR/userApiKey.json" "$DEST_MODAL_DATA_DIR"
    if [ -f "$SOURCE_DIR/swarm.pem" ] && [ ! -f "$KEY_DEST_DIR/swarm.pem" ]; then
      echo ">> Copying swarm.pem to project root..."
      cp -f "$SOURCE_DIR/swarm.pem" "$KEY_DEST_DIR" || true
    fi
  elif [ -f "$ROOT/rl-swarm/modal-login/temp-data/userData.json" ] && [ -f "$ROOT/rl-swarm/modal-login/temp-data/userApiKey.json" ]; then
    echo_green ">> Credentials already exist under modal-login/temp-data/, skipping login..."
  else
    echo_green ">> Credentials not found; starting localtunnel/public login flow..."
    if [ -z "$DOCKER" ]; then
      install_localtunnel && start_localtunnel || {
        # Fallback to local browser open
        if command -v xdg-open >/dev/null 2>&1; then
          xdg-open http://localhost:3000 >/dev/null 2>&1 || true
        elif command -v open >/dev/null 2>&1; then
          open http://localhost:3000 2>/dev/null || true
        else
          echo ">> Please open http://localhost:3000 manually."
        fi
      }
    else
      echo_green ">> In Docker: open http://localhost:3000 from host browser."
    fi
    echo_green ">> Waiting for login to finish & credentials to appear..."
    while true; do
      if [ -f "$ROOT/rl-swarm/modal-login/temp-data/userData.json" ] && [ -f "$ROOT/rl-swarm/modal-login/temp-data/userApiKey.json" ]; then
        echo_green ">> Credentials generated."
        break
      fi
      echo ">> Still waiting for credentials..."
      sleep 10
    done
  fi
  cd "$ROOT"
  # Extract ORG_ID
  if [ -f "$ROOT/rl-swarm/modal-login/temp-data/userData.json" ]; then
    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' "$ROOT/rl-swarm/modal-login/temp-data/userData.json")
    echo "Your ORG_ID is set to: $ORG_ID"
  else
    echo_red "ERROR: userData.json not found to extract ORG_ID. Make sure you are logged in."
    exit 1
  fi
  # Wait for API key activation
  echo "Waiting for API key to become activated..."
  while true; do
    STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID" || true)
    if [[ "$STATUS" == "activated" ]]; then
      echo "API key is activated! Proceeding..."
      break
    else
      echo "Waiting for API key to be activated..."
      sleep 5
    fi
  done
fi

# --- Python deps (CPU/GPU-aware) ---
echo_green ">> Getting Python requirements..."
python3 -m pip install --upgrade pip
echo_green ">> Removing potentially conflicting torch/transformers..."
python3 -m pip uninstall -y torch transformers || true
echo_green ">> Installing PyTorch (auto-detect CPU/GPU)..."
TORCH_CHANNEL_CPU="https://download.pytorch.org/whl/cpu"
TORCH_CUDA_CHANNEL="${TORCH_CUDA_CHANNEL:-cu121}"
if [ -n "${CPU_ONLY:-}" ]; then
  python3 -m pip install --index-url "$TORCH_CHANNEL_CPU" torch
else
  if command -v nvidia-smi >/dev/null 2>&1; then
    python3 -m pip install --index-url "https://download.pytorch.org/whl/${TORCH_CUDA_CHANNEL}" torch || {
      echo_red ">> CUDA wheel failed; falling back to CPU wheel."
      python3 -m pip install --index-url "$TORCH_CHANNEL_CPU" torch
    }
  else
    python3 -m pip install --index-url "$TORCH_CHANNEL_CPU" torch
  fi
fi
echo_green ">> Installing GenRL ${GENRL_TAG} and friends..."
python3 -m pip install "gensyn-genrl==${GENRL_TAG}"
python3 -m pip install trl
python3 -m pip install "reasoning-gym>=0.1.20"
python3 -m pip install "hivemind@git+https://github.com/gensyn-ai/hivemind@639c964a8019de63135a2594663b5bec8e5356dd"

# --- Config sync ---
if [ ! -d "$ROOT/rl-swarm/configs" ]; then mkdir -p "$ROOT/rl-swarm/configs"; fi
if [ -f "$ROOT/rl-swarm/configs/rg-swarm.yaml" ]; then
  if ! cmp -s "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/rl-swarm/configs/rg-swarm.yaml"; then
    if [ -z "$GENSYN_RESET_CONFIG" ]; then
      echo_green ">> Found differences in rg-swarm.yaml. Set GENSYN_RESET_CONFIG to reset to default."
    else
      echo_green ">> Backing up and resetting rg-swarm.yaml to default."
      mv "$ROOT/rl-swarm/configs/rg-swarm.yaml" "$ROOT/rl-swarm/configs/rg-swarm.yaml.bak"
      cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/rl-swarm/configs/rg-swarm.yaml"
    fi
  fi
else
  cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/rl-swarm/configs/rg-swarm.yaml"
fi
if [ -n "$DOCKER" ]; then
  sudo chmod -R 0777 /home/gensyn/rl_swarm/configs || true
fi
echo_green ">> Done!"

# --- Non-interactive summaries ---
echo_green ">> Would you like to push models you train in the RL swarm to the Hugging Face Hub? [y/N]  --> N (auto)"
echo_green ">> Enter the name of the model you want to use in huggingface repo/name format, or press [Enter] to use the default model.  --> ${MODEL_NAME} (auto)"
echo_green ">> Playing PRG game: ${PRG_GAME}"
echo_blue ">> And remember to star the repo on GitHub! --> https://github.com/gensyn-ai/rl-swarm"

# --- Autorestart loop ---
stop_loop="false"
TEMP_LOG_FILE="$ROOT/rl-swarm/logs/temp_swarm_launcher_output.log"
FINAL_LOG_FILE="$ROOT/rl-swarm/logs/swarm_launcher.log"
PID_FILE="$ROOT/rl-swarm/logs/gensyn_runner.pid"
LAST_ACTIVITY_TIME=$(date +%s)
STUCK_TIMEOUT_SECONDS=600  # 20 minutes
ACTIVITY_KEYWORDS=(
  "Joining round:"
  "Starting round:"
  "Map: 100%"
  "INFO] - Reasoning Gym Data Manager initialized"
  "INFO] - ✅ Connected to Gensyn Testnet"
  "INFO] - Peer ID"
  "INFO] - bootnodes:"
  "INFO] - Using Model:"
  "DHT initialized"
  "P2P daemon started"
)
ERROR_KEYWORDS=(
  "ERROR"
  "Exception occurred"
  "P2PDaemonError"
  "BlockingIOError"
  "EOFError"
  "FileNotFoundError"
  "HTTPError"
  "Resource temporarily unavailable"
  "DHTError"
  "Connection reset by peer"
)
while [ "$stop_loop" = "false" ]; do
  echo ">> Launching rgym swarm on $(date +'%Y-%m-%d %H:%M:%S')..."
  : > "$TEMP_LOG_FILE"
  : > "$PID_FILE"
  (
    cd "$ROOT"
    CPU_ONLY="$CPU_ONLY" python3 -m rgym_exp.runner.swarm_launcher \
      --config-path "$ROOT/rgym_exp/config" \
      --config-name "rg-swarm.yaml" 2>&1 &
    PYTHON_ACTUAL_PID=$!
    echo "$PYTHON_ACTUAL_PID" >&3
    wait $PYTHON_ACTUAL_PID
    exit $?
  ) 3> "$PID_FILE" | tee "$TEMP_LOG_FILE" &
  TEE_PID=$!
  echo ">> Tee process PID: $TEE_PID"
  sleep 2
  PYTHON_ACTUAL_PID=""
  for _ in {1..10}; do
    if [ -s "$PID_FILE" ]; then
      PYTHON_ACTUAL_PID=$(cat "$PID_FILE")
      if [ -n "$PYTHON_ACTUAL_PID" ] && [ -e "/proc/$PYTHON_ACTUAL_PID" ]; then
        break
      fi
    fi
    sleep 1
  done
  if [ -z "$PYTHON_ACTUAL_PID" ] || [ ! -e "/proc/$PYTHON_ACTUAL_PID" ]; then
    echo_red ">> FAILED to start Gensyn RL Swarm (no valid Python PID)."
    if [ -f "$TEMP_LOG_FILE" ]; then
      ERROR_MSG=$(grep -E "$(IFS='|'; echo "${ERROR_KEYWORDS[*]}")" "$TEMP_LOG_FILE" | head -n1 || true)
      [ -n "$ERROR_MSG" ] && echo_red ">> ERROR: $ERROR_MSG"
      cat "$TEMP_LOG_FILE" >> "$FINAL_LOG_FILE"
      rm -f "$TEMP_LOG_FILE"
    fi
    if [ -n "$TEE_PID" ] && kill -0 "$TEE_PID" 2>/dev/null; then
      kill -9 "$TEE_PID" 2>/dev/null || true
      wait "$TEE_PID" 2>/dev/null || true
    fi
    echo_red ">> Restarting in 10s..."
    sleep 10
    continue
  fi
  echo ">> Monitoring Python PID: $PYTHON_ACTUAL_PID"
  LAST_ACTIVITY_TIME=$(date +%s)
  MONITOR_INTERVAL=15
  MONITOR_LOOP_STOP="false"
  while [ "$MONITOR_LOOP_STOP" = "false" ]; do
    if ! kill -0 "$PYTHON_ACTUAL_PID" 2>/dev/null; then
      echo_green ">> Python process (PID: $PYTHON_ACTUAL_PID) has exited."
      MONITOR_LOOP_STOP="true"
      break
    fi
    CURRENT_TIME=$(date +%s)
    if grep -qE "$(IFS='|'; echo "${ACTIVITY_KEYWORDS[*]}")" "$TEMP_LOG_FILE"; then
      LAST_ACTIVITY_TIME=$CURRENT_TIME
      echo ">> Activity detected. Resetting idle timer."
      : > "$TEMP_LOG_FILE"
    fi
    if (( CURRENT_TIME - LAST_ACTIVITY_TIME > STUCK_TIMEOUT_SECONDS )); then
      echo_red ">> WARNING: Process appears STUCK (no activity > ${STUCK_TIMEOUT_SECONDS}s). Forcing restart..."
      kill "$PYTHON_ACTUAL_PID" 2>/dev/null || true
      sleep 5
      if kill -0 "$PYTHON_ACTUAL_PID" 2>/dev/null; then
        echo_red ">> SIGTERM ignored. Using SIGKILL..."
        kill -9 "$PYTHON_ACTUAL_PID" 2>/dev/null || true
        sleep 5
      fi
      pkill -f "DHT-" 2>/dev/null || true
      if [ -n "$TEE_PID" ] && kill -0 "$TEE_PID" 2>/dev/null; then
        kill -9 "$TEE_PID" 2>/dev/null || true
        wait "$TEE_PID" 2>/dev/null || true
      fi
      MONITOR_LOOP_STOP="true"
      break
    fi
    sleep "$MONITOR_INTERVAL"
  done
  if [ -f "$TEMP_LOG_FILE" ]; then
    cat "$TEMP_LOG_FILE" >> "$FINAL_LOG_FILE"
    rm -f "$TEMP_LOG_FILE"
  fi
  if [ -n "$TEE_PID" ]; then
    wait "$TEE_PID" 2>/dev/null || true
  fi
  SHOULD_RESTART_AFTER_CHECK="false"
  if grep -qE "$(IFS='|'; echo "${ERROR_KEYWORDS[*]}")" "$FINAL_LOG_FILE"; then
    echo_red ">> Errors detected in logs. Restarting..."
    SHOULD_RESTART_AFTER_CHECK="true"
  elif [ "$MONITOR_LOOP_STOP" = "true" ]; then
    echo_red ">> Process exited/crashed. Restarting..."
    SHOULD_RESTART_AFTER_CHECK="true"
  else
    echo_green ">> Process finished successfully. Exiting loop."
    SHOULD_RESTART_AFTER_CHECK="false"
  fi
  if [ "$SHOULD_RESTART_AFTER_CHECK" = "true" ]; then
    echo ">> Pre-restart cleanup..."
    cleanup
    pkill -f "DHT-" 2>/dev/null || true
    pkill -f "hivemind" 2>/dev/null || true
    echo ">> Restarting in 15s..."
    sleep 15
  else
    stop_loop="true"
  fi
done
echo ">> Exit."
