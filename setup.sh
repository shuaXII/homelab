#!/bin/bash
set -e

FILE_URL="https://raw.githubusercontent.com/shuaXII/homelab/refs/heads/main/template-ubuntu.sh"

TARGET_FILE="/usr/local/bin/template-ubuntu.sh"

apt-get update -qq
apt-get install -y -qq curl

curl -fsSL "$FILE_URL" -o "$TARGET_FILE"

chmod +x "$TARGET_FILE"

"$TARGET_FILE"
