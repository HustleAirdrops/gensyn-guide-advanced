#!/usr/bin/env bash
set -euo pipefail

# General arguments
ROOT=$PWD
GENRL_TAG="0.1.8"
export IDENTITY_PATH
export GENSYN_RESET_CONFIG
export CONNECT_TO_TESTNET=true
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120 # 2 minutes
export SWARM_CONTRACT="0xFaD7C5e93f28257429569B854151A1B8DCD404c2"
export PRG_CONTRACT="0x51D4db531ae706a6eC732458825465058fA23a35"
export HUGGINGFACE_ACCESS_TOKEN="None"
export PRG_GAME=true
DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}
DOCKER=${DOCKER:-""}
GENSYN_RESET_CONFIG=${GENSYN_RESET_CONFIG:-""}

# Bit of a workaround for the non-root docker container.
if [ -n "$DOCKER" ]; then
    volumes=(
        /home/gensyn/rl_swarm/modal-login/temp-data
        /home/gensyn/rl_swarm/keys
        /home/gensyn/rl_swarm/configs
        /home/gensyn/rl_swarm/logs
    )
    for volume in ${volumes[@]}; do
        sudo chown -R 1001:1001 $volume
    done
fi

CPU_ONLY=${CPU_ONLY:-""}
ORG_ID=${ORG_ID:-""}
GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RED_TEXT="\033[31m"
RESET_TEXT="\033[0m"

echo_green() { echo -e "$GREEN_TEXT$1$RESET_TEXT"; }
echo_blue() { echo -e "$BLUE_TEXT$1$RESET_TEXT"; }
echo_red() { echo -e "$RED_TEXT$1$RESET_TEXT"; }

ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

# Localtunnel functions
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
    lt --port "$PORT" > "$ROOT/logs/localtunnel_output.log" 2>&1 &
    TUNNEL_PID=$!
    sleep 5
    local URL
    URL=$(grep -o "https://[^ ]*" "$ROOT/logs/localtunnel_output.log" | head -n1 || true)
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

# Cleanup function
cleanup() {
    echo_green ">> Shutting down trainer..."
    rm -rf "$ROOT_DIR/modal-login/temp-data/*.json" 2>/dev/null || true
    kill -- -$$ 2>/dev/null || true
    pkill -f "lt --port" 2>/dev/null || true
    pkill -f "DHT-" 2>/dev/null || true
    pkill -f "hivemind" 2>/dev/null || true
    exit 0
}

errnotify() {
    echo_red ">> An error was detected while running rl-swarm. See $ROOT/logs for full logs."
}

trap cleanup EXIT
trap errnotify ERR

echo -e "\033[38;5;224m"
cat << "EOF"
    ██████ ██ ███████ ██ ██ █████ ██████ ███ ███
    ██ ██ ██ ██ ██ ██ ██ ██ ██ ██ ████ ████
    ██████ ██ █████ ███████ ██ █ ██ ███████ ██████ ██ ████ ██
    ██ ██ ██ ██ ██ ███ ██ ██ ██ ██ ██ ██ ██ ██
    ██ ██ ███████ ███████ ███ ███ ██ ██ ██ ██ ██ ██
    From Gensyn
EOF

mkdir -p "$ROOT/logs"

if [ "$CONNECT_TO_TESTNET" = true ]; then
    echo "Please login to create an Ethereum Server Wallet"
    cd modal-login

    # Node.js + NVM setup
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

    if ! command -v yarn >/dev/null 2>&1; then
        if grep -qi "ubuntu" /etc/os-release 2>/dev/null || uname -r | grep -qi "microsoft"; then
            echo "Detected Ubuntu or WSL Ubuntu. Installing Yarn via apt..."
            curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
            echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
            sudo apt update && sudo apt install -y yarn
        else
            echo "Yarn not found. Installing Yarn globally with npm..."
            npm install -g --silent yarn
        fi
    fi

    # Install localtunnel
    install_localtunnel || { echo_red ">> localtunnel installation failed. Falling back to localhost."; }

    ENV_FILE="$ROOT/modal-login/.env"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "3s/.*/SWARM_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
        sed -i '' "4s/.*/PRG_CONTRACT_ADDRESS=$PRG_CONTRACT/" "$ENV_FILE"
    else
        sed -i "3s/.*/SWARM_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
        sed -i "4s/.*/PRG_CONTRACT_ADDRESS=$PRG_CONTRACT/" "$ENV_FILE"
    fi

    if [ -z "$DOCKER" ]; then
        yarn install --immutable
        echo "Building server"
        yarn build > "$ROOT/logs/yarn.log" 2>&1
    fi

    yarn start >> "$ROOT/logs/yarn.log" 2>&1 &
    SERVER_PID=$!
    echo "Started server process: $SERVER_PID"
    sleep 5

    # Start localtunnel or fall back to localhost
    if ! start_localtunnel; then
        echo_green ">> Falling back to localhost. Please open http://localhost:3000 manually."
        if [ -z "$DOCKER" ] && ! open http://localhost:3000 2>/dev/null; then
            echo ">> Failed to open http://localhost:3000. Please open it manually."
        fi
    fi

    cd ..
    echo_green ">> Waiting for modal userData.json to be created..."
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        sleep 5
    done

    echo "Found userData.json. Proceeding..."
    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo "Your ORG_ID is set to: $ORG_ID"

    echo "Waiting for API key to become activated..."
    while true; do
        STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID")
        if [[ "$STATUS" == "activated" ]]; then
            echo "API key is activated! Proceeding..."
            break
        else
            echo "Waiting for API key to be activated..."
            sleep 5
        fi
    done
