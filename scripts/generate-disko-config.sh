#!/usr/bin/env bash

set -e

REMOTE_SERVER="$1"
HOSTNAME="$2"
REMOTE_USER="root"

# Check if required variables are set
if [ -z "$REMOTE_SERVER" ] || [ -z "$HOSTNAME" ]; then
    echo "Error: REMOTE_SERVER, and HOSTNAME must be set."
    echo "Usage: gegenerate-disko-config.sh <server> <host>"
    exit 1
fi

# Create the output directory
OUTPUT_DIR="./hosts/$HOSTNAME"
mkdir -p "$OUTPUT_DIR"
DISKO_CONFIG_FILE="$OUTPUT_DIR/disko.nix"

# Function to convert size to MB
convert_to_mb() {
    local size=$1
    local unit=${size: -1}
    local value=${size::-1}

    case $unit in
        G) echo $((value * 1024)) ;;
        M) echo "$value" ;;
        K) echo $((value / 1024)) ;;
        *) echo $((size / 1048576)) ;;  # Assume bytes if no unit
    esac
}

# Get list of disks, excluding loopback devices, using SSH
disks=$(ssh "$REMOTE_USER@$REMOTE_SERVER" "lsblk -dnp -o NAME,SIZE,TYPE | grep -v loop | awk '\$3 == \"disk\" {print \$1 \",\" \$2}'")

# Count the number of disks
disk_count=$(echo "$disks" | wc -l)

# Check if we have exactly two disks of the same size
use_raid=false
if [ "$disk_count" -eq 2 ]; then
    sizes=$(echo "$disks" | cut -d',' -f2 | sort -u)
    if [ "$(echo "$sizes" | wc -l)" -eq 1 ]; then
        use_raid=true
    fi
fi

# Start of disko.nix content
cat << EOF > "$DISKO_CONFIG_FILE"
{ lib, ... }:
{
  disko.devices = {
    disk = {
EOF

if [ "$use_raid" = true ]; then
    # RAID1 configuration
    disk_index=0
    for disk_info in $disks; do
        disk=$(echo "$disk_info" | cut -d',' -f1)
        disk_name=$(basename "$disk")
        
        cat << EOF >> "$DISKO_CONFIG_FILE"
      $disk_name = {
        type = "disk";
        device = "$disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot$disk_index";
              };
            };
            raid = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "raid1";
              };
            };
          };
        };
      };
EOF
        disk_index=$((disk_index + 1))
    done

    # Add RAID1 configuration
    cat << EOF >> "$DISKO_CONFIG_FILE"
    };
    mdadm = {
      raid1 = {
        type = "mdadm";
        level = 1;
        metadata = "1.2";
        content = {
          type = "gpt";
          partitions = {
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
EOF

else
    # Single disk configuration
    disk_info=$(echo "$disks" | head -n1)
    disk=$(echo "$disk_info" | cut -d',' -f1)
    disk_name=$(basename "$disk")

    cat << EOF >> "./hosts/$HOSTNAME/disko.nix"
      $disk_name = {
        type = "disk";
        device = "$disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
EOF
fi

echo "disko.nix file has been generated in $DISKO_CONFIG_FILE"
if [ "$use_raid" = true ]; then
    echo "RAID1 configuration created for two disks of the same size."
else
    echo "Single disk configuration created."
fi
