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

## Prerequisites

- Nix with flakes enabled
- A Hetzner server
- SOPS for secrets management
- Basic understanding of NixOS configuration

## Usage

### Initial Server Setup

1. **Activate Rescue Mode**

   ```bash
   nix run .#activate-rescue-mode -- <server-ip> <hostname>
   ```

   This script activates rescue mode on your Hetzner server and reboots it. Wait
   for the server to boot into rescue mode before proceeding.

2. **Generate Disk Configuration**

   ```bash
   nix run .#generate-disko-config -- <server-ip> <hostname>
   ```

   Creates a disko configuration file at
   `systems/x86_64-linux/<hostname>/disko.nix` based on your server's hardware.

3. **Generate Hardware Configuration**

   ```bash
   nix run .#generate-hardware-config -- <server-ip> <hostname>
   ```

   Creates a hardware configuration file at
   `systems/x86_64-linux/<hostname>/hardware-configuration.nix`.

### WireGuard Management

1. **Generate WireGuard Keys**

   ```bash
   nix run .#generate-wireguard-keys -- <environment> <server1> [<server2> ...]
   ```

   This command generates private and public key pairs for servers and updates
   `secrets/wireguard.json`.

2. **Add WireGuard Admin**

   ```bash
   nix run .#add-wireguard-admin -- <admin-name> <public-key> [endpoint]
   ```

   Adds an admin to the WireGuard configuration with their public key and
   optional endpoint.

The WireGuard configuration is stored in `secrets/wireguard.json` with the
following structure:

```json
{
  "servers": {
    "<environment>": {
      "<server1>": {
        "privateKey": "yENnAwrNBGQtjvHeK3Xn6lgdDXth9KVPchOuOHRKCUY=",
        "publicKey": "KsQPTEVg8i6sK0sgY1aLdszhzgzr3I/EwMPiP8gt90A="
      }
    }
  },
  "admins": {
    "<admin-name>": {
      "publicKey": "abc123...",
      "endpoint": "username.duckdns.org",
      "privateIP": "172.16.0.1"
    }
  }
}
```

## Integration

To use this repository in your project:

1. Add it as a flake input:

   ```nix
   {
     inputs.hetzner-nixos-deploy.url = "github:your-org/hetzner-nixos-deploy";
   }
   ```

2. Use the provided `mkServer` function to create your server configurations:

   ```nix
   let
     # Define your server configurations
     serverConfigs = {
       "server1" = {
         name = "server1";
         environment = "staging";
         networking = {
           interfaceName = "ens3";
           publicIP = "...";
           privateIP = "...";
           defaultGateway = "...";
         };
         authorizedKeys = [ "ssh-ed25519 ..." ];
         adminNames = [ "alice" "bob" ];
       };
       "server2" = {
         name = "server2";
         environment = "production";
         networking = {
           interfaceName = "ens3";
           publicIP = "...";
           privateIP = "...";
           defaultGateway = "...";
         };
         authorizedKeys = [ "ssh-ed25519 ..." ];
         adminNames = [ "alice" ];
       };
     };
   in {
     # Map server configs to NixOS configurations
     nixosConfigurations = builtins.mapAttrs
       (name: config: nixpkgs.lib.nixosSystem {
         system = "x86_64-linux";
         modules = [
           ./systems/x86_64-linux/${name}/hardware-configuration.nix
           (self.lib.mkServer (config // { inherit serverConfigs; }))
         ];
       })
       serverConfigs;
   }
   ```

   Each server configuration requires:
   - `name`: The hostname of your server
   - `environment`: Environment name (e.g., "staging", "production")
   - `networking`: Network configuration for the server
   - `authorizedKeys`: List of SSH public keys for the `nix` user
   - `adminNames`: Optional list of admin users from wireguard.json to add as WireGuard peers

   The `serverConfigs` map is automatically passed to each server configuration to enable
   WireGuard peer setup between servers.

3. Test building a server configuration:

   ```bash
   nix build .#nixosConfigurations.your-server.config.system.build.toplevel
   ```

   This will output the complete NixOS configuration in JSON format, which can be
   useful for debugging or verifying the configuration before deployment.

### Deploying the Configuration

1. **Initial Deployment with nixos-anywhere**

   After generating the configurations, deploy your NixOS system using nixos-anywhere:

   ```bash
   nix run github:nix-community/nixos-anywhere -- --flake .#<hostname> root@<server-ip>
   ```

   This will perform the initial installation of NixOS on your server according to your configuration.

   After deployment completes, test SSH access to your new server:
   ```bash
   # Wait a minute for the server to finish rebooting
   ssh nix@<server-ip>
   ```

   If you can successfully log in as the `nix` user with your SSH key, the deployment was successful.

2. **Subsequent Updates with deploy-rs**

   For ongoing maintenance and updates, you can use deploy-rs:

   1. First, add deploy-rs to your flake inputs:
      ```nix
      {
        inputs.deploy-rs.url = "github:serokell/deploy-rs";
      }
      ```

   2. Add a deployment configuration to your flake:
      ```nix
      {
        deploy.nodes.<hostname> = {
          hostname = "<server-ip>";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.<hostname>;
          };
        };
      }
      ```

   3. Deploy updates using:
      ```bash
      nix run github:serokell/deploy-rs -- .#<hostname>
      ```

   This method is faster than full reinstalls as it only updates changed components.

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

## System Configuration

The base configuration (`modules/base.nix`) provides:

- Network configuration with WireGuard VPN support
- Firewall configuration (ports 22, 80, 443 open by default)
- SOPS secrets management
- User setup with SSH key authentication
- Passwordless sudo for the `nix` user
- SSH server with secure defaults
- Nix flakes support
- Essential system packages (vim, git, wireguard-tools, sops)

## Development Shell

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
