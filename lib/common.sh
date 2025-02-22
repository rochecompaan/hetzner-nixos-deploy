#!/usr/bin/env bash

# Check JSON response for error field
# Usage: check_json_error "$(curl ...)"
check_json_error() {
    local RESPONSE=$1
    
    # Check if response is valid JSON
    if ! echo "$RESPONSE" | jq empty 2>/dev/null; then
        echo "Error: Invalid JSON response"
        echo "Response: $RESPONSE"
        exit 1
    fi
    
    # Check response type and handle accordingly
    if echo "$RESPONSE" | jq 'type == "object"' | grep -q true; then
        # For objects, check for error field
        if echo "$RESPONSE" | jq 'has("error")' | grep -q true; then
            echo "Error response received:"
            echo "$RESPONSE" | jq .
            exit 1
        fi
    fi
    
    # If we get here, assume success
    return 0
}

# Get server IP from hostname using NixOS config
# Usage: get_server_ip <hostname>
get_server_ip() {
    local hostname="$1"
    nix eval --impure --expr "
      let
        config = (builtins.import ./hosts/${hostname}/default.nix) { 
          config = {}; 
          lib = (import <nixpkgs> {}).lib;
        };
        interface = builtins.head (builtins.attrNames config.networking.interfaces);
        addr = builtins.head config.networking.interfaces.\${interface}.ipv4.addresses;
      in
        addr.address
    " | tr -d '"'
}

# Function to attempt SSH connection with exponential backoff
# Usage: wait_for_ssh <host> <user> [expected_hostname]
wait_for_ssh() {
    local host="$1"
    local user="$2"
    local expected_hostname="${3:-}"
    local max_attempts=10
    local timeout=10
    local attempt=1
    local wait_time=10

    echo "Waiting for SSH to become available..."
    while [ $attempt -le $max_attempts ]; do
        if hostname=$(ssh -o ConnectTimeout=$timeout -o BatchMode=yes -o StrictHostKeyChecking=no "$user@$host" "hostname" 2>/dev/null); then
            if [ -z "$expected_hostname" ] || [ "$hostname" = "$expected_hostname" ]; then
                echo "Successfully connected to host (hostname: $hostname)"
                return 0
            fi
            echo "Connected but got unexpected hostname: $hostname (expecting: $expected_hostname)"
        fi

        echo "Attempt $attempt/$max_attempts - Server not yet available, waiting ${wait_time}s..."
        sleep $wait_time

        # Exponential backoff with max of 30 seconds
        wait_time=$(( wait_time * 2 ))
        [ $wait_time -gt 30 ] && wait_time=30
        
        ((attempt++))
    done

    echo "Error: Failed to connect to host after $max_attempts attempts"
    return 1
}
