#!/usr/bin/env bash
set -euo pipefail

# Default values
HOSTNAME=""
EXTRA_ARGS=()
SECRETS_BASE_PATH="${SECRETS_BASE_PATH:-./secrets}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --secrets-base-path)
            if [[ $# -lt 2 ]]; then
                echo "Error: --secrets-base-path requires a path argument" >&2
                exit 1
            fi
            SECRETS_BASE_PATH="$2"
            shift 2
            ;;
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

SECRETS_DIR="${SECRETS_BASE_PATH%/}"
SSH_SECRETS_FILE="${SECRETS_DIR}/server-private-ssh-keys.json"

# Validate required arguments
if [ -z "$HOSTNAME" ]; then
    echo "Usage: deploy-nixos [--secrets-base-path PATH] <hostname> [extra nixos-anywhere args...]" >&2
    echo "Environment: SECRETS_BASE_PATH (default: ./secrets)" >&2
    echo "Example: SECRETS_BASE_PATH=./secrets/devops deploy-nixos myserver" >&2
    exit 1
fi

# Check if host configuration exists
if [ ! -f "hosts/${HOSTNAME}/default.nix" ]; then
    echo "Error: Configuration for host '${HOSTNAME}' not found in hosts/${HOSTNAME}/default.nix" >&2
    exit 1
fi

# Extract IP address using common function
IP_ADDRESS=$(get_server_ip "$HOSTNAME")

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
sops --decrypt "$SSH_SECRETS_FILE" | \
    jq -r --arg name "$HOSTNAME" \
    '.[$name].rsa' > "$TEMP_DIR/etc/ssh/ssh_host_rsa_key"

sops --decrypt "$SSH_SECRETS_FILE" | \
    jq -r --arg name "$HOSTNAME" \
    '.[$name].ed25519' > "$TEMP_DIR/etc/ssh/ssh_host_ed25519_key"

# Set correct permissions
chmod 600 "$TEMP_DIR/etc/ssh/ssh_host_rsa_key"
chmod 600 "$TEMP_DIR/etc/ssh/ssh_host_ed25519_key"

echo "Deploying $FLAKE_TARGET to $TARGET_HOST..." >&2
nixos-anywhere --extra-files "$TEMP_DIR" --flake "$FLAKE_TARGET" "${EXTRA_ARGS[@]}" "$TARGET_HOST"
