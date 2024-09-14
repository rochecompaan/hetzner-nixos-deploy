#!/usr/bin/env bash

set -e

echo "Decrypting secrets..."
USERNAME=$(sops -d --extract '["hetzner_robot_username"]' ./secrets/hetzner.json)
PASSWORD=$(sops -d --extract '["hetzner_robot_password"]' ./secrets/hetzner.json)
SERVER_IP="$1"
FINGERPRINTS="$2"

HETZNER_API_BASE_URL="https://robot-ws.your-server.de"

echo "Checking current rescue mode state for $SERVER_IP..."
RESCUE_STATE=$(curl -s -u $USERNAME:$PASSWORD "$HETZNER_API_BASE_URL/boot/$SERVER_IP/rescue")

if [[ $(echo "$RESCUE_STATE" | grep '"active":true') ]]; then
  echo "Rescue mode is already active for $SERVER_IP. Skipping activation."
  return 0
fi

echo "Composing rescue request body for $SERVER_IP..."
RESCUE_REQUEST=$(jq -n \
  --arg os "linux" \
  --arg arch "64" \
  --arg key "$FINGERPRINTS" \
  '{os: $os, arch: $arch, authorized_key: $key}')

echo "Activating rescue mode for $SERVER_IP..."
curl -s -X POST -u $USERNAME:$PASSWORD \
  -d "$(echo $RESCUE_REQUEST | jq -r @uri)" \
  "$HETZNER_API_BASE_URL/boot/$SERVER_IP/rescue"

echo "Executing hardware reset for $SERVER_IP..."
curl -s -X POST -u $USERNAME:$PASSWORD \
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
