{ lib
, pkgs
, config
, networking
, hostname
, environment
, ...
}:

let
  # Function to read all files from authorized_keys directory
  readAuthorizedKeys = let
    keyDir = ../authorized_keys;
    # Read all files in the directory
    fileNames = builtins.attrNames (builtins.readDir keyDir);
    # Read content of each file
    readKey = file: builtins.readFile (keyDir + "/${file}");
  in
    # Map over all files and read their contents
    map readKey fileNames;
in
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

  # User configuration
  users.users.nix = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = readAuthorizedKeys;
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
