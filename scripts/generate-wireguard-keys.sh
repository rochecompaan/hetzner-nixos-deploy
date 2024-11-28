#!/usr/bin/env bash
set -euo pipefail

# Constants
SECRETS_FILE="secrets/wireguard.json"
DECRYPTED_SECRETS="secrets/wireguard-decrypted.json"
SOPS_CONFIG=".sops.yaml"
HOSTS_DIR="hosts"

# Helper function to extract value from Nix expression
extract_nix_value() {
    local file="$1"
    local attr="$2"
    nix eval --file "$file" "$attr" 2>/dev/null | tr -d '"' || echo ""
}

# Ensure required tools are available
for cmd in wg sops nix; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required but not installed" >&2
        exit 1
    fi
done

# Check if required files exist
if [[ ! -f "${SOPS_CONFIG}" ]]; then
    echo "Error: Required file ${SOPS_CONFIG} not found" >&2
    exit 1
fi

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

echo "Reading/initializing secrets file..." >&2
# Initialize or read existing secrets file
mkdir -p "$(dirname "${SECRETS_FILE}")"

# Decrypt existing secrets or create new file
if [[ -f "${SECRETS_FILE}" ]]; then
    echo "Decrypting existing secrets file..." >&2
    sops --decrypt "${SECRETS_FILE}" > "${DECRYPTED_SECRETS}"
else
    echo "Creating new secrets file..." >&2
    echo '{"servers": {}}' > "${DECRYPTED_SECRETS}"
fi

echo "Getting server list..." >&2
# Get list of servers from hosts directory
SERVERS=$(find "$HOSTS_DIR" -maxdepth 1 -mindepth 1 -type d -exec basename {} \;)

# Process each server
for server in $SERVERS; do
    echo "Processing server: $server" >&2
    
    # Check if default.nix exists
    if [[ ! -f "$HOSTS_DIR/$server/default.nix" ]]; then
        echo "Warning: $HOSTS_DIR/$server/default.nix not found, skipping..." >&2
        continue
    fi
    
    # Generate new keypair for this server
    keypair=$(generate_wireguard_keypair)
    private_key=$(echo "${keypair}" | jq -r '.privateKey')
    public_key=$(echo "${keypair}" | jq -r '.publicKey')
    
    # Get server's network configuration
    public_ip=$(extract_nix_value "$HOSTS_DIR/$server/default.nix" "networking.interfaces.enp0s31f6.ipv4.addresses.0.address")
    private_ip=$(extract_nix_value "$HOSTS_DIR/$server/default.nix" "networking.wg0.privateIP")
    
    if [[ -z "$public_ip" ]] || [[ -z "$private_ip" ]]; then
        echo "Warning: Missing network configuration for $server, skipping..." >&2
        continue
    fi
    
    echo "Updating secrets for server $server..." >&2
    # Update private key in secrets file
    jq --arg server "$server" \
       --arg private_key "$private_key" \
       '.servers[$server] = {"privateKey": $private_key}' \
       "${DECRYPTED_SECRETS}" > "${DECRYPTED_SECRETS}.new" && mv "${DECRYPTED_SECRETS}.new" "${DECRYPTED_SECRETS}"
    
    echo "Updating WireGuard configuration for $server..." >&2
    # Create or update wg0.nix
    cat > "$HOSTS_DIR/$server/wg0.nix" << EOF
{ config, lib, pkgs, ... }:

{
  networking.wg-quick.interfaces.wg0 = {
    address = [ "${private_ip}/24" ];
    listenPort = 51820;
    privateKeyFile = config.sops.secrets."servers/${server}/privateKey".path;
  };

  sops = {
    defaultSopsFile = ../secrets/wireguard.json;
    secrets = {
      "servers/${server}/privateKey" = { };
    };
  };
}
EOF
done

# Encrypt the secrets file and clean up
echo "Encrypting secrets file..." >&2
sops --encrypt "${DECRYPTED_SECRETS}" > "${SECRETS_FILE}"
rm "${DECRYPTED_SECRETS}"

# Print completion message
echo "WireGuard configuration completed:" >&2
echo "  • Private keys stored in ${SECRETS_FILE} (encrypted)" >&2
echo "  • WireGuard configurations updated in hosts/<server>/wg0.nix" >&2
