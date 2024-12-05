#!/usr/bin/env bash

set -e
set -o pipefail


# Default values
BOOT_NIXOS=false
HETZNER_API_BASE_URL="https://robot-ws.your-server.de"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --boot-nixos)
            BOOT_NIXOS=true
            shift
            ;;
        *)
            SERVER_IP="$1"
            shift
            ;;
    esac
done

echo "Decrypting secrets..."
USERNAME=$(sops -d --extract '["hetzner_robot_username"]' ./secrets/hetzner.json)
PASSWORD=$(sops -d --extract '["hetzner_robot_password"]' ./secrets/hetzner.json)

if [ -z "$SERVER_IP" ]; then
  echo "Usage: $0 [--boot-nixos] <SERVER_IP>"
  echo "Options:"
  echo "  --boot-nixos    Boot into NixOS installer after rescue mode is activated"
  exit 1
fi

http_status_check() {
    local RESPONSE=$1
    local HTTP_STATUS
    HTTP_STATUS=$(echo "$RESPONSE" | yq -r '.error.status')
    
    if [[ $HTTP_STATUS =~ ^[4-9][0-9]{2}$ ]]; then
        echo "Response: $RESPONSE"
        case $HTTP_STATUS in
            401)
                echo "Error: Unauthorized access. Please check your credentials."
                ;;
            400)
                echo "Error: Invalid input. Please review the request parameters and try again."
                ;;
            *)
                echo "Error: HTTP status code $HTTP_STATUS encountered."
                ;;
        esac
        exit 1
    fi
}

# Extract fingerprints from sops.yaml
FINGERPRINTS=$(yq -r '.fingerprints | map("authorized_key[]="+.) | join("&")' .sops.yaml)

echo "Checking current rescue mode state for $SERVER_IP..."
RESPONSE=$(curl -s -u "$USERNAME:$PASSWORD" "$HETZNER_API_BASE_URL/boot/$SERVER_IP/rescue")
http_status_check "$RESPONSE"

RESCUE_STATE=$(echo "$RESPONSE" | yq -r '.rescue.active')
if [[ $RESCUE_STATE == "true" ]]; then
  echo "Rescue mode is already active for $SERVER_IP. Skipping activation."
  exit 0
fi

echo "Activating rescue mode for $SERVER_IP..."
RESPONSE=$(curl -s -u "$USERNAME:$PASSWORD" \
  -d "os=linux&$FINGERPRINTS" \
  "$HETZNER_API_BASE_URL/boot/$SERVER_IP/rescue")
http_status_check "$RESPONSE"

echo "Executing hardware reset for $SERVER_IP..."
RESPONSE=$(curl -s -u "$USERNAME:$PASSWORD" \
  -d "type=hw" \
  "$HETZNER_API_BASE_URL/reset/$SERVER_IP")
http_status_check "$RESPONSE"

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
