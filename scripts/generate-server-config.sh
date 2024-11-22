#!/usr/bin/env bash
set -euo pipefail

# Default values
PATTERN=${1:-"myserver"}
WG_SUBNET=${2:-"172.16.0.0/16"}

# Constants
SERVERS_CONFIG="servers.json"
TEMP_FILE=$(mktemp)

echo "Decrypting secrets..."
ROBOT_USERNAME=$(sops -d --extract '["hetzner_robot_username"]' ./secrets/hetzner.json)
ROBOT_PASSWORD=$(sops -d --extract '["hetzner_robot_password"]' ./secrets/hetzner.json)
echo "Robot username: $ROBOT_USERNAME"
echo "Robot password: $ROBOT_PASSWORD"

# Function to get the network portion of a CIDR subnet
get_network_prefix() {
    local cidr=$1
    echo "${cidr%/*}"
}

# Function to get first two octets from network prefix
get_subnet_base() {
    local network=$(get_network_prefix "$1")
    echo "${network%.*.*}"
}

# Get Hetzner Robot credentials from SOPS
if [ ! -f "secrets/hetzner.json" ]; then
    echo "Error: secrets/hetzner.json not found" >&2
    exit 1
fi

if [ -z "$ROBOT_USERNAME" ] || [ -z "$ROBOT_PASSWORD" ]; then
    echo "Error: Could not decrypt Hetzner Robot credentials" >&2
    exit 1
fi

# Initialize servers.json structure if it doesn't exist
if [ ! -f "$SERVERS_CONFIG" ]; then
    echo '{"servers": {}, "admins": {}}' > "$SERVERS_CONFIG"
fi

# Function to get subnet info for an IP
get_subnet_info() {
    local ip=$1
    echo "Fetching subnet info for IP: $ip" >&2
    curl -s -u "$ROBOT_USERNAME:$ROBOT_PASSWORD" \
        "https://robot-ws.your-server.de/ip/$ip" | \
        safe_jq -r '.ip | {gateway: .gateway, subnet: .mask}'
}

# Helper function to safely run safe_jq
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
ALL_SERVERS=$(curl -s -u "$ROBOT_USERNAME:$ROBOT_PASSWORD" \
    "https://robot-ws.your-server.de/server" | \
    safe_jq -r '.[] | .server')

# Then filter by pattern
SERVERS=$(echo "$ALL_SERVERS" | safe_jq -c --arg pattern "$PATTERN" \
    'select(.server_name | startswith($pattern))')

# Debug output
echo "Filtered servers matching pattern '$PATTERN':"
echo "$SERVERS"

# Counter for WireGuard IPs (always start from 1)
counter=1

# Get subnet base for WireGuard IPs
SUBNET_BASE=$(get_subnet_base "$WG_SUBNET")

# Process each server
echo "$SERVERS" | while read -r server_json; do
    if [ -z "$server_json" ]; then
        continue
    fi

    # Extract server details from the full JSON object
    echo "Processing server JSON: $server_json" >&2
    name=$(echo "$server_json" | safe_jq -r '.server_name')
    public_ip=$(echo "$server_json" | safe_jq -r '.server_ip')
    
    if [ -z "$name" ] || [ -z "$public_ip" ]; then
        echo "Warning: Missing required server details, skipping..." >&2
        continue
    fi

    echo "Processing server: $name (IP: $public_ip)" >&2
    
    # For Hetzner servers, gateway is typically the first IP in the /24 subnet
    gateway=$(echo "$public_ip" | sed 's/\.[0-9]*$/.1/')
    subnet_mask="24"

    # Generate WireGuard IP based on counter
    wg_ip="172.16.0.${counter}"
    ((counter++))

    # Generate WireGuard private IP
    wg_ip="${SUBNET_BASE}.0.${counter}"

    # Create server configuration
    jq --arg name "$name" \
       --arg public_ip "$public_ip" \
       --arg gateway "$gateway" \
       --arg subnet "$subnet_mask" \
       --arg wg_ip "$wg_ip" \
       --arg interface "enp0s31f6" \
       '.servers[$name] = {
            "name": $name,
            "environment": "staging",
            "networking": {
                ($interface): {
                    "publicIP": $public_ip,
                    "defaultGateway": $gateway,
                    "subnet": ($subnet|tonumber)
                },
                "wg0": {
                    "privateIP": $wg_ip
                }
            }
        }' "$SERVERS_CONFIG" > "$TEMP_FILE" && mv "$TEMP_FILE" "$SERVERS_CONFIG"

    echo "Added/updated configuration for $name" >&2
    ((counter++))
done

echo "Configuration update complete" >&2
echo "Updated servers.json with new configurations" >&2
