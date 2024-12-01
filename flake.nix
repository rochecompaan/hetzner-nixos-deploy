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
    in
    rec {
      lib = {
        # Function to create a server configuration
        mkServer =
          { name
          , environment
          , networking
          , authorizedKeys
          }:
          { config, lib, pkgs, ... }:
          {
            nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

            _module.args = {
              inherit networking authorizedKeys environment;
              hostname = name;
            };

            imports = [
              # Standard system configuration
              disko.nixosModules.disko
              sops-nix.nixosModules.sops
              ./systems/x86_64-linux/${name}/hardware-configuration.nix
              ./systems/x86_64-linux/${name}/disko.nix
              ./systems/x86_64-linux/${name}/wg0.nix
              ./modules/base.nix
            ];
          };
      };

      packages = {
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

        generate-wireguard-config = pkgs.writeShellApplication {
          name = "generate-wireguard-config";
          runtimeInputs = with pkgs; [
            jq
          ];
          text = builtins.readFile ./scripts/generate-wireguard-config.sh;
        };

        generate-wireguard-interface = pkgs.writeShellApplication {
          name = "generate-wireguard-interface";
          runtimeInputs = with pkgs; [
            jq
          ];
          text = builtins.readFile ./scripts/generate-wireguard-interface.sh;
        };

        generate-server-config = pkgs.writeShellApplication {
          name = "generate-server-config";
          runtimeInputs = with pkgs; [
            curl
            jq
          ];
          text = builtins.readFile ./scripts/generate-server-config.sh;
        };

        deploy-nixos = pkgs.writeShellApplication {
          name = "deploy-nixos";
          runtimeInputs = with pkgs; [
            nixos-anywhere
            jq
            sops
          ];
          text = builtins.readFile ./scripts/deploy-nixos.sh;
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

      apps = builtins.mapAttrs
        (name: pkg: {
          type = "app";
          program = "${pkg}/bin/${name}";
        })
        packages;

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          netcat
          sops
          yq
          jq
          ssh-to-age
          stdenv.cc.cc.lib
          curl
          wireguard-tools
        ] ++ builtins.attrValues self.packages;
      };
    };
}
