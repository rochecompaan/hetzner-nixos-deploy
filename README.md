# Hetzner Nixos Deploy

A collection of scripts and modules that wrap great existing tools like `NixOS
Anywhere` and `deploy-rs`, adding the necessary glue to make deployment and
maintenance of bare metal servers on Hetzner easier. This repository provides
reusable components that can be integrated into project-specific NixOS
configurations.

## Features

- Easy activation of rescue mode for Hetzner servers
- Hardware configuration generation
- Disk partitioning configuration using disko
- Initial deployment with
  [NixOS Anywhere](https://github.com/nix-community/nixos-anywhere/)
- Updates with [deploy-rs](https://github.com/serokell/deploy-rs)
- WireGuard key management and peer configuration
- Base system configuration including:
  - Network setup with WireGuard VPN
  - SSH server configuration
  - Basic security settings
  - User management
  - Common system packages

## Quick Start Summary

1. **Initial Setup**

   - Create a project-specific flake
   - Configure SOPS encryption
   - Set up Hetzner Robot credentials

2. **Server Discovery**

   - Generate a nix config for each server using the Heztner Robot API.
   - Configure network settings automatically

3. **Hardware Setup**

   - Boot server into rescue mode
   - Generate disk (disko) configuration
   - Generate hardware configuration

4. **Network Setup**

   - Configure SSH access with project keys
   - Generate WireGuard keys for all servers
   - Set up WireGuard mesh network

5. **Deployment**
   - Initial deployment with nixos-anywhere
   - Subsequent updates with deploy-rs

For detailed instructions, follow the setup phases below.

## Setup Phases

### 1. Initial Setup

1. Prerequisites

   - Nix with flakes enabled
   - A Hetzner server
   - SOPS for secrets management
   - Basic understanding of NixOS configuration

2. Create Project Flake

   Create a new flake.nix in your project directory:

   ```nix
   {
     description = "myproject description";

     inputs = {
       nixpkgs.url = "github:NixOS/nixpkgs";
       flake-parts.url = "github:hercules-ci/flake-parts";
       disko.url = "github:nix-community/disko";
       sops-nix.url = "github:Mic92/sops-nix";
       hetzner-deploy-scripts.url = "github:rochecompaan/hetzner-nixos-deploy";
     };

     outputs =
       inputs:
       inputs.flake-parts.lib.mkFlake { inherit inputs; } {
         systems = [ "x86_64-linux" ];

         perSystem =
           { config, pkgs, ... }:
           {
             devShells.default = pkgs.mkShell {
               buildInputs = with pkgs; [
                 # your packages here
               ] ++ (builtins.attrValues inputs.hetzner-deploy-scripts.packages);
             };
           };
       };
   }
   ```

   This flake:

   - Imports the hetzner-nixos-deploy scripts as a dependency
   - Makes all scripts available in your development shell
   - Allows you to add your own project-specific packages

   Enter the development shell:

   ```bash
   nix develop
   ```

   All hetzner-nixos-deploy scripts will be available in your PATH.

   You can use [direnv](https://direnv.net/) to automatically enter you
   development shell when changing into your project directory.

   To automatically create the dev shell, you need a `.envrc` file in your
   project with `use flake`, e.g.:

   ```bash
   #!/usr/bin/env bash

   if type nix-shell >/dev/null 2>&1; then
       use flake
   fi
   ```

3. SOPS Configuration

   Create a `.sops.yaml` file in your project root to configure SOPS encryption:

   ```yaml
   # .sops.yaml
   keys:
     - &admin_alice age1... # Replace with your age public key
     - &admin_bob age1... # Add more team members as needed
   creation_rules:
     - path_regex: secrets/[^/]+\.(yaml|json|env|ini)$
       key_groups:
         - age:
             - *admin_alice
             - *admin_bob
   ```

   Generate an age key pair for encrypting/decrypting secrets:

   ```bash
   # Create directory for age keys
   mkdir -p ~/.config/sops/age

   # Generate new age key pair
   age-keygen -o ~/.config/sops/age/keys.txt

   # View your public key to add to .sops.yaml
   age-keygen -y ~/.config/sops/age/keys.txt
   ```

   The age key pair is used by SOPS to encrypt/decrypt secrets. The public key
   goes in `.sops.yaml` while the private key stays in
   `~/.config/sops/age/keys.txt`.

   For more details on using SOPS with NixOS, see the
   [sops-nix documentation](https://github.com/Mic92/sops-nix).

### 2. Server Discovery & Configuration

1. Create Hetzner Robot credentials file:

   ```bash
   echo '{"hetzner_robot_username": "your-username", "hetzner_robot_password": "your-password"}' | sops -e > secrets/hetzner.json
   ```

2. Generate server configurations using the Hetzner Robot API:

   ```bash
   # Generate for all servers
   generate-server-config

   # Filter servers by name pattern
   generate-server-config "myproject"

   # Overwrite existing configurations
   generate-server-config --overwrite "myproject"

   # Specify custom WireGuard subnet
   generate-server-config --subnet "10.0.0.0/16" "myproject"
   ```

   This will create a NixOS configuration for each server in the `hosts/`
   directory. The script:

   - Fetches server details from the Hetzner Robot API
   - Creates a directory structure for each server
   - Generates network configuration based on server IP information
   - Assigns sequential WireGuard IPs in the 172.16.0.0/24 range
   - Sets up default interface names and gateway IPs
   - Generate RSA and ED25519 SSH host keys for each server
   - Convert the public ED25519 keys to age format using ssh-to-age
   - Output the age public keys to add to .sops.yaml

   Here is an example of a `default.nix` module generated by the script:

   ```nix
   {
     imports = [
       ./hardware-configuration.nix
       ./disko.nix
       ./wg0.nix
       ../../modules/base.nix
     ];

     networking = {
       hostName = "server1";
       useDHCP = false;

       # Primary network interface
       interfaces.enp0s31f6 = {
         ipv4.addresses = [{
           address = "123.45.67.89";
           prefixLength = 24;
         }];
       };

       defaultGateway = "123.45.67.1";
     };
   }
   ```

   The script will automatically download `modules/base.nix` if it doesn't
   exist. You can customize both the generated configuration and
   `modules/base.nix` as needed for your specific requirements.

3. Add the generated age keys to `.sops.yaml`:

   ```yaml
   # .sops.yaml
   keys:
     - &admin_alice age1... # Replace with your age public key
     - &admin_bob age1... # Add more team members as needed
     - &server_server1 age1wy7nmyfsnkfzsl2txt0z4anqu56d6p4a4v0zan0357a5kv36zevqzeesnp
     - &server_server2 age1rgffpespcyjn0d8jglk7km9kfrfhdyev6camd3rck6pn8y47ze4sug23v3
   creation_rules:
     - path_regex: secrets/[^/]+\.(yaml|json|env|ini)$
       key_groups:
         - age:
             - *admin_alice
             - *admin_bob
             - *server_server2
             - *server_server2
   ```

   Make sure to run `sops updatekeys secrets/wireguard.json` to re-encrypt
   secrets.

### 3. Hardware Setup

1. Activate rescue mode:

   ```bash
   # Just activate rescue mode
   activate-rescue-mode <server-ip>

   # Or activate rescue mode and boot into NixOS installer
   activate-rescue-mode --boot-nixos <server-ip>
   ```

2. Generate disk configuration:

   ```bash
   generate-disko-config <server-ip> <hostname>
   ```

3. Generate hardware configuration:

   ```bash
   generate-hardware-config <server-ip> <hostname>
   ```

You can also run `setup-servers` that will run the above scripts for all hosts
automatically.

### 4. Network Access Setup

The server configuration process handles both SSH and WireGuard setup
automatically.

1. SSH Access Configuration:

   SSH keys are used for direct server access and are managed through the
   `authorized_keys/` directory. The base system configuration
   (`modules/base.nix`) automatically adds these keys to the `nix` user's
   authorized keys.

   a. Using an Existing SSH Key:

   ```bash
   # Copy your existing public key
   cp ~/.ssh/id_ed25519.pub authorized_keys/alice.pub
   ```

   b. Generating a New Project-Specific Key:

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

2. WireGuard Network Setup:

   The `generate-server-config` script automatically handles WireGuard
   configuration during server setup:

   - Generates unique WireGuard keypairs for each server
   - Assigns sequential IPs in the 172.16.0.0/16 range
   - Creates `wg0.nix` modules in each server's directory
   - Maintains a shared peers configuration in `modules/wireguard-peers.nix`
   - Encrypts private keys in `secrets/wireguard.json`

   The generated configurations enable secure communication between servers and
   administrators.

3. Adding WireGuard Admin Access:

   ```bash
   # Generate a new WireGuard key pair
   wg genkey | tee privatekey | wg pubkey > publickey

   # View your public key
   cat publickey
   ```

4. Add Admin to WireGuard Network:

   ```bash
   add-wireguard-admin \
     --name alice \
     --endpoint alice.duckdns.org \
     --public-key "$(cat publickey)" \
     --private-ip 172.16.0.10
   ```

5. Configure Local WireGuard Client:

   ```bash
   # Generate client configuration
   generate-wireguard-config \
     --private-key "$(cat privatekey)" \
     --address 172.16.0.10/24 > wireguard/wg0.conf

   # Start WireGuard interface
   sudo wg-quick up ./wireguard/wg0.conf
   ```

### 6. Deployment

1. Pre-deployment Checklist:

   - [ ] Hardware configuration generated
   - [ ] Disk configuration created
   - [ ] Wireguard configuration generated
   - [ ] Network connectivity verified

2. Initial Deployment:

   ```bash
   deploy-nixos <hostname>
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
   deploy .#<hostname>
   ```

### 7. Maintenance

1. System Updates:

   ```bash
   # Update flake inputs
   nix flake update

   # Deploy updates
   deploy .#<hostname>
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
     - `secrets/wireguard.json`
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
│   └── base.nix                       # Base system configuration
├── secrets/
│   ├── hetnzer.json                   # Hetzner username and password
│   ├── server-private-ssh-keys.json   # Server private ssh keys
│   └── wireguard.json                 # WireGuard keys and configurations
└── hosts/                             # Server-specific configurations
    ├── default.nix                    # Generates host nixos configurations
    └── <hostname>/
            ├── default.nix
            ├── disko.nix
            ├── hardware-configuration.nix
            └── wg0.nix
```

## License

This project is licensed under the MIT License - see the LICENSE file for
details.
