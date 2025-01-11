{ self, inputs, ... }:
{
  flake.nixosConfigurations =
    let
      inherit (inputs.nixpkgs.lib) nixosSystem;

      # Get all subdirectories in the hosts directory
      hostNames = with builtins;
        attrNames (filterAttrs (n: v: v == "directory") 
          (readDir ./.));

      specialArgs = {
        inherit inputs self;
      };

      mkHost =
        hostname:
        nixosSystem {
          inherit specialArgs;
          modules = [
            inputs.disko.nixosmodules.disko
            inputs.sops-nix.nixosmodules.sops
            ./${hostname}
          ];
          system = "x86_64-linux";
        };
    in
    builtins.listToAttrs (
      map (name: {
        inherit name;
        value = mkHost name;
      }) hostNames
    );
}
