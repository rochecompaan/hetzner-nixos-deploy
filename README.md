# hetzner-nixos-deploy
A collection of modules to deploy Nixos to bare metal servers

## Activate rescue mode

```
nix run .#activate-rescue-mode -- <server-ip> <hostname>
```

## Generate disko configuration

```
nix run .#generate-disko-configuration -- <server-ip> <hostname>
```

## Generate hardware configuration

```
nix run .#generate-hardware-configuration -- <server-ip> <hostname>
```

## Generate wireguards keys

```
nix run .#generate-wireguard-keys -- <server1> <server2> <server2>
```

This will update `secrets/wireguard.json` with the following structure:
```json
{
  "wireguard": {
    "server1": {
      "private": "private_key_here",
      "public": "public_key_here"
    },
    "server2": {
      "private": "private_key_here",
      "public": "public_key_here"
    }
  }
}
```
