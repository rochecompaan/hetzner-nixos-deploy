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

The following scripts help set up and manage a WireGuard private network that
enables secure communication between servers and allows administrators to
securely access and manage the servers. The network uses private IP addresses in
the 172.16.0.0/24 range, with servers and administrators each assigned unique
addresses.

1. **Generate WireGuard Keys**

   ```bash
   nix run .#generate-wireguard-keys -- <environment> <server1> [<server2> ...]
   ```

   This command generates private and public key pairs for servers and updates:
   - `wireguard/private-keys.json` (encrypted with SOPS)
   - `wireguard/peers.json` (public keys only)

2. **Add WireGuard Admin**

   ```bash
   nix run .#add-wireguard-admin -- --name NAME --endpoint ENDPOINT --public-key PUBLIC_KEY --private-ip PRIVATE_IP
   ```

   Adds or updates an admin in the WireGuard configuration with their public key, endpoint, and private IP.
   The script validates the input and checks for duplicate IPs and endpoints.

3. **Generate WireGuard Config**

   ```bash
   nix run .#generate-wireguard-config -- --private-key KEY --address IP
   ```

   Generates a WireGuard configuration file (`wireguard/wg0.conf`) for a peer using their private key
   and IP address. The configuration includes all servers and admins from peers.json as peers.

The WireGuard configuration is stored in two files:

`wireguard/private-keys.json` (encrypted):
```json
{
  "servers": {
    "<environment>": {
      "<server1>": {
        "privateKey": "yENnAwrNBGQtjvHeK3Xn6lgdDXth9KVPchOuOHRKCUY="
      }
    }
  }
}
```

`wireguard/peers.json`:
```json
{
  "servers": {
    "<environment>": {
      "<server1>": {
        "publicKey": "KsQPTEVg8i6sK0sgY1aLdszhzgzr3I/EwMPiP8gt90A="
      }
    }
  },
  "admins": {
    "<admin-name>": {
      "publicKey": "abc123...",
      "endpoint": "username.duckdns.org",
      "privateIP": "172.16.0.2"
    }
  }
}
```

The generated WireGuard config (`wg0.conf`) will look like:
```ini
[Interface]
Address = 172.16.0.201/24
MTU = 1200
PrivateKey = 1111111111I6TxNdsBfyZJQYRNenVMoYUqrwaulUrVc=
ListenPort = 51820

# Peers within the group
[Peer]
PublicKey = VOP13f3YGm1JoSCZuqsr0kZ83OkFQEpKmBtr0Fp2mVc=
AllowedIPs = 172.16.0.101/32
Endpoint = 178.63.123.200:51820
PersistentKeepalive = 25
```

## Integration

To use this repository in your project:

1. Add it as a flake input:

   ```nix
   {
     inputs.hetzner-nixos-deploy.url = "github:your-org/hetzner-nixos-deploy";
   }
   ```

2. Create a `servers.json` file to define your server configurations:

   ```json
   {
     "servers": {
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
           },
           "authorizedKeys": [
             "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..."
           ]
         }
       },
       "production": {
         "server2": {
           "name": "server2", 
           "networking": {
             "interfaceName": "enp0s31f6",
             "publicIP": "98.76.54.32",
             "defaultGateway": "98.76.54.1",
             "wg0": {
               "privateIP": "172.16.0.2"
             }
           },
           "authorizedKeys": [
             "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..."
           ]
         }
       }
     }
   }
   ```

   Each server configuration requires:
   - `name`: The hostname of your server
   - `networking`: Network configuration including interface name, IPs and gateway
   - `authorizedKeys`: List of SSH public keys for the `nix` user

   The server configurations are organized by environment (staging/production).
   The WireGuard peer configuration is automatically read from `wireguard/peers.json`,
   which contains both server and admin peer information.

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
