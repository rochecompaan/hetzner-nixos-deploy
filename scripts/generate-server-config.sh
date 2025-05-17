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
mkdir -p "$OUTPUT_DIR" "$SSH_KEYS_DIR" modules
WIREGUARD_PEERS_FILE="modules/wireguard-peers.nix"

# Download base.nix if it doesn't exist
if [ ! -f "modules/base.nix" ]; then
    echo "Downloading base.nix module..."
    curl -o modules/base.nix https://raw.githubusercontent.com/rochecompaan/hetzner-nixos-deploy/main/modules/base.nix
fi

# Download hosts.nix and copy it to hosts/default.nix
mkdir -p hosts
if [ ! -f "hosts/default.nix" ]; then
    echo "Downloading hosts.nix module..."
    curl -o hosts/default.nix https://raw.githubusercontent.com/rochecompaan/hetzner-nixos-deploy/main/modules/hosts.nix
fi

# Create temporary decrypted secrets files
DECRYPTED_SSH_SECRETS=$(mktemp -p secrets --suffix=".json")
DECRYPTED_WG_SECRETS=$(mktemp -p secrets --suffix=".json")

# Ensure cleanup of temporary files
cleanup() {
    rm -f "${DECRYPTED_SSH_SECRETS}" "${DECRYPTED_WG_SECRETS}"
}
trap cleanup EXIT

declare -A existing_peer_details_json # Key: servername, Value: JSON string of the peer from wireguard-peers.nix
declare -A final_peer_nix_strings     # Key: servername, Value: Nix string for the peer to be written
max_seen_ip_octet=0

# Function to convert peer JSON object to Nix string
peer_json_to_nix_string() {
    local peer_json_str="$1"
    local p_name p_publicKey p_allowedIPs_0 p_endpoint p_persistentKeepalive
    p_name=$(echo "$peer_json_str" | jq -r .name)
    p_publicKey=$(echo "$peer_json_str" | jq -r .publicKey)
    p_allowedIPs_0=$(echo "$peer_json_str" | jq -r .allowedIPs[0])
    p_endpoint=$(echo "$peer_json_str" | jq -r .endpoint)
    p_persistentKeepalive=$(echo "$peer_json_str" | jq -r .persistentKeepalive)

    cat <<NIX_EOF
    {
      name = "${p_name}";
      publicKey = "${p_publicKey}";
      allowedIPs = [ "${p_allowedIPs_0}" ];
      endpoint = "${p_endpoint}";
      persistentKeepalive = ${p_persistentKeepalive:-25};
    }
NIX_EOF
}


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

