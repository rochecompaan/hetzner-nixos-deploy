#!/usr/bin/env bash

set -euo pipefail

# Constants
HOSTS_DIR="hosts"

# Function to show usage
usage() {
    echo "Usage: $0 --name NAME --endpoint ENDPOINT --public-key PUBLIC_KEY --private-ip PRIVATE_IP"
    echo
    echo "Add an administrator's WireGuard configuration to the peers file and server configs"
    echo
    echo "Options:"
    echo "  --name        Administrator name"
    echo "  --endpoint    WireGuard endpoint (e.g., domain or IP)"
    echo "  --public-key  Administrator's WireGuard public key"
    echo "  --private-ip  Administrator's WireGuard private IP (e.g., 172.16.0.x)"
    exit 1
}

# Function to update wg0.nix file
update_wg0_config() {
    local server_dir="$1"
    local wg0_file="$server_dir/wg0.nix"
    local temp_file=$(mktemp)

    # Check if wg0.nix exists
    if [[ ! -f "$wg0_file" ]]; then
        echo "Warning: $wg0_file not found, skipping..." >&2
        return
    fi

    # Process the file
    awk -v name="$NAME" \
        -v pubkey="$PUBLIC_KEY" \
        -v privip="$PRIVATE_IP" \
        -v endpoint="$ENDPOINT" '
    BEGIN { in_peers = 0; peer_added = 0; }
    {
        if ($0 ~ /^    peers = \[/) {
            in_peers = 1
            print $0
            next
        }
        
        if (in_peers && $0 ~ /^    \];/) {
            if (!peer_added) {
                print "      { # " name
                print "        publicKey = \"" pubkey "\";"
                print "        allowedIPs = [ \"" privip "/32\" ];"
                print "        endpoint = \"" endpoint ":51820\";"
                print "        persistentKeepalive = 25;"
                print "      }"
            }
            in_peers = 0
            peer_added = 0
        }
        
        if (in_peers && $0 ~ "# " name) {
            # Update existing peer
            print "      { # " name
            print "        publicKey = \"" pubkey "\";"
            print "        allowedIPs = [ \"" privip "/32\" ];"
            print "        endpoint = \"" endpoint ":51820\";"
            print "        persistentKeepalive = 25;"
            print "      }"
            peer_added = 1
            # Skip existing peer config
            while (getline && $0 !~ /^      }/) { }
            next
        }
        
        print $0
    }' "$wg0_file" > "$temp_file"

    # Replace original file
    mv "$temp_file" "$wg0_file"
}

# Check if required tools are available
for cmd in jq find; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required but not installed" >&2
        exit 1
    fi
done

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
        NAME="$2"
        shift 2
        ;;
        --endpoint)
        ENDPOINT="$2"
        shift 2
        ;;
        --public-key)
        PUBLIC_KEY="$2"
        shift 2
        ;;
        --private-ip)
        PRIVATE_IP="$2"
        shift 2
        ;;
        *)
        usage
        ;;
    esac
done

# Check if required arguments are provided
if [ -z "${NAME:-}" ] || [ -z "${ENDPOINT:-}" ] || [ -z "${PUBLIC_KEY:-}" ] || [ -z "${PRIVATE_IP:-}" ]; then
    usage
fi

# Validate public key format (base64, 44 characters)
if ! [[ $PUBLIC_KEY =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "Error: Invalid WireGuard public key format" >&2
    exit 1
fi

# Validate private IP format
if ! [[ $PRIVATE_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "Error: Invalid IP address format" >&2
    exit 1
fi


# Update all server WireGuard configurations
export NAME ENDPOINT PUBLIC_KEY PRIVATE_IP
find "$HOSTS_DIR" -maxdepth 1 -mindepth 1 -type d | while read -r server_dir; do
    echo "Updating WireGuard configuration for $(basename "$server_dir")..." >&2
    update_wg0_config "$server_dir"
done

echo "Admin configuration completed:" >&2
echo "  • Server WireGuard configurations updated in $HOSTS_DIR/*/wg0.nix" >&2
