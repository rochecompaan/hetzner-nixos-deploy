#!/usr/bin/env bash
set -euo pipefail


# Default values
PATTERN=""
OVERWRITE=false
WG_SUBNET="172.16.0.0/16"
counter=1  # Counter for WireGuard IPs

# Function to get subnet base (first two octets)
get_subnet_base() {
    local network="${WG_SUBNET%/*}"  # Remove CIDR notation
    echo "${network%.*.*}"  # Return first two octets
}

# Get subnet base for WireGuard IPs
SUBNET_BASE=$(get_subnet_base "$WG_SUBNET")

# Function to generate WireGuard keypair
generate_wireguard_keypair() {
    local private_key
    local public_key

    private_key=$(wg genkey)
    public_key=$(echo "${private_key}" | wg pubkey)

    echo "{\"privateKey\": \"${private_key}\", \"publicKey\": \"${public_key}\"}"
}

# Show usage if --help is specified
if [ "$1" = "--help" ]; then
    echo "Usage: $0 [--overwrite] [PATTERN]" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --overwrite    Overwrite existing configurations" >&2
    echo "  PATTERN        Optional pattern to filter server names" >&2
    exit 1
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --overwrite)
            OVERWRITE=true
            shift
            ;;
        *)
            if [ -z "$PATTERN" ]; then
                PATTERN="$1"
            fi
            shift
            ;;
    esac
done

# Constants
declare -g AGE_KEYS=""
OUTPUT_DIR="hosts"
SSH_KEYS_DIR="server-public-ssh-keys"
SSH_SECRETS_FILE="secrets/server-private-ssh-keys.json"
WG_SECRETS_FILE="secrets/wireguard.json"
mkdir -p "$OUTPUT_DIR" "$SSH_KEYS_DIR"

# Create temporary decrypted secrets files
DECRYPTED_SSH_SECRETS=$(mktemp -p secrets --suffix=".json")
DECRYPTED_WG_SECRETS=$(mktemp -p secrets --suffix=".json")

if [[ -f "${SSH_SECRETS_FILE}" ]]; then
    sops --decrypt "${SSH_SECRETS_FILE}" > "${DECRYPTED_SSH_SECRETS}"
else
    echo '{}' > "${DECRYPTED_SSH_SECRETS}"
fi

if [[ -f "${WG_SECRETS_FILE}" ]]; then
    sops --decrypt "${WG_SECRETS_FILE}" > "${DECRYPTED_WG_SECRETS}"
else
    echo '{"servers": {}}' > "${DECRYPTED_WG_SECRETS}"
fi
ROBOT_USERNAME=$(sops -d --extract '["hetzner_robot_username"]' ./secrets/hetzner.json)
ROBOT_PASSWORD=$(sops -d --extract '["hetzner_robot_password"]' ./secrets/hetzner.json)

# Get Hetzner Robot credentials from SOPS
if [ ! -f "secrets/hetzner.json" ]; then
    echo "Error: secrets/hetzner.json not found" >&2
    exit 1
fi

if [ -z "$ROBOT_USERNAME" ] || [ -z "$ROBOT_PASSWORD" ]; then
    echo "Error: Could not decrypt Hetzner Robot credentials" >&2
    exit 1
fi

# Helper function to safely run jq
safe_jq() {
    local cmd="$1"
    shift
    local result
    if ! result=$(jq "$cmd" "$@" 2>&1); then
        echo "Error running jq command: $result" >&2
        echo "Command was: jq $cmd $*" >&2
        exit 1
    fi
    echo "$result"
}

# Get servers matching pattern from Hetzner API
echo "Fetching servers" >&2
# First get all servers
RESPONSE=$(curl -s -u "$ROBOT_USERNAME:$ROBOT_PASSWORD" \
    "https://robot-ws.your-server.de/server")
echo "RESPONSE: $RESPONSE"
check_json_error "$RESPONSE"
ALL_SERVERS=$(echo "$RESPONSE" | safe_jq -r '.[] | .server')
echo "ALL_SERVERS: $ALL_SERVERS"

# Then filter by pattern
SERVERS=$(echo "$ALL_SERVERS" | safe_jq -c --arg pattern "$PATTERN" \
    "select(.server_name | startswith(\$pattern))")
echo "SERVERS: $SERVERS"

# Debug output
echo "Filtered servers matching pattern '$PATTERN':"
echo "$SERVERS"

