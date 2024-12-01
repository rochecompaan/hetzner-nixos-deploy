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
    peers = (import ./modules/wireguard-peers.nix).peers;

    # Format a peer for WireGuard config file
    formatPeerConfig = peer: ''
      [Peer]
      PublicKey = \${peer.publicKey}
      AllowedIPs = \${builtins.head peer.allowedIPs}
      Endpoint = \${peer.endpoint}
      PersistentKeepalive = 25
    '';

    # Generate WireGuard config for admin
    generateConfig = { privateKey, address, peers }: ''
      [Interface]
      Address = \${address}/24
      MTU = 1200
      PrivateKey = \${privateKey}
      ListenPort = 51820

      # Peers
      \${lib.concatMapStrings formatPeerConfig 
        (lib.filter
          (peer: peer.allowedIPs != [ \"\${address}/32\" ])
          peers)}
    '';
  in
    generateConfig {
      privateKey = \"$PRIVATE_KEY\";
      address = \"$ADDRESS\";
      peers = peers;
    }
" > "${OUTPUT_DIR}/wg0.conf"

echo "WireGuard configuration written to ${OUTPUT_DIR}/wg0.conf" >&2
