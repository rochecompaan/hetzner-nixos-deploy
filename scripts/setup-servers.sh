#!/usr/bin/env bash
set -euo pipefail

# Process each host directory
for host_dir in hosts/*; do
    if [ ! -d "$host_dir" ]; then
       continue
    fi

    hostname=$(basename "$host_dir")
    echo "Processing server: $hostname"

    ip=$(get_server_ip "$hostname")

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
    generate-disko-config "$hostname"

    # Step 3: Generate hardware configuration
    echo "Generating hardware configuration..."
    generate-hardware-config "$hostname"

    echo "Setup complete for $hostname"
    echo "----------------------------------------"
done

echo "All servers processed"
