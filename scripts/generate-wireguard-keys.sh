#!/usr/bin/env bash
set -euo pipefail

# Show usage if insufficient arguments provided
if [ $# -lt 2 ]; then
    echo "Usage: $0 <environment> <server1> [server2 ...]" >&2
    echo "Example: $0 staging web1 web2 db1" >&2
    exit 1
fi

# Constants
SECRETS_FILE="secrets/wireguard.json"
TEMP_FILE=$(mktemp)
SOPS_CONFIG=".sops.yaml"

# Get environment from first argument and shift arguments
ENVIRONMENT="$1"
shift

# Ensure required tools are available
if ! command -v wg &> /dev/null; then
    echo "Error: wireguard-tools is required but not installed" >&2
    exit 1
fi

if ! command -v sops &> /dev/null; then
    echo "Error: sops is required but not installed" >&2
    exit 1
fi

# Check if SOPS config exists
if [[ ! -f "${SOPS_CONFIG}" ]]; then
    echo "Error: ${SOPS_CONFIG} not found. Please create a SOPS configuration first." >&2
    exit 1
fi

# Create secrets directory if it doesn't exist
mkdir -p "$(dirname "${SECRETS_FILE}")"

# Function to generate WireGuard keypair
generate_wireguard_keypair() {
    local private_key
    local public_key
    
    private_key=$(wg genkey)
    public_key=$(echo "${private_key}" | wg pubkey)
    
    echo "{\"privateKey\": \"${private_key}\", \"publicKey\": \"${public_key}\"}"
}

# Initialize or read existing secrets file
if [[ -f "${SECRETS_FILE}" ]]; then
    sops --decrypt "${SECRETS_FILE}" > "${TEMP_FILE}"
    # Preserve admins section if it exists
    if ! jq -e '.admins' "${TEMP_FILE}" >/dev/null 2>&1; then
        jq '. + {"admins": {}}' "${TEMP_FILE}" > "${TEMP_FILE}.new" && mv "${TEMP_FILE}.new" "${TEMP_FILE}"
    fi
else
    echo '{"servers": {}, "admins": {}}' > "${TEMP_FILE}"
fi

# Ensure environment structure exists, preserving other environments
jq --arg env "${ENVIRONMENT}" \
   'if .servers[$env] == null then .servers[$env] = {} else . end' \
   "${TEMP_FILE}" > "${TEMP_FILE}.new" && mv "${TEMP_FILE}.new" "${TEMP_FILE}"

# Start printing the public keys output
echo "        servers.${ENVIRONMENT} = {"

# Process each server
for server in "$@"; do
    # Generate new keypair for this server
    keypair=$(generate_wireguard_keypair)
    public_key=$(echo "${keypair}" | jq -r '.publicKey')
    private_key=$(echo "${keypair}" | jq -r '.privateKey')
    
    # Update only this server's private key while preserving others
    jq --arg env "${ENVIRONMENT}" \
       --arg server "${server}" \
       --arg private_key "${private_key}" \
       '.servers[$env][$server] = {"privateKey": $private_key}' \
       "${TEMP_FILE}" > "${TEMP_FILE}.new" && mv "${TEMP_FILE}.new" "${TEMP_FILE}"
    
    # Print the public key in the requested format
    echo "          \"${server}\".publicKey = \"${public_key}\";"
done

# Close the output block
echo "        };"

# Copy the unencrypted file to the target location
cp "${TEMP_FILE}" "${SECRETS_FILE}"

# Encrypt the file in place using sops
sops --encrypt --in-place "${SECRETS_FILE}"

# Clean up
rm "${TEMP_FILE}"

# Print completion message to stderr (so it doesn't interfere with the public key output)
echo "Done! Private keys have been stored and encrypted in ${SECRETS_FILE}" >&2
