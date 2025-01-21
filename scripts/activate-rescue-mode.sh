#!/usr/bin/env bash

set -e
set -o pipefail


# Default values
BOOT_NIXOS=false
HETZNER_API_BASE_URL="https://robot-ws.your-server.de"
SERVER_IP=""
HOSTNAME=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --boot-nixos)
            BOOT_NIXOS=true
            shift
            ;;
        *)
            # Check if argument is an IP address
            if [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                SERVER_IP="$1"
            else
                HOSTNAME="$1"
                SERVER_IP=$(get_server_ip "$HOSTNAME")
            fi
            shift
            ;;
    esac
done

echo "Decrypting secrets..."
USERNAME=$(sops -d --extract '["hetzner_robot_username"]' ./secrets/hetzner.json)
PASSWORD=$(sops -d --extract '["hetzner_robot_password"]' ./secrets/hetzner.json)

if [ -z "$SERVER_IP" ]; then
  echo "Usage: $0 [--boot-nixos] <SERVER_IP|HOSTNAME>"
  echo "Options:"
  echo "  --boot-nixos    Boot into NixOS installer after rescue mode is activated"
  echo ""
  echo "Arguments:"
  echo "  SERVER_IP       IP address of the server"
  echo "  HOSTNAME        Hostname of the server (will look up IP from NixOS config)"
  exit 1
fi


# Extract fingerprints from sops.yaml
FINGERPRINTS=$(yq -r '.fingerprints | map("authorized_key[]="+.) | join("&")' .sops.yaml)

# Function to print curl command (with password masked)
print_curl_command() {
    local url="$1"
    local data="${2:-}"
    echo "Debug: Executing curl command:"
    if [ -n "$data" ]; then
        echo "curl -u '$USERNAME:********' \\"
        echo "  -d '$data' \\"
        echo "  '$url'"
    else
        echo "curl -u '$USERNAME:********' '$url'"
    fi
}

echo "Checking current rescue mode state for $SERVER_IP..."
print_curl_command "$HETZNER_API_BASE_URL/boot/$SERVER_IP/rescue"
RESPONSE=$(curl -s -u "$USERNAME:$PASSWORD" "$HETZNER_API_BASE_URL/boot/$SERVER_IP/rescue")
check_json_error "$RESPONSE"

RESCUE_STATE=$(echo "$RESPONSE" | yq -r '.rescue.active')
if [[ $RESCUE_STATE == "true" ]]; then
  echo "Rescue mode is already active for $SERVER_IP. Skipping activation."
  exit 0
fi

echo "Activating rescue mode for $SERVER_IP..."
DATA="os=linux&$FINGERPRINTS"
print_curl_command "$HETZNER_API_BASE_URL/boot/$SERVER_IP/rescue" "$DATA"
RESPONSE=$(curl -s -u "$USERNAME:$PASSWORD" \
  -d "$DATA" \
  "$HETZNER_API_BASE_URL/boot/$SERVER_IP/rescue")
check_json_error "$RESPONSE"

echo "Executing hardware reset for $SERVER_IP..."
DATA="type=hw"
print_curl_command "$HETZNER_API_BASE_URL/reset/$SERVER_IP" "$DATA"
RESPONSE=$(curl -s -u "$USERNAME:$PASSWORD" \
  -d "$DATA" \
  "$HETZNER_API_BASE_URL/reset/$SERVER_IP")
check_json_error "$RESPONSE"

echo "Removing $SERVER_IP from local known_hosts file..."
ssh-keygen -R "$SERVER_IP"

echo "Pausing for hardware reset to kick in for $SERVER_IP..."
sleep 30

if ! wait_for_ssh "$SERVER_IP" "root"; then
    echo "Failed to connect to server after reset"
    exit 1
fi

echo "$SERVER_IP is back online"

if [ "$BOOT_NIXOS" = true ]; then
    echo "Booting into NixOS installer..."
    ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" << 'EOF'
        set -e
        echo "Downloading and running the NixOS kexec installer..."
        curl -L https://github.com/nix-community/nixos-images/releases/download/nixos-unstable/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz | tar -xzf- -C /root
        /root/kexec/run
EOF
fi
