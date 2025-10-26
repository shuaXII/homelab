#!/bin/bash
set -e

# URL of the raw script file in your GitHub repo
FILE_URL="https://raw.githubusercontent.com/shuaXII/homelab/refs/heads/main/template-ubuntu.sh"

# Target path on your system
TARGET_FILE="/usr/local/bin/template-ubuntu.sh"

# Ensure dependencies
apt-get update -qq
apt-get install -y -qq curl

# Download the file
echo "Downloading template setup script..."
curl -fsSL "$FILE_URL" -o "$TARGET_FILE"

# Make it executable
chmod +x "$TARGET_FILE"

# Run the script
"$TARGET_FILE"

# Optional: disable service after first run
systemctl disable template-setup.service
