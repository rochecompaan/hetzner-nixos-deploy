#!/usr/bin/env bash
set -euo pipefail

# Show usage if insufficient arguments provided
if [ $# -lt 2 ]; then
    echo "Usage: $0 --private-key KEY --address IP" >&2
    echo "Example: $0 --private-key abc123... --address 172.16.0.201" >&2
    exit 1
fi

# Constants
CONFIG_FILE="wireguard/peers.json"
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

# Ensure config file exists
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Error: ${CONFIG_FILE} not found" >&2
    exit 1
fi

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Generate config file
CONFIG="${OUTPUT_DIR}/wg0.conf"

# Write interface section
cat > "${CONFIG}" << EOF
[Interface]
Address = ${ADDRESS}/24
MTU = ${MTU}
PrivateKey = ${PRIVATE_KEY}
ListenPort = ${PORT}

# Peers within the group
EOF

# Add server peers
jq -r '.servers | to_entries[] | .value | to_entries[] | .value | 
    "[Peer]\nPublicKey = \(.publicKey)\nAllowedIPs = \(.privateIP)/32\nEndpoint = \(.endpoint):51820\nPersistentKeepalive = 25\n"' \
    "${CONFIG_FILE}" >> "${CONFIG}"

# Add admin peers
jq -r '.admins | to_entries[] | .value |
    "[Peer]\nPublicKey = \(.publicKey)\nAllowedIPs = \(.privateIP)/32\nEndpoint = \(.endpoint):51820\nPersistentKeepalive = 25\n"' \
    "${CONFIG_FILE}" >> "${CONFIG}"

echo "WireGuard configuration written to ${CONFIG}" >&2
