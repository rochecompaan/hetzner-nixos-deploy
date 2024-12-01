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
        wireguard = import ./lib/wireguard.nix { inherit (pkgs) lib; };
      };

      packages = {
        wireguard-lib = pkgs.writeTextFile {
          name = "wireguard-lib";
          text = builtins.readFile ./lib/wireguard.nix;
          destination = "/lib/wireguard.nix";
        };

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
