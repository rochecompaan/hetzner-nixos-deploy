# hetzner-nixos-deploy

A collection of NixOS modules and utilities for deploying and managing bare
metal servers on Hetzner. This repository provides reusable components that can
be integrated into project-specific NixOS configurations.

## Features

- Automated rescue mode activation for Hetzner servers
- Hardware configuration generation
- Disk partitioning configuration using disko
- WireGuard key management and peer configuration
- Base system configuration including:
  - Network setup with WireGuard VPN
  - SSH server configuration
  - Basic security settings
  - User management
  - Common system packages

## Setup Phases

### 1. Initial Setup

1. Prerequisites
   - Nix with flakes enabled
   - A Hetzner server
   - SOPS for secrets management
   - Basic understanding of NixOS configuration

2. SOPS Configuration
   ```yaml
   keys:
     - &admin_alice age1...
     - &admin_bob age1...
   creation_rules:
     - path_regex: wireguard/private-keys.json$
       key_groups:
       - age:
         - *admin_alice
         - *admin_bob
   ```

   Generate age key:
   ```bash
   mkdir -p ~/.config/sops/age
   age-keygen -o ~/.config/sops/age/keys.txt
   ```

   Add your public key to `.sops.yaml`

### 2. Server Discovery & Configuration

1. Create Hetzner Robot credentials file:
   ```bash
   echo '{"hetzner_robot_username": "your-username", "hetzner_robot_password": "your-password"}' | sops -e > secrets/hetzner.json
   ```

2. Generate server configurations:
   ```bash
   # Generate for all servers
   nix run .#generate-server-config

   # Or for specific servers
   nix run .#generate-server-config -- "mycity"
   ```
   This creates `servers.json` with network settings and WireGuard IPs.

### 3. Hardware Setup

1. Activate rescue mode:
   ```bash
   nix run .#activate-rescue-mode -- <server-ip> <hostname>
   ```

2. Generate disk configuration:
   ```bash
   nix run .#generate-disko-config -- <server-ip> <hostname>
   ```

3. Generate hardware configuration:
   ```bash
   nix run .#generate-hardware-config -- <server-ip> <hostname>
   ```

4. Customize Hardware Configuration (if needed):
   For servers with RAID or specific boot requirements:

   ```nix
   boot = {
     initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" ];
     initrd.kernelModules = [ ];
     kernelModules = [ "kvm-intel" ];
     extraModulePackages = [ ];

     # RAID configuration
     swraid.mdadmConf = ''
       MAILADDR nobody@nowhere
     '';

     # Boot loader configuration for multiple drives
     loader = {
       grub = {
         enable = true;
         devices = [ "/dev/nvme0n1" "/dev/nvme1n1" ];
         efiSupport = true;
       };
     };
   };
   ```

### 4. Network Configuration

1. Generate WireGuard keys:
   ```bash
   # For staging environment
   nix run .#generate-wireguard-keys -- staging server1 server2
   
   # For production environment
   nix run .#generate-wireguard-keys -- production server3 server4
   ```

2. Generate WireGuard interface configurations:
   ```bash
   nix run .#generate-wireguard-interface -- staging server1
   nix run .#generate-wireguard-interface -- staging server2
   ```

IP Address Allocation:
- Servers: 172.16.0.1-9 (production), 172.16.0.20-29 (staging)
- Administrators: 172.16.0.10-19
- Future use: 172.16.0.30-254

Network Requirements:
- UDP port 51820 must be open on all peers
- Each peer needs a stable endpoint (domain or IP)
- MTU 1420 is recommended for most setups

### 5. Access Management

1. SSH Key Management:
   Add public keys to `authorized_keys/`:
   ```bash
   # Example: Add user's key
   echo "ssh-ed25519 AAAAC3..." > authorized_keys/user.pub
   ```

2. WireGuard Admin Access:
   ```bash
   nix run .#add-wireguard-admin -- \
     --name alice \
     --endpoint alice.duckdns.org \
     --public-key <alice-pubkey> \
     --private-ip 172.16.0.10
   ```

3. Verify configurations:
   ```bash
   # Check server configs
   cat systems/x86_64-linux/server1/wg0.nix
   
   # Check encrypted private keys
   sops wireguard/private-keys.json
   ```

### 6. Deployment

1. Pre-deployment Checklist:
   - [ ] Hardware configuration generated
   - [ ] Disk configuration created
   - [ ] WireGuard keys generated
   - [ ] Server configuration in servers.json
   - [ ] Network connectivity verified
   - [ ] Backup of existing data (if applicable)

2. Initial Deployment:
   ```bash
   nix run github:nix-community/nixos-anywhere -- --flake .#<hostname> root@<server-ip>
   ```

   After deployment:
   ```bash
   # Wait a minute for the server to finish rebooting
   ssh nix@<server-ip>
   ```

3. Subsequent Updates:
   Add deploy-rs to your flake:
   ```nix
   {
     inputs.deploy-rs.url = "github:serokell/deploy-rs";
   }
   ```

   Deploy updates:
   ```bash
   nix run github:serokell/deploy-rs -- .#<hostname>
   ```

### 7. Maintenance

1. System Updates:
   ```bash
   # Update flake inputs
   nix flake update
   
   # Deploy updates
   nix run github:serokell/deploy-rs -- .#<hostname>
   ```

2. Key Rotation:
   ```bash
   # Generate new WireGuard keys
   nix run .#generate-wireguard-keys -- <environment> <server>
   
   # Update admin keys
   nix run .#add-wireguard-admin -- --name <admin> --update-key
   ```

3. Backup Strategy:
   - Keep encrypted copies of:
     - `wireguard/private-keys.json`
     - `servers.json`
     - Any custom configurations
   - Store backups in a secure location
   - Test restoration procedures regularly

4. Troubleshooting:
   - WireGuard issues: Check `journalctl -u wireguard-wg0`
   - Deployment failures: Verify network and configurations
   - Access issues: Check SSH keys and firewall rules

## Repository Structure

```
.
├── modules/
│   └── base.nix           # Base system configuration
├── scripts/               # Deployment and setup scripts
├── secrets/
│   └── wireguard.json    # WireGuard keys and configurations
└── systems/              # Server-specific configurations
    └── x86_64-linux/
        └── <hostname>/
            ├── disko.nix
            └── hardware-configuration.nix
```

## Development

A development shell with required tools is provided:

```bash
nix develop
```

This gives you access to:
- `netcat` for network operations
- `sops` for secrets management
- `yq` and `jq` for YAML/JSON processing

## License

This project is licensed under the MIT License - see the LICENSE file for
details.
