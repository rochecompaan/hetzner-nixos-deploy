{
  description = "Hetzner-specific NixOS deployment scripts and expressions";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
    sops-nix.url = "github:Mic92/sops-nix";
    disko.url = "github:nix-community/disko";
  };

  outputs = { self, nixpkgs, sops-nix, disko }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        system = "${system}";
        config = { allowUnfree = true; };
      };

      # Function to read and parse the WireGuard secrets file
      getWireguardSecrets = environment: let
        secretsFile = ./secrets/wireguard.json;
        secretsContent = builtins.readFile secretsFile;
        secrets = builtins.fromJSON secretsContent;
      in
        secrets.servers.${environment} or {};

      # Function to generate WireGuard peer configurations
      generateWireguardPeers = environment: serverName: let
        secrets = getWireguardSecrets environment;
        servers = builtins.removeAttrs secrets [ serverName ];
        # Add admin peers to the configuration
        adminPeers = (builtins.fromJSON (builtins.readFile ./secrets/wireguard.json)).admins or {};
        allPeers = servers // adminPeers;
      in
        builtins.mapAttrs
          (name: value: {
            publicKey = value.publicKey;
            allowedIPs = [ "10.0.0.0/24" ]; # Adjust IP range as needed
            endpoint = value.endpoint or null;
          })
          allPeers;
    in
    {
      lib = {
        # Function to create a server configuration
        mkServer = { name, environment, networking, authorizedKeys }: nixpkgs.lib.nixosSystem {
          inherit system;

          modules = [
            # Include instalation-specific module when installing
            ({ config, ... }: {
              nixpkgs.hostPlatform = system;
            })
            
            # Standard system configuration
            disko.nixosModules.disko
            sops-nix.nixosModules.sops
            ./systems/${system}/${name}/hardware-configuration.nix
            ./systems/${system}/${name}/disko.nix
            (import ./modules/base.nix)
            {
              _module.args = {
                inherit authorizedKeys;
                hostname = name;
                inherit networking;
                wireguardPeers = generateWireguardPeers environment name;
              };
            }
          ];
        };
      };

      packages.x86_64-linux = {
        activate-rescue-mode = pkgs.writeShellApplication {
          name = "activate-rescue-mode";
          runtimeInputs = with pkgs; [
            curl
            netcat
            sops-nix
          ];
          text = builtins.readFile ./scripts/activate-rescue-mode.sh;
        };

        generate-disko-config = pkgs.writeShellApplication {
          name = "generate-disko-config";
          runtimeInputs = with pkgs; [
            curl
            yq
            sops-nix
          ];
          text = builtins.readFile ./scripts/generate-disko-config.sh;
        };

        generate-hardware-config = pkgs.writeShellApplication {
          name = "generate-hardware-config";
          runtimeInputs = with pkgs; [
            curl
            sops-nix
          ];
          text = builtins.readFile ./scripts/generate-hardware-config.sh;
        };

        generate-wireguard-keys = pkgs.writeShellApplication {
          name = "generate-wireguard-keys";
          runtimeInputs = with pkgs; [
            jq
            sops
            wireguard-tools
          ];
          text = builtins.readFile ./scripts/generate-wireguard-keys.sh;
        };

        add-wireguard-admin = pkgs.writeShellApplication {
          name = "add-wireguard-admin";
          runtimeInputs = with pkgs; [
            jq
            sops
          ];
          text = builtins.readFile ./scripts/add-wireguard-admin.sh;
        };
      };

      apps.x86_64-linux = {
        activate-rescue-mode = {
          type = "app";
          program = "${self.packages.x86_64-linux.activate-rescue-mode}/bin/activate-rescue-mode";
        };

        generate-disko-config = {
          type = "app";
          program = "${self.packages.x86_64-linux.generate-disko-config}/bin/generate-disko-config";
        };

        generate-hardware-config = {
          type = "app";
          program = "${self.packages.x86_64-linux.generate-hardware-config}/bin/generate-hardware-config";
        };

        generate-wireguard-keys = {
          type = "app";
          program = "${self.packages.x86_64-linux.generate-wireguard-keys}/bin/generate-wireguard-keys";
        };

        add-wireguard-admin = {
          type = "app";
          program = "${self.packages.x86_64-linux.add-wireguard-admin}/bin/add-wireguard-admin";
        };
      };

      devShell.${system} = pkgs.mkShell {
        buildInputs = [
          pkgs.netcat
          pkgs.sops
          pkgs.yq
          pkgs.jq
        ];
      };
    };
}
