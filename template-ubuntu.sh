#!/bin/bash

# Exit on any error
set -e

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Try: sudo $0"
    exit 1
fi

echo "Adding Docker GPG key and repository..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "Updating and installing dependencies..."
apt-get update -y -qq
apt-get install -y -qq curl openssh-client git jq ca-certificates qemu-guest-agent docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "Dependencies installed."

echo "Installing and configuring QEMU Guest Agent..."
systemctl start qemu-guest-agent
ln -sf /usr/lib/systemd/system/qemu-guest-agent.service /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service

ARCH=$(dpkg --print-architecture)
UBUNTU_CODENAME=${UBUNTU_CODENAME:-$(. /etc/os-release && echo "$VERSION_CODENAME")}
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $UBUNTU_CODENAME stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "Updating repositories and upgrading packages..." 
apt-get upgrade -y -qq

echo "Deploying Docker and Portainer..."
docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:lts

echo "=== Ubuntu Static IP Configuration ==="
read -rp "Enter new hostname: " NEW_HOSTNAME
read -rp "Enter static IP address (e.g., 192.168.1.50/24): " NEW_IP
read -rp "Enter gateway IP address (e.g., 192.168.1.1): " GATEWAY
read -rp "Enter DNS servers (comma-separated, e.g., 1.1.1.1,8.8.8.8): " DNS

INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
[ -z "$INTERFACE" ] && { echo "Could not detect network interface"; exit 1; }
NETPLAN_FILE=$(find /etc/netplan -type f -name "*.yaml" | head -n 1)
[ -z "$NETPLAN_FILE" ] && { echo "No netplan config found"; exit 1; }

BACKUP_FILE="${NETPLAN_FILE}.bak.$(date +%F_%T)"
cp "$NETPLAN_FILE" "$BACKUP_FILE"

hostnamectl set-hostname "$NEW_HOSTNAME"
grep -q "127.0.1.1" /etc/hosts && sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts || echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts

cat > "$NETPLAN_FILE" <<EOL
network:
  version: 2
  renderer: networkd
  ethernets:
    ${INTERFACE}:
      dhcp4: no
      addresses:
        - ${NEW_IP}
      gateway4: ${GATEWAY}
      nameservers:
        addresses: [$(echo "$DNS" | sed 's/,/, /g')]
EOL

netplan apply

echo "=== SSH Key Generation & GitHub Upload ==="
KEY_TYPE="ed25519"
EMAIL="${GITHUB_EMAIL:-$(git config user.email)}"
KEY_FILE="$HOME/.ssh/id_${KEY_TYPE}_github"
TITLE="${NEW_HOSTNAME}-$(date +%Y-%m-%d)"
GITHUB_API="https://api.github.com/user/keys"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

echo "Generating SSH key ($KEY_TYPE)..."
ssh-keygen -t "$KEY_TYPE" -C "$EMAIL" -f "$KEY_FILE" -N ""

echo "Starting SSH agent and adding key..."
eval "$(ssh-agent -s)"
ssh-add "$KEY_FILE"

echo "Enter your GitHub Personal Access Token (with 'admin:public_key' scope):"
read -r -s GITHUB_TOKEN
[ -z "$GITHUB_TOKEN" ] && { echo "GitHub token required"; exit 1; }

PUB_KEY_CONTENT=$(cat "${KEY_FILE}.pub")
response=$(curl -s -o /tmp/gh_response.json -w "%{http_code}" \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"title\": \"${TITLE}\", \"key\": \"${PUB_KEY_CONTENT}\"}" \
    "$GITHUB_API")

if [ "$response" -eq 201 ]; then
    echo "SSH key uploaded to GitHub"
else
    echo "Failed to upload SSH key (HTTP $response)"
    cat /tmp/gh_response.json | jq
fi
unset GITHUB_TOKEN

sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

echo "Done! SSH key saved at: $KEY_FILE"
echo "=== Configuration Complete ==="
echo "Hostname: $NEW_HOSTNAME"
echo "Static IP: $NEW_IP"

echo "Rebooting in 10 seconds..."
for i in {10..1}; do
    echo "$i..."
    sleep 1
done
reboot
