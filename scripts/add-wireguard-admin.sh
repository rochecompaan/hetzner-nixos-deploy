#!/usr/bin/env bash

set -euo pipefail

# Constants
SECRETS_FILE="secrets/wireguard.json"
TEMP_FILE=$(mktemp)
SOPS_CONFIG=".sops.yaml"

# Function to show usage
usage() {
    echo "Usage: $0 --name NAME --endpoint ENDPOINT --public-key PUBLIC_KEY"
    echo
    echo "Add an administrator's WireGuard configuration to the secrets file"
    echo
    echo "Options:"
    echo "  --name        Administrator name"
    echo "  --endpoint    WireGuard endpoint (e.g., domain or IP)"
    echo "  --public-key  Administrator's WireGuard public key"
    exit 1
}

# Check if required tools are available
if ! command -v sops &> /dev/null; then
    echo "Error: sops is required but not installed"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed"
    exit 1
fi

# Check if SOPS config exists
if [[ ! -f "${SOPS_CONFIG}" ]]; then
    echo "Error: ${SOPS_CONFIG} not found. Please create a SOPS configuration first."
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
        *)
        usage
        ;;
    esac
done

# Check if required arguments are provided
if [ -z "${NAME:-}" ] || [ -z "${ENDPOINT:-}" ] || [ -z "${PUBLIC_KEY:-}" ]; then
    usage
fi

# Validate public key format (base64, 44 characters)
if ! [[ $PUBLIC_KEY =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "Error: Invalid WireGuard public key format"
    exit 1
fi

# Create secrets directory if it doesn't exist
mkdir -p "$(dirname "${SECRETS_FILE}")"

# Initialize or read existing secrets file
if [[ -f "${SECRETS_FILE}" ]]; then
    sops --decrypt "${SECRETS_FILE}" > "${TEMP_FILE}"
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
   '.admins[$name] = {"endpoint": $endpoint, "publicKey": $pubkey}' \
   "${TEMP_FILE}" > "${TEMP_FILE}.new" && mv "${TEMP_FILE}.new" "${TEMP_FILE}"

# Copy the unencrypted file to the target location
cp "${TEMP_FILE}" "${SECRETS_FILE}"

# Encrypt the file in place using sops
sops --encrypt --in-place "${SECRETS_FILE}"

# Clean up
rm "${TEMP_FILE}"

echo "Successfully added/updated WireGuard configuration for admin: $NAME"
