#!/usr/bin/env bash

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <hostname>"
    exit 1
fi

hostname="$1"

# Build the configuration and show it
nix eval --json ".#nixosConfigurations.${hostname}.config" | jq
