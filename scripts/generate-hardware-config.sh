#!/usr/bin/env bash

set -e

REMOTE_SERVER="$1"
REMOTE_USER="root"
LOCAL_DIR="./nixos-configs/$REMOTE_SERVER"

echo "Creating local directory to store configuration files..."
mkdir -p $LOCAL_DIR

echo "Running kexec installer and generating hardware config on remote server..."

# Run the kexec installer and generate the hardware config
ssh $REMOTE_USER@$REMOTE_SERVER << 'EOF'
    set -e
    echo "Downloading and running the NixOS kexec installer..."
    curl -L https://github.com/nix-community/nixos-images/releases/download/nixos-unstable/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz | tar -xzf- -C /root
    /root/kexec/run

    echo "Generating hardware configuration..."
    nixos-generate-config --no-filesystems --dir /mnt
EOF

# Copy generated configuration files from the remote server to the local machine
echo "Copying configuration files from remote server..."
scp -r $REMOTE_USER@$REMOTE_SERVER:/mnt/etc/nixos/hardware-configuration.nix $LOCAL_DIR/

echo "Generating disk configuration by parsing Hetzner installimage output..."

# Run the Hetzner installimage command to only generate config
INSTALLIMAGE_OUTPUT=$(ssh $REMOTE_USER@$REMOTE_SERVER installimage -a -c)

# Parse the installimage output to extract drive information
DISKS=$(echo "$INSTALLIMAGE_OUTPUT" | grep '^DRIVE' | awk '{ print $2 }')

# Generate a disko configuration based on the parsed drives
DISKO_CONFIG="$LOCAL_DIR/disko.nix"
echo "Creating disko configuration file at $DISKO_CONFIG..."

cat <<EOF > $DISKO_CONFIG
{
  config = {
    partitions = {
EOF

for DISK in $DISKS; do
    echo "      $DISK = { type = \"gpt\"; };"
done >> $DISKO_CONFIG

cat <<EOF >> $DISKO_CONFIG
    };
  };
}
EOF

echo "Disk configuration generated and saved to $DISKO_CONFIG."