if [ -f "$WIREGUARD_PEERS_FILE" ]; then
    # Try to parse existing wireguard-peers.nix
    # Returns [] for non-existent, empty, or invalid files that can't be imported.
    parsed_peers_json=$(nix eval --json --impure --expr \
        'let
           f = ./'"$WIREGUARD_PEERS_FILE"';
           emptyPeersList = []; # Renamed to avoid conflict if peers is a common var name
         in
         if builtins.pathExists f then
           let
             content = builtins.readFile f;
           in
           if content == "" then emptyPeersList
           else
             let
               evalResult = builtins.tryEval (import f).peers;
             in
             if evalResult.success then evalResult.value else emptyPeersList
         else emptyPeersList' 2>/dev/null || echo "[]")

    if [[ "$parsed_peers_json" != "[]" && -n "$parsed_peers_json" ]]; then
        echo "Successfully parsed existing $WIREGUARD_PEERS_FILE"
        # Populate existing_peer_details_json and find max_seen_ip_octet
        for row in $(echo "${parsed_peers_json}" | jq -r '.[] | @base64'); do
            _jq() { echo "${row}" | base64 --decode | jq -r "${1}"; }
            peer_name=$(_jq '.name')
            existing_peer_details_json["$peer_name"]=$(echo "${row}" | base64 --decode)

            ip=$(_jq '.allowedIPs[0]' | cut -d'/' -f1)
            octet=$(echo "$ip" | awk -F. '{print $4}')
            if [[ "$octet" -gt "$max_seen_ip_octet" ]]; then
                max_seen_ip_octet=$octet
            fi
        done
    else
        echo "Warning: $WIREGUARD_PEERS_FILE is empty, invalid, or unreadable. Treating as new."
    fi
fi
counter=$((max_seen_ip_octet + 1))

existing_wg_privkeys_json=$(cat "$DECRYPTED_WG_SECRETS")

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
    AGE_KEYS="${AGE_KEYS:-}  - &server_${name} $age_pub\n"

    # Get subnet information from Hetzner API
    echo "Fetching subnet information for $public_ip..." >&2
    RESPONSE=$(curl -s -u "$ROBOT_USERNAME:$ROBOT_PASSWORD" \
        "https://robot-ws.your-server.de/ip/$public_ip")
    check_json_error "$RESPONSE"
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

    current_wg_private_ip=""
    is_existing_peer_in_nix=false
    if [[ -v existing_peer_details_json["$name"] ]]; then
        is_existing_peer_in_nix=true
        current_wg_private_ip=$(echo "${existing_peer_details_json[$name]}" | jq -r '.allowedIPs[0]' | cut -d'/' -f1)
        echo "Server $name found in $WIREGUARD_PEERS_FILE, using IP $current_wg_private_ip."
    else
        current_wg_private_ip="${SUBNET_BASE}.0.${counter}"
        echo "Server $name is new or not in $WIREGUARD_PEERS_FILE, assigning IP $current_wg_private_ip."
        ((counter++))
    fi

    current_wg_private_key=""
    current_wg_public_key=""
    private_key_from_sops=$(echo "$existing_wg_privkeys_json" | jq -r ".servers[\"$name\"].privateKey // empty")

    if [[ -n "$private_key_from_sops" && "$OVERWRITE" = false ]]; then
        current_wg_private_key="$private_key_from_sops"
        current_wg_public_key=$(echo "${current_wg_private_key}" | wg pubkey)
        echo "Reusing existing WireGuard keys for $name from sops."
    else
        keypair=$(generate_wireguard_keypair)
        current_wg_private_key=$(echo "${keypair}" | jq -r '.privateKey')
        current_wg_public_key=$(echo "${keypair}" | jq -r '.publicKey')
        echo "Generated new WireGuard keys for $name (overwrite: $OVERWRITE)."
        # Update DECRYPTED_WG_SECRETS (sops file)
        existing_wg_privkeys_json=$(echo "$existing_wg_privkeys_json" | jq --arg server_name "$name" --arg pk "$current_wg_private_key" \
            '.servers[$server_name] = {"privateKey": $pk}')
        echo "$existing_wg_privkeys_json" > "$DECRYPTED_WG_SECRETS"
    fi

    new_peer_config_json=$(jq -n \
        --arg name "$name" \
        --arg publicKey "$current_wg_public_key" \
        --arg allowedIPs "${current_wg_private_ip}/32" \
        --arg endpoint "${public_ip}:51820" \
        --argjson persistentKeepalive 25 \
        '{name: $name, publicKey: $publicKey, allowedIPs: [$allowedIPs], endpoint: $endpoint, persistentKeepalive: $persistentKeepalive}')

    update_this_peer_nix_entry=false
    if [ "$is_existing_peer_in_nix" = false ] || [ "$OVERWRITE" = true ] || \
       [[ "$(echo "${existing_peer_details_json[$name]}" | jq -S .)" != "$(echo "$new_peer_config_json" | jq -S .)" ]]; then
        update_this_peer_nix_entry=true
        echo "Configuration for $name requires update in $WIREGUARD_PEERS_FILE."
    fi

    final_peer_nix_strings["$name"]=$(peer_json_to_nix_string "$new_peer_config_json")

    server_dir="$OUTPUT_DIR/${name}" # Define server_dir first
    mkdir -p "$server_dir" # Ensure directory exists

    # Conditionally generate wg0.nix. It's (re)generated if:
    # 1. OVERWRITE is true.
    # 2. The file wg0.nix doesn't exist yet (new server setup).
    # 3. The WireGuard peer configuration specific to this server changed (update_this_peer_nix_entry is true).
    if [ "$OVERWRITE" = true ] || [ ! -f "$server_dir/wg0.nix" ] || [ "$update_this_peer_nix_entry" = true ]; then
        echo "Generating $server_dir/wg0.nix for $name..."
    # Generate wg0.nix configuration
    cat > "$server_dir/wg0.nix" << EOF
{ config, ... }:

let
  sharedPeers = (import ../../modules/wireguard-peers.nix).peers;
  # Filter out self from peers list
  filteredPeers = builtins.filter
    (peer: peer.allowedIPs != [ "${current_wg_private_ip}/32" ])
    sharedPeers;
in
{
  networking.wireguard.interfaces.wg0 = {
    ips = [ "${current_wg_private_ip}/24" ]; # Use /24 for the interface IP
    listenPort = 51820;
    privateKeyFile = config.sops.secrets."servers/${name}/privateKey".path;
    peers = filteredPeers;
  };

  sops = {
    secrets = {
      "servers/${name}/privateKey" = {
        sopsFile = ../../secrets/wireguard.json;
      };
    };
  };
}
EOF
    else
        echo "Skipping $server_dir/wg0.nix regeneration for $name as no relevant WG changes, not overwriting, and file exists."
    fi

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

# Reconstruct wireguard-peers.nix

# Preserve peers from the original wireguard-peers.nix that were not processed (i.e., did not match PATTERN)
echo "Checking for existing peers not matching PATTERN '$PATTERN' to preserve..."
for original_peer_name in "${!existing_peer_details_json[@]}"; do
    # Check if this original peer was already processed (i.e., it matched the PATTERN and is in final_peer_nix_strings)
    # The -v check tests if the key exists.
    if ! [[ -v final_peer_nix_strings["$original_peer_name"] ]]; then
        # This peer was in the original file but not in the current $SERVERS list (did not match PATTERN)
        # Add its original Nix string representation to final_peer_nix_strings to preserve it.
        echo "Preserving non-PATTERN matching peer: $original_peer_name"
        final_peer_nix_strings["$original_peer_name"]=$(peer_json_to_nix_string "${existing_peer_details_json[$original_peer_name]}")
    fi
done

echo "Reconstructing $WIREGUARD_PEERS_FILE with all processed and preserved peers..."
cat > "$WIREGUARD_PEERS_FILE" << EOF
{
  peers = [
EOF

# Write all peers (new, updated, and preserved non-pattern matching) to the file
for key in "${!final_peer_nix_strings[@]}"; do
    echo "${final_peer_nix_strings[$key]}" >> "$WIREGUARD_PEERS_FILE"
done

cat >> "$WIREGUARD_PEERS_FILE" << EOF
  ];
}
EOF
nixfmt "$WIREGUARD_PEERS_FILE"

# Encrypt the final secrets files
echo "Encrypting secrets files..." >&2
if ! sops --encrypt "${DECRYPTED_SSH_SECRETS}" > "${SSH_SECRETS_FILE}.tmp"; then
    echo "Failed to encrypt SSH secrets" >&2
    rm -f "${SSH_SECRETS_FILE}.tmp"
    exit 1
fi
mv "${SSH_SECRETS_FILE}.tmp" "${SSH_SECRETS_FILE}"

if ! sops --encrypt "${DECRYPTED_WG_SECRETS}" > "${WG_SECRETS_FILE}.tmp"; then
    echo "Failed to encrypt WireGuard secrets" >&2
    rm -f "${WG_SECRETS_FILE}.tmp"
    exit 1
fi
mv "${WG_SECRETS_FILE}.tmp" "${WG_SECRETS_FILE}"

echo "Configuration generation complete"
echo "Generated configurations for $(echo "$SERVERS" | wc -l) servers"
echo "SSH host keys stored in $SSH_KEYS_DIR"
echo "Private keys encrypted in $SSH_SECRETS_FILE"
echo -e "\nGenerated age public keys for .sops.yaml:"
echo -e "$AGE_KEYS"
echo "Add these keys to your .sops.yaml file under the appropriate creation rules"
