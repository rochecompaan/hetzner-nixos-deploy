#!/usr/bin/env bash
set -euo pipefail

# Constants
SERVERS_CONFIG="servers.json"
PEERS_FILE="wireguard/peers.json"
SECRETS_FILE="wireguard/private-keys.json"

# Function to show usage
usage() {
    echo "Usage: $0 --environment ENV --name NAME" >&2
    echo
    echo "Generate WireGuard interface configuration for a server" >&2
    echo
    echo "Options:" >&2
    echo "  --environment  Environment name (e.g., staging, production)" >&2
    echo "  --name        Server name" >&2
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --environment)
        ENVIRONMENT="$2"
        shift 2
        ;;
        --name)
        NAME="$2"
        shift 2
        ;;
        *)
        usage
        ;;
    esac
done

# Check if required arguments are provided
if [ -z "${ENVIRONMENT:-}" ] || [ -z "${NAME:-}" ]; then
    usage
fi

# Check if required files exist
for file in "$SERVERS_CONFIG" "$PEERS_FILE" "$SECRETS_FILE"; do
    if [[ ! -f "$file" ]]; then
        echo "Error: Required file $file not found" >&2
        exit 1
    fi
done

# Create systems directory if it doesn't exist
mkdir -p "systems/x86_64-linux/$NAME"

# Get server's private IP from servers config
PRIVATE_IP=$(jq -r --arg name "$NAME" '.[$name].networking.privateIP' "$SERVERS_CONFIG")
if [ "$PRIVATE_IP" == "null" ]; then
    echo "Error: Server $NAME not found in $SERVERS_CONFIG" >&2
    exit 1
fi

# Get server's private key from encrypted secrets
PRIVATE_KEY=$(sops --decrypt "$SECRETS_FILE" | jq -r --arg env "$ENVIRONMENT" --arg name "$NAME" '.servers[$env][$name].privateKey')
if [ "$PRIVATE_KEY" == "null" ]; then
    echo "Error: Private key for $NAME not found in $SECRETS_FILE" >&2
    exit 1
fi

# Generate wg0.nix
cat > "systems/x86_64-linux/$NAME/wg0.nix" << EOF
{ config, lib, pkgs, ... }:

{
  networking.wg-quick.interfaces.wg0 = {
    address = [ "${PRIVATE_IP}/24" ];
    listenPort = 51820;
    privateKey = "\${config.sops.secrets.\"wireguard/\${config.networking.hostName}/private-key\".path}";

    peers = [
EOF

# Add server peers (excluding self)
jq -r --arg env "$ENVIRONMENT" --arg name "$NAME" \
    '.servers[$env] | to_entries[] | select(.key != $name) | .value |
    "      { # \(.key)\n" +
    "        publicKey = \"\(.publicKey)\";\n" +
    "        allowedIPs = [ \"\(.privateIP)/32\" ];\n" +
    "        endpoint = \"\(.endpoint):51820\";\n" +
    "        persistentKeepalive = 25;\n" +
    "      }"' \
    "$PEERS_FILE" >> "systems/x86_64-linux/$NAME/wg0.nix"

# Add admin peers
jq -r '.admins | to_entries[] | .key as $name | .value |
    "      { # \($name)\n" +
    "        publicKey = \"\(.publicKey)\";\n" +
    "        allowedIPs = [ \"\(.privateIP)/32\" ];\n" +
    "        endpoint = \"\(.endpoint):51820\";\n" +
    "        persistentKeepalive = 25;\n" +
    "      }"' \
    "$PEERS_FILE" >> "systems/x86_64-linux/$NAME/wg0.nix"

# Close the configuration
cat >> "systems/x86_64-linux/$NAME/wg0.nix" << EOF
    ];
  };

  # SOPS configuration for WireGuard private key
  sops.secrets."wireguard/\${config.networking.hostName}/private-key" = {
    sopsFile = ../../../secrets/\${config.networking.hostName}/\${config.deployment.environment}/secrets.yaml;
    restartUnits = [ "wg-quick-wg0.service" ];
  };
}
EOF

echo "Generated WireGuard interface configuration in systems/x86_64-linux/$NAME/wg0.nix" >&2
