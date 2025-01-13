#!/usr/bin/env bash
set -euo pipefail

# Default values
HOSTNAME=""
EXTRA_ARGS=()

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -*)
            EXTRA_ARGS+=("$1")
            shift
            ;;
        *)
            if [ -z "$HOSTNAME" ]; then
                HOSTNAME="$1"
            else
                EXTRA_ARGS+=("$1")
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ -z "$HOSTNAME" ]; then
    echo "Usage: deploy-nixos <hostname> [extra nixos-anywhere args...]" >&2
    echo "Example: deploy-nixos myserver" >&2
    exit 1
fi

# Check if host configuration exists
if [ ! -f "hosts/${HOSTNAME}/default.nix" ]; then
    echo "Error: Configuration for host '${HOSTNAME}' not found in hosts/${HOSTNAME}/default.nix" >&2
    exit 1
fi

# Extract IP address using nix evaluation
IP_ADDRESS=$(nix eval --impure --expr "
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

if [ -z "$IP_ADDRESS" ]; then
    echo "Error: Could not extract IP address from host configuration" >&2
    exit 1
fi

# Set target host and flake
TARGET_HOST="root@${IP_ADDRESS}"
FLAKE_TARGET=".#${HOSTNAME}"

# Create a temporary directory for secrets
TEMP_DIR=$(mktemp -d)

# Cleanup function
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Create SSH directory
install -d -m755 "$TEMP_DIR/etc/ssh"

# Decrypt and install SSH host keys
echo "Installing SSH host keys for $HOSTNAME..." >&2
sops --decrypt secrets/server-private-ssh-keys.json | \
    jq -r --arg name "$HOSTNAME" \
    '.[$name].rsa' > "$TEMP_DIR/etc/ssh/ssh_host_rsa_key"

sops --decrypt secrets/server-private-ssh-keys.json | \
    jq -r --arg name "$HOSTNAME" \
    '.[$name].ed25519' > "$TEMP_DIR/etc/ssh/ssh_host_ed25519_key"

# Set correct permissions
chmod 600 "$TEMP_DIR/etc/ssh/ssh_host_rsa_key"
chmod 600 "$TEMP_DIR/etc/ssh/ssh_host_ed25519_key"

echo "Deploying $FLAKE_TARGET to $TARGET_HOST..." >&2
nixos-anywhere --extra-files "$TEMP_DIR" --flake "$FLAKE_TARGET" "${EXTRA_ARGS[@]}" "$TARGET_HOST"
