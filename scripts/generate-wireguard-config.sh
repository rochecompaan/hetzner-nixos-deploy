#!/usr/bin/env bash
set -euo pipefail

# Show usage if insufficient arguments provided
if [ $# -lt 2 ]; then
    echo "Usage: $0 --private-key KEY --address IP" >&2
    echo "Example: $0 --private-key abc123... --address 172.16.0.201" >&2
    exit 1
fi

# Constants
OUTPUT_DIR="wireguard"
MTU=1200
PORT=51820

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --private-key)
        PRIVATE_KEY="$2"
        shift 2
        ;;
        --address)
        ADDRESS="$2"
        shift 2
        ;;
        *)
        echo "Unknown argument: $1" >&2
        exit 1
        ;;
    esac
done

# Check if required arguments are provided
if [ -z "${PRIVATE_KEY:-}" ] || [ -z "${ADDRESS:-}" ]; then
    echo "Error: --private-key and --address are required" >&2
    exit 1
fi

# Validate private key format (base64, 44 characters)
if ! [[ $PRIVATE_KEY =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "Error: Invalid WireGuard private key format" >&2
    exit 1
fi

# Validate IP address format
if ! [[ $ADDRESS =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "Error: Invalid IP address format" >&2
    exit 1
fi

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Generate WireGuard config using the wireguard.nix module
nix eval --raw --impure --expr "
  let
    lib = (import <nixpkgs> {}).lib;
    wireguard = import ./lib/wireguard.nix { inherit lib; };
    peers = (import ./modules/wireguard-peers.nix).peers;
  in
    wireguard.generateConfig {
      privateKey = \"$PRIVATE_KEY\";
      address = \"$ADDRESS\";
      peers = peers;
    }
" > "${OUTPUT_DIR}/wg0.conf"

echo "WireGuard configuration written to ${OUTPUT_DIR}/wg0.conf" >&2
