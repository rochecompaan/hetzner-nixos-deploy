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

echo "Checking if we're already in the NixOS installer..."
REMOTE_HOSTNAME=$(ssh "$REMOTE_USER@$REMOTE_SERVER" "hostname")
if [ "$REMOTE_HOSTNAME" != "nixos-installer" ]; then
    echo "Not in NixOS installer, booting into it..."
    # Run the kexec installer
    ssh "$REMOTE_USER@$REMOTE_SERVER" << 'EOF'
        set -e
        echo "Downloading and running the NixOS kexec installer..."
        curl -L https://github.com/nix-community/nixos-images/releases/download/nixos-unstable/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz | tar -xzf- -C /root
        /root/kexec/run
EOF

  echo "Waiting for NixOS installer to become available..."
  while true; do
      REMOTE_HOSTNAME=$(ssh -o ConnectTimeout=5 "$REMOTE_USER@$REMOTE_SERVER" "hostname")
      if [ "$REMOTE_HOSTNAME" = "nixos-installer" ]; then
          echo "Successfully booted into NixOS installer"
          break
      fi
      echo "Waiting for NixOS installer to become available..."
      sleep 5
  done

fi

# Generate the hardware config
echo "Generating hardware configuration..."
ssh "$REMOTE_USER@$REMOTE_SERVER" "nixos-generate-config --show-hardware-config" > "$OUTPUT_DIR/hardware-configuration.nix"

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

echo "Hardware configuration has been generated in $OUTPUT_DIR/hardware-configuration.nix"
