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
CONFIG_FILE="config/wireguard.json"
TEMP_SECRETS=$(mktemp)
TEMP_CONFIG=$(mktemp)
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

# Create necessary directories
mkdir -p "$(dirname "${SECRETS_FILE}")" "$(dirname "${CONFIG_FILE}")"

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
    sops --decrypt "${SECRETS_FILE}" > "${TEMP_SECRETS}"
    # Preserve admins section if it exists
    if ! jq -e '.admins' "${TEMP_SECRETS}" >/dev/null 2>&1; then
        jq '. + {"admins": {}}' "${TEMP_SECRETS}" > "${TEMP_SECRETS}.new" && mv "${TEMP_SECRETS}.new" "${TEMP_SECRETS}"
    fi
else
    echo '{"servers": {}, "admins": {}}' > "${TEMP_SECRETS}"
fi

# Initialize or read existing config file
if [[ -f "${CONFIG_FILE}" ]]; then
    cp "${CONFIG_FILE}" "${TEMP_CONFIG}"
    # Ensure basic structure exists
    if ! jq -e '.servers' "${TEMP_CONFIG}" >/dev/null 2>&1; then
        jq '. + {"servers": {}}' "${TEMP_CONFIG}" > "${TEMP_CONFIG}.new" && mv "${TEMP_CONFIG}.new" "${TEMP_CONFIG}"
    fi
else
    echo '{"servers": {}, "admins": {}}' > "${TEMP_CONFIG}"
fi

# Ensure environment structure exists in both files
for file in "${TEMP_SECRETS}" "${TEMP_CONFIG}"; do
    jq --arg env "${ENVIRONMENT}" \
       'if .servers[$env] == null then .servers[$env] = {} else . end' \
       "${file}" > "${file}.new" && mv "${file}.new" "${file}"
done

# Start printing the public keys output
echo "        servers.${ENVIRONMENT} = {"

# Process each server
for server in "$@"; do
    # Generate new keypair for this server
    keypair=$(generate_wireguard_keypair)
    public_key=$(echo "${keypair}" | jq -r '.publicKey')
    private_key=$(echo "${keypair}" | jq -r '.privateKey')
    
    # Update private key in secrets file
    jq --arg env "${ENVIRONMENT}" \
       --arg server "${server}" \
       --arg private_key "${private_key}" \
       '.servers[$env][$server] = {"privateKey": $private_key}' \
       "${TEMP_SECRETS}" > "${TEMP_SECRETS}.new" && mv "${TEMP_SECRETS}.new" "${TEMP_SECRETS}"
    
    # Update public key in config file
    jq --arg env "${ENVIRONMENT}" \
       --arg server "${server}" \
       --arg public_key "${public_key}" \
       '.servers[$env][$server] = {"publicKey": $public_key}' \
       "${TEMP_CONFIG}" > "${TEMP_CONFIG}.new" && mv "${TEMP_CONFIG}.new" "${TEMP_CONFIG}"
    
    # Print the public key in the requested format
    echo "          \"${server}\".publicKey = \"${public_key}\";"
done

# Close the output block
echo "        };"

# Save the files
cp "${TEMP_SECRETS}" "${SECRETS_FILE}"
cp "${TEMP_CONFIG}" "${CONFIG_FILE}"

# Encrypt the secrets file
sops --encrypt --in-place "${SECRETS_FILE}"

# Clean up
rm "${TEMP_SECRETS}" "${TEMP_CONFIG}"

# Print completion message to stderr
echo "Done! Private keys have been stored and encrypted in ${SECRETS_FILE}" >&2
echo "Public keys have been stored in ${CONFIG_FILE}" >&2
