#!/usr/bin/env bash

set -euo pipefail

# Constants
CONFIG_FILE="wireguard/peers.json"
TEMP_FILE=$(mktemp)

# Function to show usage
usage() {
    echo "Usage: $0 --name NAME --endpoint ENDPOINT --public-key PUBLIC_KEY --private-ip PRIVATE_IP"
    echo
    echo "Add an administrator's WireGuard configuration to the peers file"
    echo
    echo "Options:"
    echo "  --name        Administrator name"
    echo "  --endpoint    WireGuard endpoint (e.g., domain or IP)"
    echo "  --public-key  Administrator's WireGuard public key"
    echo "  --private-ip  Administrator's WireGuard private IP (e.g., 172.16.0.x)"
    exit 1
}

# Check if required tools are available
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed" >&2
    exit 1
fi

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

# Create necessary directory
mkdir -p "$(dirname "${CONFIG_FILE}")"

# Initialize or read existing config file
if [[ -f "${CONFIG_FILE}" ]]; then
    cp "${CONFIG_FILE}" "${TEMP_FILE}"
else
    echo '{"servers": {}, "admins": {}}' > "${TEMP_FILE}"
fi

# Ensure admins structure exists
jq 'if .admins == null then .admins = {} else . end' \
   "${TEMP_FILE}" > "${TEMP_FILE}.new" && mv "${TEMP_FILE}.new" "${TEMP_FILE}"

# Add or update admin configuration
jq --arg name "$NAME" \
   --arg endpoint "$ENDPOINT" \
   --arg pubkey "$PUBLIC_KEY" \
   --arg privateip "$PRIVATE_IP" \
   '.admins[$name] = {"endpoint": $endpoint, "publicKey": $pubkey, "privateIP": $privateip}' \
   "${TEMP_FILE}" > "${TEMP_FILE}.new" && mv "${TEMP_FILE}.new" "${TEMP_FILE}"

# Save the file
cp "${TEMP_FILE}" "${CONFIG_FILE}"

# Clean up
rm "${TEMP_FILE}"

# Print completion message
echo "Admin configuration saved to ${CONFIG_FILE}" >&2
