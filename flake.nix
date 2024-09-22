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
            sops-nix
          ];
          text = builtins.readFile ./scripts/activate-rescue-mode.sh;
        };

        generate-hardware-config = pkgs.writeShellApplication {
          name = "generate-hardware-config";
          runtimeInputs = with pkgs; [
            curl
            jq
            sops-nix
          ];
          text = builtins.readFile ./scripts/generate-hardware-config.sh;
        };
      };

      apps = {
        activate-rescue-mode = {
          type = "app";
          program = "${self.packages.x86_64-linux.activate-rescue-mode}/bin/activate-rescue-mode";
        };

        generate-hardware-config = {
          type = "app";
          program = "${self.packages.x86_64-linux.generate-hardware-config}/bin/generate-hardware-config";
        };
      };

      devShell.${system} = pkgs.mkShell {
        buildInputs = [
          pkgs.yq
          pkgs.sops
        ];
      };
    };
}
