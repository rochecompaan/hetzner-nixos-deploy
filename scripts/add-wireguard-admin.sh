#!/usr/bin/env bash

set -euo pipefail

# Constants
HOSTS_DIR="hosts"

# Function to show usage
usage() {
    echo "Usage: $0 --name NAME --endpoint ENDPOINT --public-key PUBLIC_KEY --private-ip PRIVATE_IP"
    echo
    echo "Add an administrator's WireGuard configuration to the peers file and server configs"
    echo
    echo "Options:"
    echo "  --name        Administrator name"
    echo "  --endpoint    WireGuard endpoint (e.g., domain or IP)"
    echo "  --public-key  Administrator's WireGuard public key"
    echo "  --private-ip  Administrator's WireGuard private IP (e.g., 172.16.0.x)"
    exit 1
}

# Function to update shared peers module using nix expression
update_peers_module() {
    local temp_file="modules/wireguard-peers.temp.nix"
    local final_file="modules/wireguard-peers.nix"
    mkdir -p modules

    # Use the lib function to update peers and write directly to file
    nix eval --raw --show-trace --impure \
      --expr "
        let
          lib = (import <nixpkgs> {}).lib;
          wireguard = import ./lib/wireguard.nix { inherit lib; };
        in
          wireguard.updateAdminPeer { 
            name = \"$NAME\";
            publicKey = \"$PUBLIC_KEY\";
            privateIP = \"$PRIVATE_IP\";
            endpoint = \"$ENDPOINT\";
          }
      " > "$temp_file"

    # Move the temporary file to the final location
    mv "$temp_file" "$final_file"
}

# Check if required tools are available
for cmd in nix; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required but not installed" >&2
        exit 1
    fi
done

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
        NAME="$2"
        shift 2
        ;;
        --endpoint)
        ENDPOINT="$2"
        shift 2
        ;;
        --public-key)
        PUBLIC_KEY="$2"
        shift 2
        ;;
        --private-ip)
        PRIVATE_IP="$2"
        shift 2
        ;;
        *)
        usage
        ;;
    esac
done

# Check if required arguments are provided
if [ -z "${NAME:-}" ] || [ -z "${ENDPOINT:-}" ] || [ -z "${PUBLIC_KEY:-}" ] || [ -z "${PRIVATE_IP:-}" ]; then
    usage
fi

# Validate public key format (base64, 44 characters)
if ! [[ $PUBLIC_KEY =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "Error: Invalid WireGuard public key format" >&2
    exit 1
fi

# Validate private IP format
if ! [[ $PRIVATE_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "Error: Invalid IP address format" >&2
    exit 1
fi


# Update shared peers module
echo "Updating shared peers module..." >&2
update_peers_module

echo "Admin configuration completed:" >&2
echo "  • Admin peer added to modules/wireguard-peers.nix" >&2