fi

echo_green ">> Getting requirements..."
pip install --upgrade pip
echo_green ">> Installing GenRL..."
pip install gensyn-genrl==${GENRL_TAG}
pip install reasoning-gym>=0.1.20
pip install hivemind@git+https://github.com/gensyn-ai/hivemind@639c964a8019de63135a2594663b5bec8e5356dd

if [ ! -d "$ROOT/configs" ]; then
    mkdir "$ROOT/configs"
fi

if [ -f "$ROOT/configs/rg-swarm.yaml" ]; then
    if ! cmp -s "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"; then
        if [ -z "$GENSYN_RESET_CONFIG" ]; then
            echo_green ">> Found differences in rg-swarm.yaml. If you would like to reset to the default, set GENSYN_RESET_CONFIG to a non-empty value."
        else
            echo_green ">> Found differences in rg-swarm.yaml. Backing up existing config."
            mv "$ROOT/configs/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml.bak"
            cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"
        fi
    fi
else
    cp "$ROOT/rgym_exp/config/rg-swarm.yaml" "$ROOT/configs/rg-swarm.yaml"
fi

if [ -n "$DOCKER" ]; then
    sudo chmod -R 0777 /home/gensyn/rl_swarm/configs
fi

echo_green ">> Done!"
echo -en $GREEN_TEXT
read -p ">> Would you like to push models you train in the RL swarm to the Hugging Face Hub? [y/N] " yn
echo -en $RESET_TEXT
yn=${yn:-N}
case $yn in
    [Yy]*) read -p "Enter your Hugging Face access token: " HUGGINGFACE_ACCESS_TOKEN ;;
    [Nn]*) HUGGINGFACE_ACCESS_TOKEN="None" ;;
    *) echo ">>> No answer was given, so NO models will be pushed to Hugging Face Hub" && HUGGINGFACE_ACCESS_TOKEN="None" ;;
esac

echo -en $GREEN_TEXT
read -p ">> Enter the name of the model you want to use in huggingface repo/name format, or press [Enter] to use the default model. " MODEL_NAME
echo -en $RESET_TEXT
if [ -n "$MODEL_NAME" ]; then
    export MODEL_NAME
    echo_green ">> Using model: $MODEL_NAME"
else
    echo_green ">> Using default model from config"
fi

echo -en $GREEN_TEXT
read -p ">> Would you like your model to participate in the AI Prediction Market? [Y/n] " yn
if [ "$yn" = "n" ] || [ "$yn" = "N" ]; then
    PRG_GAME=false
    echo_green ">> Playing PRG game: false"
else
    echo_green ">> Playing PRG game: true"
fi
echo -en $RESET_TEXT

echo_green ">> Good luck in the swarm!"
echo_blue ">> And remember to star the repo on GitHub! --> https://github.com/gensyn-ai/rl-swarm"

# Auto-restart loop for swarm_launcher
stop_loop="false"
TEMP_LOG_FILE="$ROOT/logs/temp_swarm_launcher_output.log"
FINAL_LOG_FILE="$ROOT/logs/swarm_launcher.log"
PID_FILE="$ROOT/logs/gensyn_runner.pid"
LAST_ACTIVITY_TIME=$(date +%s)
STUCK_TIMEOUT_SECONDS=600  # 10 minutes
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
        pkill -f "DHT-" 2>/dev/null || true
        pkill -f "hivemind" 2>/dev/null || true
        echo ">> Restarting in 15s..."
        sleep 15
    else
        stop_loop="true"
    fi
done

echo ">> Exit."
