{ self, config, inputs, lib, ... }:
{
  flake = {
    nixosConfigurations =
      let
        inherit (inputs.nixpkgs.lib) nixosSystem;

        # Get all subdirectories in the hosts directory
        hostNames = with builtins;
          attrNames (lib.attrsets.filterAttrs (n: v: v == "directory") 
            (readDir ./.));

        specialArgs = {
          inherit inputs self;
        };

        mkHost =
          hostname:
          nixosSystem {
            inherit specialArgs;
            modules = [
              inputs.disko.nixosModules.disko
              inputs.sops-nix.nixosModules.sops
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

    deploy.nodes =
      let
        # Get all subdirectories in the hosts directory
        hostNames = with builtins;
          attrNames (lib.attrsets.filterAttrs (n: v: v == "directory") 
            (readDir ./.));
            
        # Function to get IP from host's network interface config
        getHostIP = hostname:
          let
            hostConfig = (import ./${hostname}/default.nix { inherit self config lib; }).networking;
            # Get the first interface that has IPv4 addresses configured
            interface = lib.head (lib.attrNames 
              (lib.filterAttrs 
                (name: value: value.ipv4.addresses != []) 
                hostConfig.interfaces
              ));
          in
            # Get the address from the first IPv4 configuration
            (lib.head hostConfig.interfaces.${interface}.ipv4.addresses).address;

        mkDeployNode = hostname: {
          name = hostname;
          value = {
            hostname = getHostIP hostname;
            profiles.system = {
              user = "root";
              sshUser = "nix";
              path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.${hostname};
            };
          };
        };
      in
      builtins.listToAttrs (map mkDeployNode hostNames);
  };
}
