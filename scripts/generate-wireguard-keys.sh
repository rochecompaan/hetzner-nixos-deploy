#!/usr/bin/env bash
set -euo pipefail

# Show usage if insufficient arguments provided
if [ $# -lt 2 ]; then
    echo "Usage: $0 <environment> <server1> [server2 ...]"
    echo "Example: $0 staging web1 web2 db1"
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
    echo "Error: wireguard-tools is required but not installed"
    exit 1
fi

if ! command -v sops &> /dev/null; then
    echo "Error: sops is required but not installed"
    exit 1
fi

# Check if SOPS config exists
if [[ ! -f "${SOPS_CONFIG}" ]]; then
    echo "Error: ${SOPS_CONFIG} not found. Please create a SOPS configuration first."
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
else
    echo '{"servers": {}}' > "${TEMP_FILE}"
fi

# Ensure environment structure exists
jq --arg env "${ENVIRONMENT}" \
   'if .servers[$env] == null then .servers[$env] = {} else . end' \
   "${TEMP_FILE}" > "${TEMP_FILE}.new" && mv "${TEMP_FILE}.new" "${TEMP_FILE}"

# Generate keys for each server
for server in "$@"; do
    echo "Generating WireGuard keys for ${server} in ${ENVIRONMENT} environment..."
    
    # Check if keys already exist for this server in the environment
    if jq -e ".servers.${ENVIRONMENT}.${server}" "${TEMP_FILE}" >/dev/null 2>&1; then
        echo "Keys already exist for ${server} in ${ENVIRONMENT}, skipping..."
        continue
    fi
    
    # Generate new keypair and add to JSON
    keypair=$(generate_wireguard_keypair)
    jq --arg env "${ENVIRONMENT}" \
       --arg server "${server}" \
       --argjson keypair "${keypair}" \
       '.servers[$env][$server] = $keypair' \
       "${TEMP_FILE}" > "${TEMP_FILE}.new" && mv "${TEMP_FILE}.new" "${TEMP_FILE}"
done

# Copy the unencrypted file to the target location
cp "${TEMP_FILE}" "${SECRETS_FILE}"

# Encrypt the file in place using sops
sops --encrypt --in-place "${SECRETS_FILE}"

# Clean up
rm "${TEMP_FILE}"

echo "Done! WireGuard keys have been generated and encrypted in ${SECRETS_FILE}"
