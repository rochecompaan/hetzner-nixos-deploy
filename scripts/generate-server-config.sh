#!/usr/bin/env bash
set -euo pipefail

# Default values
PATTERN=${1:-""}
WG_SUBNET=${2:-"172.16.0.0/16"}

# Constants
OUTPUT_DIR="hosts"
mkdir -p "$OUTPUT_DIR"

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
    local network
    network=$(get_network_prefix "$1")
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
ALL_SERVERS=$(curl -s -u "$ROBOT_USERNAME:$ROBOT_PASSWORD" \
    "https://robot-ws.your-server.de/server" | \
    safe_jq -r '.[] | .server')

# Then filter by pattern
SERVERS=$(echo "$ALL_SERVERS" | safe_jq -c --arg pattern "$PATTERN" \
    "select(.server_name | startswith(\$pattern))")

# Debug output
echo "Filtered servers matching pattern '$PATTERN':"
echo "$SERVERS"

# Counter for WireGuard IPs (always start from 1)
counter=1

# Get subnet base for WireGuard IPs
SUBNET_BASE=$(get_subnet_base "$WG_SUBNET")

# Process each server
echo "Found $(echo "$SERVERS" | wc -l) servers matching pattern '$PATTERN'"
echo "----------------------------------------"

echo "$SERVERS" | while read -r server_json; do
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

    echo "Processing server: $name (IP: $public_ip)" >&2
    
    # For Hetzner servers, gateway is typically the first IP in the /24 subnet
    gateway=${public_ip%.*}.1
    subnet_mask="24"

    # Generate WireGuard private IP
    wg_ip="${SUBNET_BASE}.0.${counter}"

    # Create server directory
    server_dir="$OUTPUT_DIR/${name}"
    mkdir -p "$server_dir"

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
    # TODO: make interface name confirurable
    interfaces.enp0s31f6 = {
      ipv4.addresses = [{
        address = "$public_ip";
        prefixLength = $subnet_mask;
      }];
    };

    defaultGateway = "$gateway";

    # WireGuard configuration
    wg0 = {
      privateIP = "$wg_ip";
    };
  };
}
EOF

    echo "✓ Generated configuration for server: $name"
    echo "  • Location: $dc"
    echo "  • Public IP: $public_ip"
    echo "  • WireGuard IP: $wg_ip"
    echo "  • Configuration: $server_dir/default.nix"
    echo "----------------------------------------"
    ((counter++))
done

echo "Configuration generation complete"
echo "Generated configurations for $(echo "$SERVERS" | wc -l) servers"