# Create shared wireguard peers configuration
mkdir -p modules
cat > "modules/wireguard-peers.nix" << EOF
{
  peers = [
EOF


# Process each server
echo "Found $(echo "$SERVERS" | wc -l) servers matching pattern '$PATTERN'"
echo "----------------------------------------"

while read -r server_json; do
    if [ -z "$server_json" ]; then
        continue
    fi

    # Extract server details from the full JSON object
    name=$(echo "$server_json" | safe_jq -r '.server_name')
    public_ip=$(echo "$server_json" | safe_jq -r '.server_ip')
    dc=$(echo "$server_json" | safe_jq -r '.dc')

    if [ -z "$name" ] || [ -z "$public_ip" ]; then
        echo "Warning: Missing required server details, skipping..." >&2
        continue
    fi

    # Check if configuration exists
    if [ -f "$OUTPUT_DIR/${name}/default.nix" ] || \
       [ -f "$SSH_KEYS_DIR/${name}_rsa.pub" ] || \
       [ -f "$SSH_KEYS_DIR/${name}_ed25519.pub" ]; then
        if [ "$OVERWRITE" = true ]; then
            echo "Configuration exists for $name - overwriting..." >&2
        else
            echo "Configuration exists for $name - skipping (use --overwrite to force)..." >&2
            continue
        fi
    else
        echo "Processing server: $name (IP: $public_ip)" >&2
    fi

    # Generate SSH host keys
    temp_dir=$(mktemp -d)

    # Generate keys quietly
    ssh-keygen -t rsa -b 4096 -N "" -C "$name" -f "$temp_dir/ssh_host_rsa_key" -q
    ssh-keygen -t ed25519 -N "" -C "$name" -f "$temp_dir/ssh_host_ed25519_key" -q

    # Store public keys
    echo "Copying public keys to $SSH_KEYS_DIR..." >&2
    cp "$temp_dir/ssh_host_rsa_key.pub" "$SSH_KEYS_DIR/${name}_rsa.pub"
    cp "$temp_dir/ssh_host_ed25519_key.pub" "$SSH_KEYS_DIR/${name}_ed25519.pub"
    echo "Public keys copied" >&2

    # Update SOPS encrypted file with new keys
    echo "Creating JSON with private keys..." >&2
    json_content=$(jq -n \
        --arg rsa "$(cat "$temp_dir/ssh_host_rsa_key")" \
        --arg ed25519 "$(cat "$temp_dir/ssh_host_ed25519_key")" \
        --arg name "$name" \
        '{($name): {"rsa": $rsa, "ed25519": $ed25519}}')
    echo "JSON content created" >&2

    # Update the decrypted secrets file
    echo "Updating secrets..." >&2
    jq --argjson new "$json_content" '. * $new' "${DECRYPTED_SSH_SECRETS}" > "${DECRYPTED_SSH_SECRETS}.new" && \
        mv "${DECRYPTED_SSH_SECRETS}.new" "${DECRYPTED_SSH_SECRETS}"
    echo "Secrets updated" >&2

    # Generate age key from ed25519 private key
    echo "Generating age key from ed25519 key..." >&2
    age_pub=$(ssh-to-age < "$temp_dir/ssh_host_ed25519_key.pub")
    echo "Age key generated: $age_pub" >&2

    # Add SSH host keys to known_hosts
    echo "Adding SSH host keys to known_hosts..." >&2
    ssh-keygen -R "$public_ip" 2>/dev/null || true
    echo "[$public_ip]:22 $(cat "$temp_dir/ssh_host_rsa_key.pub")" >> ~/.ssh/known_hosts
    echo "[$public_ip]:22 $(cat "$temp_dir/ssh_host_ed25519_key.pub")" >> ~/.ssh/known_hosts
    echo "SSH host keys added to known_hosts" >&2

    # Clean up SSH key generation files
    echo "Cleaning up temporary files..." >&2
    rm -rf "$temp_dir"
    echo "Cleanup complete" >&2

    # Store age keys for final output
    AGE_KEYS="${AGE_KEYS:-}  • ${name}: $age_pub\n"

    # Get subnet information from Hetzner API
    echo "Fetching subnet information for $public_ip..." >&2
    RESPONSE=$(curl -s -u "$ROBOT_USERNAME:$ROBOT_PASSWORD" \
        "https://robot-ws.your-server.de/ip/$public_ip")
    http_status_check "$RESPONSE"
    ip_info="$RESPONSE"

    # Extract subnet mask and gateway
    subnet_mask=$(echo "$ip_info" | safe_jq -r '.ip.mask')
    gateway=$(echo "$ip_info" | safe_jq -r '.ip.gateway')

    if [ -z "$subnet_mask" ] || [ -z "$gateway" ]; then
        echo "Warning: Could not get subnet information, using defaults..." >&2
        gateway=${public_ip%.*}.1
        subnet_mask="24"
    fi

    # Generate WireGuard configuration
    echo "Generating WireGuard configuration..." >&2

    # Generate WireGuard keypair
    keypair=$(generate_wireguard_keypair)
    wg_private_key=$(echo "${keypair}" | jq -r '.privateKey')
    wg_public_key=$(echo "${keypair}" | jq -r '.publicKey')

    # Generate WireGuard private IP
    wg_private_ip="${SUBNET_BASE}.0.${counter}"
    ((counter++))

    # Update WireGuard private key in secrets file
    jq --arg server "$name" \
       --arg private_key "$wg_private_key" \
       '.servers[$server] = {"privateKey": $private_key}' \
       "${DECRYPTED_WG_SECRETS}" > "${DECRYPTED_WG_SECRETS}.new" && mv "${DECRYPTED_WG_SECRETS}.new" "${DECRYPTED_WG_SECRETS}"

    # Create server directory
    server_dir="$OUTPUT_DIR/${name}"
    mkdir -p "$server_dir"

    # Generate wg0.nix configuration
    cat > "$server_dir/wg0.nix" << EOF
{ config, ... }:

let
  sharedPeers = (import ../../modules/wireguard-peers.nix).peers;
  # Filter out self from peers list
  filteredPeers = builtins.filter
    (peer: peer.allowedIPs != [ "${wg_private_ip}/32" ])
    sharedPeers;
in
{
  networking.wireguard.interfaces.wg0 = {
    ips = [ "${wg_private_ip}/24" ];
    listenPort = 51820;
    privateKeyFile = config.sops.secrets."servers/${name}/privateKey".path;
    peers = filteredPeers;
  };

  sops = {
    defaultSopsFile = ../../secrets/wireguard.json;
    secrets = {
      "servers/${name}/privateKey" = { };
    };
  };
}
EOF

    # Add this server to wireguard-peers.nix
    cat >> "modules/wireguard-peers.nix" << EOF
    {
      name = "${name}";
      publicKey = "${wg_public_key}";
      allowedIPs = [ "${wg_private_ip}/32" ];
      endpoint = "${public_ip}:51820";
      persistentKeepalive = 25;
    }
EOF

    # Generate default.nix for this server
    cat > "$server_dir/default.nix" << EOF
{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ./wg0.nix
    ../../modules/base.nix
  ];

  networking = {
    hostName = "$name";
    useDHCP = false;

    # Primary network interface
    interfaces.REPLACED_BY_GENERATE_HARDWARE_CONFIG = {
      ipv4.addresses = [{
        address = "$public_ip";
        prefixLength = $subnet_mask;
      }];
    };

    defaultGateway = "$gateway";
  };
}
EOF

    echo "✓ Generated configuration for server: $name"
    echo "  • Location: $dc"
    echo "  • Public IP: $public_ip"
    echo "  • SSH host keys generated"
    echo "  • Configuration: $server_dir/default.nix"
    echo "----------------------------------------"
done < <(echo "$SERVERS")

# Close the shared peers configuration
cat >> "modules/wireguard-peers.nix" << EOF
  ];
}
EOF

# Encrypt the final secrets files
echo "Encrypting secrets files..." >&2
sops --encrypt "${DECRYPTED_SSH_SECRETS}" > "${SSH_SECRETS_FILE}"
sops --encrypt "${DECRYPTED_WG_SECRETS}" > "${WG_SECRETS_FILE}"
rm "${DECRYPTED_SSH_SECRETS}" "${DECRYPTED_WG_SECRETS}"

echo "Configuration generation complete"
echo "Generated configurations for $(echo "$SERVERS" | wc -l) servers"
echo "SSH host keys stored in $SSH_KEYS_DIR"
echo "Private keys encrypted in $SSH_SECRETS_FILE"
echo -e "\nGenerated age public keys for .sops.yaml:"
echo -e "$AGE_KEYS"
echo "Add these keys to your .sops.yaml file under the appropriate creation rules"
