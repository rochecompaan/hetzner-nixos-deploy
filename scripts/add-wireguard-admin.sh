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
    }

    # Read file up to the closing peers bracket
    awk '/peers = \[/,/\];/ {
        if ($0 ~ /\];/) {
            # Store the line number of closing bracket
            close_line = NR
        }
        print
    }
    END {
        # Print the stored closing line
        if (close_line) {
            print "      { # " ENVIRON["NAME"]
            print "        publicKey = \"" ENVIRON["PUBLIC_KEY"] "\";"
            print "        allowedIPs = [ \"" ENVIRON["PRIVATE_IP"] "/32\" ];"
            print "        endpoint = \"" ENVIRON["ENDPOINT"] ":51820\";"
            print "        persistentKeepalive = 25;"
            print "      }"
            print "    ];"
        }
    }' "$wg0_file" > "$temp_file"

    # Print the rest of the file after peers section
    awk -v start_printing=0 '{
        if ($0 ~ /\];/) {
            start_printing = 1
            next
        }
        if (start_printing) print
    }' "$wg0_file" >> "$temp_file"

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

# Create necessary directory
mkdir -p "$(dirname "${CONFIG_FILE}")"

# Initialize or read existing config file
if [[ -f "${CONFIG_FILE}" ]]; then
    cp "${CONFIG_FILE}" "${TEMP_FILE}"
else
    echo '{"servers": {}, "admins": {}}' > "${TEMP_FILE}"
fi

# Ensure admins structure exists
jq 'if .admins == null then .admins = {} else . end' \
   "${TEMP_FILE}" > "${TEMP_FILE}.new" && mv "${TEMP_FILE}.new" "${TEMP_FILE}"

# Add or update admin configuration
jq --arg name "$NAME" \
   --arg endpoint "$ENDPOINT" \
   --arg pubkey "$PUBLIC_KEY" \
   --arg privateip "$PRIVATE_IP" \
   '.admins[$name] = {"endpoint": $endpoint, "publicKey": $pubkey, "privateIP": $privateip}' \
   "${TEMP_FILE}" > "${TEMP_FILE}.new" && mv "${TEMP_FILE}.new" "${TEMP_FILE}"

# Save the peers file
cp "${TEMP_FILE}" "${CONFIG_FILE}"
rm "${TEMP_FILE}"

# Update all server WireGuard configurations
export NAME ENDPOINT PUBLIC_KEY PRIVATE_IP
find "$HOSTS_DIR" -maxdepth 1 -mindepth 1 -type d | while read -r server_dir; do
    echo "Updating WireGuard configuration for $(basename "$server_dir")..." >&2
    update_wg0_config "$server_dir"
done

echo "Admin configuration completed:" >&2
echo "  • Peers file updated: ${CONFIG_FILE}" >&2
echo "  • Server WireGuard configurations updated in $HOSTS_DIR/*/wg0.nix" >&2
