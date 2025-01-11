#!/usr/bin/env bash
set -euo pipefail

# Process each host directory
for host_dir in hosts/*; do
    if [ ! -d "$host_dir" ]; then
       continue
    fi

    hostname=$(basename "$host_dir")
    echo "Processing server: $hostname"

    # Get server IP from the default.nix configuration
    ip=$(grep -A 2 'address = ' "$host_dir/default.nix" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    
    if [ -z "$ip" ]; then
        echo "Could not find IP address for $hostname, skipping..."
        continue
    fi

    echo "Setting up $hostname ($ip)..."

    # Step 1: Activate rescue mode and boot into NixOS
    echo "Activating rescue mode..."
    activate-rescue-mode "$ip"

    # Step 2: Generate disk configuration
    echo "Generating disk configuration..."
    generate-disko-config "$ip" "$hostname"

    # Step 3: Generate hardware configuration
    echo "Generating hardware configuration..."
    generate-hardware-config "$ip" "$hostname"

    echo "Setup complete for $hostname"
    echo "----------------------------------------"
done

echo "All servers processed"
