#!/bin/bash
set -e

# Ensure script runs as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Try: sudo $0"
    exit 1
fi

# === Docker Repository Setup ===
echo "=== Setting up Docker repository ==="
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

ARCH=$(dpkg --print-architecture)
CODENAME=$(lsb_release -cs)  # Ubuntu codename
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "=== Installing Dependencies ==="
apt-get update -y -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable QEMU Guest Agent
systemctl enable --now qemu-guest-agent

# Deploy Portainer
if docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
    echo "Portainer container already exists. Restarting..."
    docker rm -f portainer
fi

docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:lts

# === Static IP Configuration ===
echo "=== Static IP Configuration ==="
read -rp "Enter new hostname: " NEW_HOSTNAME
read -rp "Enter static IP (e.g., 192.168.1.50/24): " NEW_IP
read -rp "Enter gateway IP (e.g., 192.168.1.1): " GATEWAY
read -rp "Enter DNS servers (comma-separated, e.g., 1.1.1.1,8.8.8.8): " DNS

# Detect interface
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$INTERFACE" ]; then
    echo "Could not detect network interface. Exiting."
    exit 1
fi

# Backup existing netplan
NETPLAN_FILES=(/etc/netplan/*.yaml)
BACKUP_DIR="/etc/netplan/backup_$(date +%F_%H%M%S)"
mkdir -p "$BACKUP_DIR"
for f in "${NETPLAN_FILES[@]}"; do
    cp "$f" "$BACKUP_DIR/"
done
echo "Netplan configs backed up to $BACKUP_DIR"

# Determine renderer
CURRENT_RENDERER=$(grep 'renderer:' "${NETPLAN_FILES[0]}" | awk '{print $2}')
CURRENT_RENDERER=${CURRENT_RENDERER:-networkd}

# Create new static IP netplan config
NEW_NETPLAN_FILE="/etc/netplan/01-static-ip.yaml"
cat > "$NEW_NETPLAN_FILE" <<EOL
network:
  version: 2
  renderer: $CURRENT_RENDERER
  ethernets:
    $INTERFACE:
      dhcp4: no
      addresses: [$NEW_IP]
      gateway4: $GATEWAY
      nameservers:
        addresses: [$(echo "$DNS" | sed 's/,/, /g')]
EOL

echo "Applying new netplan configuration..."
netplan try || { echo "Netplan test failed. Restoring backup."; cp "$BACKUP_DIR"/*.yaml /etc/netplan/; netplan apply; exit 1; }

# Hostname change
hostnamectl set-hostname "$NEW_HOSTNAME"
if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts
else
    echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
fi

# === SSH Key Generation & GitHub Upload ===
KEY_TYPE="ed25519"
EMAIL="${GITHUB_EMAIL:-$(git config user.email)}"
KEY_FILE="$HOME/.ssh/id_${KEY_TYPE}_github"
TITLE="${NEW_HOSTNAME}-$(date +%Y-%m-%d)"
GITHUB_API="https://api.github.com/user/keys"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

echo "Generating SSH key ($KEY_TYPE)..."
ssh-keygen -t "$KEY_TYPE" -C "$EMAIL" -f "$KEY_FILE" -N ""

echo "Starting SSH agent..."
eval "$(ssh-agent -s)"
ssh-add "$KEY_FILE"

read -rp "Enter GitHub Personal Access Token (with 'admin:public_key' scope): " -s GITHUB_TOKEN
echo
if [ -n "$GITHUB_TOKEN" ]; then
    PUB_KEY_CONTENT=$(<"${KEY_FILE}.pub")
    RESPONSE=$(curl -s -o /tmp/gh_response.json -w "%{http_code}" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"${TITLE}\", \"key\": \"${PUB_KEY_CONTENT}\"}" \
        "$GITHUB_API")
    if [ "$RESPONSE" -eq 201 ]; then
        echo "SSH key successfully uploaded to GitHub."
    else
        echo "Failed to upload SSH key (HTTP $RESPONSE)."
        cat /tmp/gh_response.json | jq
    fi
    unset GITHUB_TOKEN
else
    echo "No GitHub token provided. Skipping upload."
fi

# Disable password authentication for SSH
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl reload sshd

echo "=== Configuration Complete ==="
echo "Hostname: $NEW_HOSTNAME"
echo "Static IP: $NEW_IP"
echo "SSH key saved at: $KEY_FILE"

read -rp "Reboot now? (y/N): " REBOOT
if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
    echo "Rebooting in 5 seconds..."
    sleep 5
    reboot
else
    echo "Reboot skipped. Remember to reboot later."
fi
