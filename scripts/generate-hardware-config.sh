#!/usr/bin/env bash

set -e


# Default values
SERVER_IP=""
HOSTNAME=""
REMOTE_USER="root"

# Parse argument
if [ -z "$1" ]; then
    echo "Error: Server must be provided"
    echo "Usage: generate-hardware-config.sh <SERVER_IP|HOSTNAME>"
    echo ""
    echo "Arguments:"
    echo "  SERVER_IP     IP address of the server"
    echo "  HOSTNAME      Hostname of the server (will look up IP from NixOS config)"
    exit 1
fi

# Check if argument is an IP address
if [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SERVER_IP="$1"
    HOSTNAME="$1"
else
    HOSTNAME="$1"
    # Look up IP from hostname's NixOS configuration
    SERVER_IP=$(nix eval --impure --expr "
      let
        config = (builtins.import ./hosts/${HOSTNAME}/default.nix) { 
          config = {}; 
          lib = (import <nixpkgs> {}).lib;
        };
        interface = builtins.head (builtins.attrNames config.networking.interfaces);
        addr = builtins.head config.networking.interfaces.\${interface}.ipv4.addresses;
      in
        addr.address
    " | tr -d '"')
fi

# Create the output directory
OUTPUT_DIR="./hosts/$HOSTNAME"
mkdir -p "$OUTPUT_DIR"

echo "Checking if we're already in the NixOS installer..."
REMOTE_HOSTNAME=$(ssh "$REMOTE_USER@$SERVER_IP" "hostname")
if [ "$REMOTE_HOSTNAME" != "nixos-installer" ]; then
    echo "Not in NixOS installer, booting into it..."
    # Run the kexec installer
    ssh "$REMOTE_USER@$SERVER_IP" << 'EOF'
        set -e
        echo "Downloading and running the NixOS kexec installer..."
        curl -L https://github.com/nix-community/nixos-images/releases/download/nixos-unstable/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz | tar -xzf- -C /root
        /root/kexec/run
EOF

    # Wait for server to become available with exponential backoff
    if ! wait_for_ssh "$SERVER_IP" "$REMOTE_USER" "nixos-installer"; then
        echo "Failed to connect to NixOS installer"
        exit 1
    fi

fi

# Generate the hardware config
echo "Generating hardware configuration..."
ssh "$REMOTE_USER@$SERVER_IP" "nixos-generate-config --no-filesystems --show-hardware-config" > "$OUTPUT_DIR/hardware-configuration.nix"

# Get the primary network interface name
PRIMARY_INTERFACE=$(ssh "$REMOTE_USER@$SERVER_IP" "ip -json route show default | jq -r '.[0].dev'")

if [ -z "$PRIMARY_INTERFACE" ]; then
    echo "Error: Could not determine primary network interface"
    exit 1
fi

# Update default.nix to use the correct interface name
if [ -f "$OUTPUT_DIR/default.nix" ]; then
    # Replace the placeholder interface name with the actual one
    sed -i "s/interfaces\.REPLACED_BY_GENERATE_HARDWARE_CONFIG/interfaces.$PRIMARY_INTERFACE/" "$OUTPUT_DIR/default.nix"
    echo "Updated network interface name in default.nix to $PRIMARY_INTERFACE"
fi

echo "Hardware configuration has been generated in $OUTPUT_DIR/hardware-configuration.nix"
