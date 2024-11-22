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

2. Generate the `servers.json` file using the Hetzner Robot API:
   ```bash
   nix run .#generate-server-config
   ```

   You can pass any jq pattern filter to filter the list of servers. Adding
   `myproject` will filter to all servers starting with "myproject".
   ```bash
   nix run .#generate-server-config -- "myproject"
   ```

   This will create a `servers.json` file with all your registered servers from
   Hetzner Robot. The script:

   - Fetches server details from the Hetzner Robot API
   - Configures network settings based on server IP information
   - Assigns sequential WireGuard IPs in the 172.16.0.0/24 range
   - Sets up default interface names and gateway IPs

   The generated file will look like:
   ```json
   {
     "servers": {
       #TODO: environment is hardcoded in the script
       "staging": {
         "server1": {
           "name": "server1",
           "networking": {
             "interfaceName": "enp0s31f6",
             "publicIP": "123.45.67.89",
             "defaultGateway": "123.45.67.1",
             "wg0": {
               "privateIP": "172.16.0.1"
             }
           }
         }
       }
     }
   }
   ```

   You can then customize this generated configuration as needed.

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

### 4. SSH Access

SSH keys are used for direct server access and are managed through the
`authorized_keys/` directory. The base system configuration (`modules/base.nix`)
automatically adds these keys to the `nix` user's authorized keys. Use your
existing key or generate a project specific one.

1. Using an Existing SSH Key:
   ```bash
   # Copy your existing public key
   cp ~/.ssh/id_ed25519.pub authorized_keys/alice.pub
   ```

2. Generating a New Project-Specific Key:
   ```bash
   # Generate a new ED25519 key pair
   ssh-keygen -t ed25519 -C "alice@project" -f ~/.ssh/project_ed25519
   
   # Copy the public key to authorized_keys
   cp ~/.ssh/project_ed25519.pub authorized_keys/alice.pub
   
   # Update SSH config to use the project key
   cat >> ~/.ssh/config << EOF
   
   # Project-specific configuration
   Host <publicip>
     IdentityFile ~/.ssh/project_ed25519
     User nix
   EOF
   ```

### 5. Wireguard Network Access

WireGuard provides secure network access between servers and administrators.
Each peer (server or admin) needs a unique key pair and IP address. 

1. Generate wireguard keys for servers listed in `servers.json`.
   ```bash
   nix run .#generate-wireguard-keys
   ```

   Server private keys are stored in `secrets/wireguard.json`.

   Public keys are added to `servers.json`. The wireguard interface section
   for each server will be updated with the following peer settings:
   ```
             "wg0": {
               "privateIP": "172.16.0.1"
               "publicKey": <generated public key>,
               "endpoint": <same as networking.publicIP>,
             }
   ```

2. Generate Admin WireGuard Keys:
   ```bash
   # Generate a new WireGuard key pair
   wg genkey | tee privatekey | wg pubkey > publickey
   
   # View your public key
   cat publickey
   ```

3. Add Admin to WireGuard Network:
   ```bash
   nix run .#add-wireguard-admin -- \
     --name alice \
     --endpoint alice.duckdns.org \
     --public-key "$(cat publickey)" \
     --private-ip 172.16.0.10
   ```

4. Generate WireGuard interface configurations:
   ```bash
   nix run .#generate-wireguard-interface
   ```

   This script creates a wireguard module for each server listed in
   `servers.json` in `systems/x86_64-linux/<servername>/wg0.nix` that looks like
   this:
   ```nix
      {
        networking.wg-quick.interfaces.wg0 = {
          address = [ "172.16.0.1/24" ];
          listenPort = 51820;
          privateKeyFile = config.sops.secrets."servers/${environment}/${hostname}/privateKey".path;

          peers = [
            { # server1
              publicKey = "<generated public key>";
              allowedIPs = [ "172.16.0.2/32" ];
              endpoint = "<same as networking.publicIP for given server>";
              persistentKeepalive = 25;
            }
            ...
            { # alice admin
              publicKey = "<generated public key>";
              allowedIPs = [ "<same as private ip arg in add-wireguard-admin script>" ];
              endpoint = "<same as endpoint in add-wireguard-admin script>";
              persistentKeepalive = 25;
            }
         ];
         ...
        };
      }
   ```

3. Configure Local WireGuard Client:
   ```bash
   # Generate client configuration
   nix run .#generate-wireguard-config -- \
     --private-key "$(cat privatekey)" \
     --address 172.16.0.10/24 > wireguard/wg0.conf
   
   # Start WireGuard interface
   sudo wg-quick up ./wireguard/wg0.conf
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
├── secrets/
│   └── wireguard.json    # WireGuard keys and configurations
└── systems/              # Server-specific configurations
    └── x86_64-linux/
        └── <hostname>/
            ├── disko.nix
            ├── hardware-configuration.nix
            └── wg0.nix
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
