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
     server = hetzner-nixos-deploy.lib.mkServer {
       name = "your-server";
       environment = "staging";
       networking = {
         interfaceName = "ens3";
         publicIP = "...";
         privateIP = "...";
         defaultGateway = "...";
       };
       authorizedKeys = [ "ssh-ed25519 ..." ];
       # Optional: List of admin names from wireguard.json to include as WireGuard peers
       adminNames = [ "alice" "bob" ];
     };
   in {
     nixosConfigurations.your-server = server;
   }
   ```

   The `adminNames` parameter allows you to specify which admin users from your
   `secrets/wireguard.json` should be added as WireGuard peers to this server.
   These admins must first be added using the `add-wireguard-admin` script.

3. You can preview the generated NixOS configuration for a server:
   ```bash
   nix run .#show-server-config -- <hostname>
   ```

   This will output the complete NixOS configuration in JSON format, which can be
   useful for debugging or verifying the configuration before deployment.

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
