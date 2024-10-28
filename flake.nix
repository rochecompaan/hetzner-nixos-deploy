{
  description = "Hetzner-specific NixOS deployment scripts and expressions";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
    sops-nix.url = "github:Mic92/sops-nix";
  };

  outputs = { self, nixpkgs, sops-nix }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        system = "${system}";
        config = { allowUnfree = true; };
      };
    in
    {
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
      };

      apps = {
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
      };

      devShell.${system} = pkgs.mkShell {
        buildInputs = [
          pkgs.netcat
          pkgs.sops
          pkgs.yq
        ];
      };
    };
}
