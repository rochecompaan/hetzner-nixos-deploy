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
    {
      lib = {
        # Function to create a server configuration
        mkServer =
          { name
          , environment
          , networking
          , authorizedKeys
          , servers
          , adminNames ? [ ] # List of admin names to include from wireguard.json
          }:
          { config, lib, pkgs, ... }:
          let
            wireguardConfig = builtins.fromJSON (builtins.readFile ./secrets/wireguard.json);
            adminPeers = map
              (adminName: {
                name = adminName;
                publicKey = wireguardConfig.admins.${adminName}.publicKey;
                endpoint = wireguardConfig.admins.${adminName}.endpoint;
                privateIP = wireguardConfig.admins.${adminName}.privateIP;
              })
              adminNames;
          in
          {
            nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

            _module.args = {
              inherit networking authorizedKeys environment;
              hostname = name;
              getWireguardPeers = config:
                # Generate server peers
                let
                  serverPeers = nixpkgs.lib.mapAttrsToList
                    (peerName: peerCfg: {
                      name = peerName;
                      publicKey = wireguardConfig.servers.${environment}.${peerName}.publicKey;
                      allowedIPs = [ "${peerCfg.networking.privateIP}/32" ];
                      endpoint = "${peerCfg.networking.publicIP}:51820";
                      persistentKeepalive = 25;
                    })
                    (nixpkgs.lib.filterAttrs (peerName: _: peerName != name) serverConfigs);

                  # Generate admin peers
                  adminPeersList = map
                    (adminPeer: {
                      name = adminPeer.name;
                      publicKey = adminPeer.publicKey;
                      allowedIPs = [ "${adminPeer.privateIP}/32" ];
                      endpoint = adminPeer.endpoint;
                      persistentKeepalive = 25;
                    })
                    adminPeers;
                in
                serverPeers ++ adminPeersList;
            };

            imports = [
              # Standard system configuration
              disko.nixosModules.disko
              sops-nix.nixosModules.sops
              ./systems/x86_64-linux/${name}/disko.nix
              ./modules/base.nix
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

        show-server-config = pkgs.writeShellApplication {
          name = "show-server-config";
          runtimeInputs = with pkgs; [
            jq
          ];
          text = builtins.readFile ./scripts/show-server-config.sh;
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

        show-server-config = {
          type = "app";
          program = "${self.packages.x86_64-linux.show-server-config}/bin/show-server-config";
        };
      };

      devShell.${system} = pkgs.mkShell {
        buildInputs = with pkgs; [
          netcat
          sops
          yq
          jq
          stdenv.cc.cc.lib
        ];
        shellHook = ''
          VENV_DIR="$(pwd)/.venv"
          if [ -d "$VENV_DIR" ]; then
            echo "Skipping venv creation, '$VENV_DIR' already exists"
          else
            echo "Creating new venv environment in path: '$VENV_DIR'"
            python -m venv "$VENV_DIR"
          fi

          echo "Activating venv environment"
          source "$VENV_DIR/bin/activate"
        '';
      };
    };
}
