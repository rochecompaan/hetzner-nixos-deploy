{ lib
, pkgs
, config
, networking
, authorizedKeys
, getWireguardPeers
, hostname
, environment
, ...
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

    # Add Hetzner recurisve nameservers
    nameservers = [
      "185.12.64.1" # Hetzner DNS 1
      "185.12.64.2" # Hetzner DNS 2
    ];

    firewall = {
      enable = true;
      # Ports open to the public internet
      allowedTCPPorts = [ 80 443 22 ];

      # ports only open on Wireguard interface
      # Once you are sure that the wireguard network is secure, you can limit
      # port 22 to the wireguard interface

      # interfaces."wg0".allowedTCPPorts = [
      #   22
      # ];

      # Trust all traffic on the Wireguard interface
      trustedInterfaces = [ "wg0" ];
    };
  };

  # Wireguard configuration
  networking.wireguard.interfaces = {
    wg0 = {
      ips = [ "${networking.privateIP}/24" ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets."servers/${environment}/${hostname}/privateKey".path;
      peers = getWireguardPeers config;
    };
  };

  # Secrets configuration - declare secrets for our key and all peer public keys
  sops = {
    defaultSopsFile = ../secrets/wireguard.json;
    secrets = {
      "servers/${environment}/${hostname}/privateKey" = { };
    };
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
    # I'm not sure why this is necessary. I expected it to be auto generated.
    hostKeys = [
      {
        bits = 4096;
        path = "/etc/ssh/ssh_host_rsa_key";
        type = "rsa";
      }
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };

  # Enable nix flakes
  nix = {
    package = pkgs.nixVersions.stable;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
    settings.trusted-users = [ "root" "@wheel" ];
  };

  # System packages
  # System state version
  system.stateVersion = "24.11";

  # Swap configuration
  swapDevices = [{
    device = "/swapfile";
    size = 8196; # Size in MB (8GB)
  }];

  environment.systemPackages = with pkgs; [
    vim
    git
    wireguard-tools
    sops
  ];
}
