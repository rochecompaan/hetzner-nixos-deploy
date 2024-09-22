#!/usr/bin/env bash

set -e

HETZNER_API_BASE_URL="https://robot-ws.your-server.de"

echo "Decrypting secrets..."
USERNAME=$(sops -d --extract '["hetzner_robot_username"]' ./secrets/hetzner.json)
PASSWORD=$(sops -d --extract '["hetzner_robot_password"]' ./secrets/hetzner.json)
SERVER_IP="$1"

if [ -z "$SERVER_IP" ]; then
  echo "Usage: $0 <SERVER_IP>"
  exit 1
fi

# Extract PGP IDs from .sops.yaml using yq
GPG_IDS=$(yq -r '.keys[]' .sops.yaml)

# Check if any GPG IDs were found
if [ -z "$GPG_IDS" ]; then
    echo "Error: No GPG IDs found in .sops.yaml."
    exit 1
fi

# Initialize an array to hold fingerprints
FINGERPRINTS=()

# Loop over each GPG ID and compute its SSH MD5 fingerprint
for GPG_ID in $GPG_IDS; do
    # Export the GPG public key in SSH format and compute the MD5 fingerprint
    FINGERPRINT=$(gpg --export-ssh-key "$GPG_ID" 2>/dev/null | \
        ssh-keygen -E md5 -lf - 2>/dev/null | \
        awk '{gsub("MD5:", "", $2); print $2}')

    # Check if the fingerprint was successfully computed
    if [ -n "$FINGERPRINT" ]; then
        # Append the fingerprint to the array
        FINGERPRINTS+=("$FINGERPRINT")
    else
        echo "Warning: Failed to compute fingerprint for GPG ID: $GPG_ID"
    fi
done

# Check if any fingerprints were computed
if [ ${#FINGERPRINTS[@]} -eq 0 ]; then
    echo "Error: No fingerprints were computed."
    exit 1
fi

# Concatenate the fingerprints (separated by commas)
FINGERPRINTS=$(IFS=,; echo "${FINGERPRINTS[*]}")

echo "Checking current rescue mode state for $SERVER_IP..."
RESPONSE=$(curl -s -u "$USERNAME:$PASSWORD" "$HETZNER_API_BASE_URL/boot/$SERVER_IP/rescue")
HTTP_STATUS=$(echo $RESPONSE | yq -r '.error.status')
if [[ $HTTP_STATUS -eq 401 ]]; then
  echo "Error: Unauthorized access. Please check your credentials."
  exit 1
fi

RESCUE_STATE=$(echo $RESPONSE | yq -r '.rescue.active')
if [[ $RESCUE_STATE == "true" ]]; then
  echo "Rescue mode is already active for $SERVER_IP. Skipping activation."
  exit 0
fi

echo "Activating rescue mode for $SERVER_IP..."
curl -u "$USERNAME:$PASSWORD" \
  -d "os=linux&authorized_key[]=$FINGERPRINTS" \
  "$HETZNER_API_BASE_URL/boot/$SERVER_IP/rescue"

echo "Executing hardware reset for $SERVER_IP..."
curl -s -u "$USERNAME:$PASSWORD" \
  -d "type=hw" \
  "$HETZNER_API_BASE_URL/reset/$SERVER_IP"

echo "Removing $SERVER_IP from local known_hosts file..."
ssh-keygen -R "$SERVER_IP"

echo "Pausing for hardware reset to kick in for $SERVER_IP..."
sleep 30

echo "Waiting for $SERVER_IP to come back online..."
timeout 180 bash -c \
  "until nc -zv $SERVER_IP 22; do sleep 1; done"

echo "$SERVER_IP is back online."
