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
