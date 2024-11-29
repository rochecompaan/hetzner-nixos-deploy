#!/usr/bin/env bash

set -e

REMOTE_SERVER="$1"
HOSTNAME="$2"
REMOTE_USER="root"

# Check if required variables are set
if [ -z "$REMOTE_SERVER" ] || [ -z "$HOSTNAME" ]; then
    echo "Error: REMOTE_SERVER, and HOSTNAME must be set."
    echo "Usage: gegenerate-hardware-config.sh <server> <host>"
    exit 1
fi

# Create the output directory
OUTPUT_DIR="./hosts/$HOSTNAME"
mkdir -p "$OUTPUT_DIR"

echo "Running kexec installer and generating hardware config on remote server..."

# Run the kexec installer
ssh $REMOTE_USER@"$REMOTE_SERVER" << 'EOF'
    set -e
    echo "Downloading and running the NixOS kexec installer..."
    curl -L https://github.com/nix-community/nixos-images/releases/download/nixos-unstable/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz | tar -xzf- -C /root
    /root/kexec/run
EOF

echo "Waiting for $REMOTE_SERVER to reboot into the NixOS installer ..."
sleep 30

# Generate the hardware config
ssh $REMOTE_USER@"$REMOTE_SERVER" << 'EOF'
    echo "Generating hardware configuration..."
    nixos-generate-config --no-filesystems --dir /mnt
EOF

# Copy hardware config from the remote server to the local machine
echo "Copying hardware-configuration.nix from remote server..."
scp $REMOTE_USER@"$REMOTE_SERVER":/mnt/hardware-configuration.nix "$OUTPUT_DIR"/

# Get the primary network interface name
PRIMARY_INTERFACE=$(ssh "$REMOTE_USER@$REMOTE_SERVER" "ip -json route show default | jq -r '.[0].dev'")

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
