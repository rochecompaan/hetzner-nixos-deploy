#!/usr/bin/env bash

set -e

REMOTE_SERVER="$1"
HOSTNAME="$2"
REMOTE_USER="root"

# Check if required variables are set
if [ -z "$REMOTE_SERVER" ] || [ -z "$HOSTNAME" ]; then
    echo "Error: REMOTE_SERVER, and HOSTNAME must be set."
    echo "Usage: gegenerate-disko-config.sh <server> <host>"
    exit 1
fi

# Create the output directory
OUTPUT_DIR="./systems/x86_64-linux/$HOSTNAME"
mkdir -p $OUTPUT_DIR

echo "Running kexec installer and generating hardware config on remote server..."

# Run the kexec installer and generate the hardware config
ssh $REMOTE_USER@$REMOTE_SERVER << 'EOF'
    set -e
    echo "Downloading and running the NixOS kexec installer..."
    curl -L https://github.com/nix-community/nixos-images/releases/download/nixos-unstable/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz | tar -xzf- -C /root
    /root/kexec/run
EOF

echo "Waiting for $SERVER_IP to reboot into the NixOS installer ..."
sleep 10

ssh $REMOTE_USER@$REMOTE_SERVER << 'EOF'
    echo "Generating hardware configuration..."
    nixos-generate-config --no-filesystems --dir /mnt
EOF

# Copy generated configuration files from the remote server to the local machine
echo "Copying configuration files from remote server..."
scp $REMOTE_USER@$REMOTE_SERVER:/mnt/*.nix $OUTPUT_DIR/

