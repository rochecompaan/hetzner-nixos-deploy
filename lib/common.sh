#!/usr/bin/env bash

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
