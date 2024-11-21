#!/usr/bin/env bash
set -euo pipefail

# Constants
SERVERS_CONFIG="servers.json"
SECRETS_FILE="wireguard/private-keys.json"

# Check if required files exist
for file in "$SERVERS_CONFIG" "$SECRETS_FILE"; do
    if [[ ! -f "$file" ]]; then
        echo "Error: Required file $file not found" >&2
        exit 1
    fi
done

# Get list of servers from servers.json
SERVERS=$(jq -r '.servers | keys[]' "$SERVERS_CONFIG")

# Process each server
for NAME in $SERVERS; do
    echo "Generating WireGuard configuration for $NAME..." >&2

    # Create systems directory if it doesn't exist
    OUTPUT_DIR="systems/x86_64-linux/$NAME"
    mkdir -p "$OUTPUT_DIR"

    # Get server's private IP from servers config
    PRIVATE_IP=$(jq -r --arg name "$NAME" '.servers[$name].networking.wg0.privateIP' "$SERVERS_CONFIG")
    if [ "$PRIVATE_IP" == "null" ]; then
        echo "Warning: Server $NAME missing WireGuard configuration, skipping..." >&2
        continue
    fi

    # Get server's public IP for endpoint
    PUBLIC_IP=$(jq -r --arg name "$NAME" '.servers[$name].networking.enp0s31f6.publicIP' "$SERVERS_CONFIG")
    if [ "$PUBLIC_IP" == "null" ]; then
        echo "Warning: Server $NAME missing public IP configuration, skipping..." >&2
        continue
    fi

    # Generate wg0.nix
    cat > "$OUTPUT_DIR/wg0.nix" << EOF
{ config, lib, pkgs, ... }:

{
  networking.wg-quick.interfaces.wg0 = {
    address = [ "${PRIVATE_IP}/24" ];
    listenPort = 51820;
    privateKeyFile = config.sops.secrets."servers/\${environment}/\${hostname}/privateKey".path;

    peers = [
EOF

    # Add server peers (excluding self)
    jq -r --arg name "$NAME" \
        '.servers | to_entries[] | select(.key != $name) | .value |
        "      { # \(.name)\n" +
        "        publicKey = \"\(.publicKey)\";\n" +
        "        allowedIPs = [ \"\(.networking.wg0.privateIP)/32\" ];\n" +
        "        endpoint = \"\(.networking.enp0s31f6.publicIP):51820\";\n" +
        "        persistentKeepalive = 25;\n" +
        "      }"' \
        "$SERVERS_CONFIG" >> "$OUTPUT_DIR/wg0.nix"

    # Add admin peers
    jq -r '.admins | to_entries[] | .key as $name | .value |
        "      { # \($name)\n" +
        "        publicKey = \"\(.publicKey)\";\n" +
        "        allowedIPs = [ \"\(.privateIP)/32\" ];\n" +
        "        endpoint = \"\(.endpoint):51820\";\n" +
        "        persistentKeepalive = 25;\n" +
        "      }"' \
        "$SERVERS_CONFIG" >> "$OUTPUT_DIR/wg0.nix"

    # Close the configuration
    cat >> "$OUTPUT_DIR/wg0.nix" << EOF
    ];
  };

  # SOPS configuration for WireGuard private key
  sops = {
    defaultSopsFile = ../wireguard/private-keys.json;
    secrets = {
      "servers/\${environment}/\${hostname}/privateKey" = { };
    };
  };
}
EOF

    echo "Generated WireGuard interface configuration in $OUTPUT_DIR/wg0.nix" >&2
done

echo "Completed generating WireGuard configurations for all servers." >&2