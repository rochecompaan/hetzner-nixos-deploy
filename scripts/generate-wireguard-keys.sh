#!/usr/bin/env bash
set -euo pipefail

# Show usage if no arguments provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 server1 server2 ..."
    echo "Example: $0 web1 web2 db1"
    exit 1
fi

# Constants
SECRETS_FILE="secrets/wireguard.json"
TEMP_FILE=$(mktemp)
SOPS_CONFIG=".sops.yaml"

# Ensure required tools are available
if ! command -v wg &> /dev/null; then
    echo "Error: wireguard-tools is required but not installed"
    exit 1
fi

if ! command -v sops &> /dev/null; then
    echo "Error: sops is required but not installed"
    exit 1
fi

# Create secrets directory if it doesn't exist
mkdir -p "$(dirname "${SECRETS_FILE}")"

# Check if SOPS config exists
if [[ ! -f "${SOPS_CONFIG}" ]]; then
    echo "Error: ${SOPS_CONFIG} not found. Please create a SOPS configuration first."
    exit 1
fi

# Function to generate WireGuard keypair
generate_wireguard_keypair() {
    local private_key
    local public_key
    
    private_key=$(wg genkey)
    public_key=$(echo "${private_key}" | wg pubkey)
    
    echo "{\"private\": \"${private_key}\", \"public\": \"${public_key}\"}"
}

# Initialize or read existing secrets file
if [[ -f "${SECRETS_FILE}" ]]; then
    sops --decrypt "${SECRETS_FILE}" > "${TEMP_FILE}"
else
    echo '{"wireguard": {}}' > "${TEMP_FILE}"
fi

# Generate keys for each server
for server in "$@"; do
    echo "Generating WireGuard keys for ${server}..."
    
    # Check if keys already exist for this server
    if jq -e ".wireguard.${server}" "${TEMP_FILE}" >/dev/null 2>&1; then
        echo "Keys already exist for ${server}, skipping..."
        continue
    fi
    
    # Generate new keypair and add to JSON
    keypair=$(generate_wireguard_keypair)
    jq --arg server "${server}" \
       --argjson keypair "${keypair}" \
       '.wireguard[$server] = $keypair' \
       "${TEMP_FILE}" > "${TEMP_FILE}.new" && mv "${TEMP_FILE}.new" "${TEMP_FILE}"
done

# Encrypt the final file with SOPS
sops --encrypt "${TEMP_FILE}" > "${SECRETS_FILE}"

# Clean up
rm "${TEMP_FILE}"

echo "Done! WireGuard keys have been generated and encrypted in ${SECRETS_FILE}"
