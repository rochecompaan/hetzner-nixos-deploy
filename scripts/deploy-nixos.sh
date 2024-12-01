#!/usr/bin/env bash
set -euo pipefail

# Default values
FLAKE_TARGET=""
TARGET_HOST=""
EXTRA_ARGS=()

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --flake)
            FLAKE_TARGET="$2"
            shift 2
            ;;
        --target)
            TARGET_HOST="$2"
            shift 2
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

# Validate required arguments
if [ -z "$FLAKE_TARGET" ] || [ -z "$TARGET_HOST" ]; then
    echo "Usage: $0 --flake <flake-target> --target <user@host> [extra nixos-anywhere args...]" >&2
    echo "Example: $0 --flake .#myserver --target root@1.2.3.4" >&2
    exit 1
fi

# Create a temporary directory for secrets
TEMP_DIR=$(mktemp -d)

# Cleanup function
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Create SSH directory
install -d -m755 "$TEMP_DIR/etc/ssh"

# Get server name from flake target
SERVER_NAME=${FLAKE_TARGET##*.#}

# Decrypt and install SSH host keys
echo "Installing SSH host keys for $SERVER_NAME..." >&2
sops --decrypt secrets/server-private-ssh-keys.json | \
    jq -r --arg name "$SERVER_NAME" \
    '.[$name].rsa' > "$TEMP_DIR/etc/ssh/ssh_host_rsa_key"

sops --decrypt secrets/server-private-ssh-keys.json | \
    jq -r --arg name "$SERVER_NAME" \
    '.[$name].ed25519' > "$TEMP_DIR/etc/ssh/ssh_host_ed25519_key"

# Set correct permissions
chmod 600 "$TEMP_DIR/etc/ssh/ssh_host_rsa_key"
chmod 600 "$TEMP_DIR/etc/ssh/ssh_host_ed25519_key"

echo "Deploying $FLAKE_TARGET to $TARGET_HOST..." >&2
nixos-anywhere --extra-files "$TEMP_DIR" --flake "$FLAKE_TARGET" "${EXTRA_ARGS[@]}" "$TARGET_HOST"
