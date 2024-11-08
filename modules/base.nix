{ lib, pkgs, config, ... }:

{ networking
, authorizedKeys
, getWireguardPeers
, hostname
}:

{
  # Networking configuration
  networking = {
    hostName = hostname;
    useDHCP = false;
    interfaces.${networking.interfaceName} = {
      ipv4.addresses = [{
        address = networking.publicIP;
        prefixLength = 24;
      }];
    };
    defaultGateway = networking.defaultGateway;
    firewall = {
      enable = true;
      allowedTCPPorts = [ 80 443 22 ];
      trustedInterfaces = [ "wg0" ];
    };
  };

  # Wireguard configuration
  networking.wireguard.interfaces = {
    wg0 = {
      ips = [ "${networking.privateIP}/24" ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets."wireguard/${hostname}/privateKey".path;
      peers = getWireguardPeers config;
    };
  };

  # Secrets configuration - declare secrets for our key and all peer public keys
  sops = {
    secrets = {
      "wireguard/${hostname}/privateKey" = {
        sopsFile = ./secrets/wireguard.json;
      };
      "wireguard/${hostname}/publicKey" = {
        sopsFile = ./secrets/wireguard.json;
      };
    } // (builtins.listToAttrs (map (peer: {
      name = "wireguard/${peer.name}/publicKey";
      value = { sopsFile = ./secrets/wireguard.json; };
    }) (getWireguardPeers null)));  # Pass null since we just need the peer names here
  };

  # User configuration
  users.users.nix = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = authorizedKeys;
  };

  # Sudo configuration
  security.sudo.extraRules = [{
    users = [ "nix" ];
    commands = [{
      command = "ALL";
      options = [ "NOPASSWD" ];
    }];
  }];

  # SSH server configuration
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # Enable nix flakes
  nix = {
    package = pkgs.nixFlakes;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  # System packages
  environment.systemPackages = with pkgs; [
    vim
    git
    wireguard-tools
    sops
  ];
}
