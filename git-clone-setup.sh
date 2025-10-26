#!/bin/bash
# Wrapper to clone/update script and run it

set -e

REPO_URL="https://github.com/yourusername/your-repo.git"
TARGET_DIR="/usr/local/bin/template-setup"

# Make sure git is installed
apt-get update -qq
apt-get install -y -qq git

# Clone or update repo
if [ -d "$TARGET_DIR" ]; then
    echo "Updating existing repo..."
    cd "$TARGET_DIR"
    git reset --hard
    git pull
else
    echo "Cloning repo..."
    git clone "$REPO_URL" "$TARGET_DIR"
fi

# Make script executable
chmod +x "$TARGET_DIR/template-setup.sh"

# Run the script
"$TARGET_DIR/template-setup.sh"

# Optional: disable this service after first run
systemctl disable template-setup.service
