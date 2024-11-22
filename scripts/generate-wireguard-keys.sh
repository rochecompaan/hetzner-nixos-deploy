#!/usr/bin/env bash
set -euo pipefail

# Constants
SERVERS_CONFIG="servers.json"
SECRETS_FILE="secrets/wireguard.json"
TEMP_SECRETS=$(mktemp)
TEMP_CONFIG=$(mktemp)
SOPS_CONFIG=".sops.yaml"

# Helper function to safely run jq
safe_jq() {
    local result
    if ! result=$(jq "$@" 2>&1); then
        echo "Error running jq command: $result" >&2
        echo "Command was: jq $*" >&2
        exit 1
    fi
    echo "$result"
}

# Ensure required tools are available
if ! command -v wg &> /dev/null; then
    echo "Error: wireguard-tools is required but not installed" >&2
    exit 1
fi

if ! command -v sops &> /dev/null; then
    echo "Error: sops is required but not installed" >&2
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed" >&2
    exit 1
fi

# Check if required files exist
for file in "$SERVERS_CONFIG" "$SOPS_CONFIG"; do
    if [[ ! -f "${file}" ]]; then
        echo "Error: Required file ${file} not found" >&2
        exit 1
    fi
done

# Create necessary directories
mkdir -p "$(dirname "${SECRETS_FILE}")"

# Function to generate WireGuard keypair
generate_wireguard_keypair() {
    local private_key
    local public_key
    
    private_key=$(wg genkey)
    public_key=$(echo "${private_key}" | wg pubkey)
    
    echo "{\"privateKey\": \"${private_key}\", \"publicKey\": \"${public_key}\"}"
}

# Helper function to safely run jq
safe_jq() {
    local result
    if ! result=$(jq "$@" 2>&1); then
        echo "Error running jq command: $result" >&2
        echo "Command was: jq $*" >&2
        exit 1
    fi
    echo "$result"
}

echo "Reading/initializing secrets file..." >&2
# Initialize or read existing secrets file
if [[ -f "${SECRETS_FILE}" ]]; then
    echo "Decrypting existing secrets file..." >&2
    sops --decrypt "${SECRETS_FILE}" > "${TEMP_SECRETS}"
else
    echo "Creating new secrets file..." >&2
    echo '{"servers": {}}' > "${TEMP_SECRETS}"
fi

echo "Copying servers config..." >&2
# Copy servers config for modification
cp "${SERVERS_CONFIG}" "${TEMP_CONFIG}"

echo "Getting server list..." >&2
# Get list of servers from servers.json
SERVERS=$(safe_jq -r '.servers | keys[]' "${SERVERS_CONFIG}")

# Process each server
for server in $SERVERS; do
    echo "Processing server: $server" >&2
    
    # Generate new keypair for this server
    keypair=$(generate_wireguard_keypair)
    private_key=$(echo "${keypair}" | safe_jq -r '.privateKey')
    public_key=$(echo "${keypair}" | safe_jq -r '.publicKey')
    
    # Get server's public IP and private IP
    public_ip=$(safe_jq -r --arg name "$server" '.servers[$name].networking.enp0s31f6.publicIP' "${SERVERS_CONFIG}")
    private_ip=$(safe_jq -r --arg name "$server" '.servers[$name].networking.wg0.privateIP' "${SERVERS_CONFIG}")
    
    echo "Updating secrets for server $server..." >&2
    # Update private key in secrets file
    safe_jq --arg server "$server" \
       --arg private_key "$private_key" \
       '.servers[$server] = {"privateKey": $private_key}' \
       "${TEMP_SECRETS}" > "${TEMP_SECRETS}.new" && mv "${TEMP_SECRETS}.new" "${TEMP_SECRETS}"
    
    echo "Updating config for server $server..." >&2
    # Update server config with public key and endpoint
    safe_jq --arg server "$server" \
       --arg public_key "$public_key" \
       --arg public_ip "$public_ip" \
       --arg private_ip "$private_ip" \
       '.servers[$server].networking.wg0 += {
          "publicKey": $public_key,
          "endpoint": $public_ip,
          "privateIP": $private_ip
        }' \
       "${TEMP_CONFIG}" > "${TEMP_CONFIG}.new" && mv "${TEMP_CONFIG}.new" "${TEMP_CONFIG}"
done

# Save the files
cp "${TEMP_CONFIG}" "${SERVERS_CONFIG}"
cp "${TEMP_SECRETS}" "${SECRETS_FILE}"
sops --encrypt --in-place "${SECRETS_FILE}"

# Clean up
rm "${TEMP_SECRETS}" "${TEMP_CONFIG}"

# Print completion message
echo "WireGuard configuration completed:" >&2
echo "  • Private keys stored in ${SECRETS_FILE} (encrypted)" >&2
echo "  • Server configuration updated in ${SERVERS_CONFIG}" >&2
