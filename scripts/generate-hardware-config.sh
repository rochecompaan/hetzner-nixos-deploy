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

