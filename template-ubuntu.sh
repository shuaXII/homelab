#!/bin/bash
# template-ubuntu.sh

# Make sure the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Try: sudo $0"
    exit 1
fi

echo "Updating repos"
sudo apt-get update -y

echo "Upgrading packages"
sudo apt-get upgrade -y

echo "Deploying Portainer via Docker"
docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:lts

echo "=== Ubuntu Static IP Configuration ==="
read -rp "Enter new hostname: " NEW_HOSTNAME
read -rp "Enter static IP address (e.g., 192.168.1.50/24): " NEW_IP
read -rp "Enter gateway IP address (e.g., 192.168.1.1): " GATEWAY
read -rp "Enter DNS servers (comma-separated, e.g., 1.1.1.1,8.8.8.8): " DNS

# Detect primary network interface (skip loopback and docker)
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$INTERFACE" ]; then
    echo "Could not detect a network interface. Please check your network setup."
    exit 1
fi

echo "Detected network interface: $INTERFACE"

# Backup current netplan configuration
NETPLAN_FILE=$(find /etc/netplan -type f -name "*.yaml" | head -n 1)
if [ -z "$NETPLAN_FILE" ]; then
    echo "No netplan configuration file found in /etc/netplan."
    exit 1
fi

BACKUP_FILE="${NETPLAN_FILE}.bak.$(date +%F_%T)"
cp "$NETPLAN_FILE" "$BACKUP_FILE"
echo "Backed up current netplan config to $BACKUP_FILE"

# Change hostname
echo "Setting new hostname: $NEW_HOSTNAME"
hostnamectl set-hostname "$NEW_HOSTNAME"

# Update /etc/hosts
if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts
else
    echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
fi

# Generate new netplan configuration
cat <<EOF > "$NETPLAN_FILE"
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: no
      addresses:
        - $NEW_IP
      gateway4: $GATEWAY
      nameservers:
        addresses: [${DNS//,/ }]
EOF

echo "Updated netplan configuration: $NETPLAN_FILE"

# Apply the new network settings
echo "Applying new network settings..."
netplan apply

if [ $? -eq 0 ]; then
    echo "Network settings applied successfully."
else
    echo "Failed to apply netplan. You may need to run 'sudo netplan apply' manually."
fi

echo "=== Configuration Complete ==="
echo "New hostname: $NEW_HOSTNAME"
echo "Static IP: $NEW_IP"

echo "Rebooting..."
reboot
reboot
