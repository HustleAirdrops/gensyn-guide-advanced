
#!/bin/bash
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

TEMP_DATA_DIR="$SWARM_DIR/modal-login/temp-data"
SWARM_DIR="$HOME/rl-swarm"

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

# Unzip files from HOME (no validation)
unzip_files() {
    ZIP_FILE=$(find "$HOME" -maxdepth 1 -type f -name "*.zip" | head -n 1)
    
    if [ -n "$ZIP_FILE" ]; then
        log "INFO" "📂 Found ZIP file: $ZIP_FILE, unzipping to $HOME ..."
        install_unzip
        unzip -o "$ZIP_FILE" -d "$HOME" >/dev/null 2>&1
      
        [ -f "$HOME/swarm.pem" ] && {
            sudo mv "$HOME/swarm.pem" "$SWARM_DIR/swarm.pem"
            sudo chmod 600 "$SWARM_DIR/swarm.pem"
            JUST_EXTRACTED_PEM=true
            log "INFO" "✅ Moved swarm.pem to $SWARM_DIR"
        }
        [ -f "$HOME/userData.json" ] && {
            sudo mv "$HOME/userData.json" "$TEMP_DATA_DIR/"
            log "INFO" "✅ Moved userData.json to $TEMP_DATA_DIR"
        }
        [ -f "$HOME/userApiKey.json" ] && {
            sudo mv "$HOME/userApiKey.json" "$TEMP_DATA_DIR/"
            log "INFO" "✅ Moved userApiKey.json to $TEMP_DATA_DIR"
        }

        ls -l "$HOME"
        if [ -f "$SWARM_DIR/swarm.pem" ] || [ -f "$TEMP_DATA_DIR/userData.json" ] || [ -f "$TEMP_DATA_DIR/userApiKey.json" ]; then
            log "INFO" "✅ Successfully extracted files from $ZIP_FILE"
        else
            log "WARN" "⚠️ No expected files (swarm.pem, userData.json, userApiKey.json) found in $ZIP_FILE"
        fi
    else
        log "WARN" "⚠️ No ZIP file found in $HOME, proceeding without unzipping"
    fi
}
