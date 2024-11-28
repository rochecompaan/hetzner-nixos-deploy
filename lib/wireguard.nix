{ lib }:
let
  # Format a peer as a nix expression string
  formatPeer = peer: ''
    {
      # ${peer.name}
      name = "${peer.name}";
      publicKey = "${peer.publicKey}";
      allowedIPs = [ "${builtins.head peer.allowedIPs}" ];
      endpoint = "${peer.endpoint}";
      persistentKeepalive = ${toString peer.persistentKeepalive};
    }'';

  # Format a peer for WireGuard config file
  formatPeerConfig = peer: ''
    [Peer]
    # ${peer.name}
    PublicKey = ${peer.publicKey}
    AllowedIPs = ${builtins.head peer.allowedIPs}
    Endpoint = ${peer.endpoint}
    PersistentKeepalive = 25
  '';

  # Update peers list and generate formatted module
  updatePeers = { existingPeers ? [ ], newPeer }:
    let
      # Filter out existing peer with same name if it exists
      filteredPeers = builtins.filter (p: p.name != newPeer.name) existingPeers;
      # Add new peer to the list
      updatedPeers = filteredPeers ++ [ newPeer ];
      # Format the complete peers module
      formatPeersModule = peers: ''
        {
          peers = [
            ${lib.concatStringsSep "" (map formatPeer peers)}
          ];
        }
      '';
    in
    {
      peers = updatedPeers;
      formatted = formatPeersModule updatedPeers;
    };

in
{
  # Update admin peer configuration
  updateAdminPeer = { name, publicKey, privateIP, endpoint }:
    let
      existingPeers =
        if builtins.pathExists ../modules/wireguard-peers.nix
        then (import ../modules/wireguard-peers.nix).peers
        else [ ];
      result = updatePeers {
        inherit existingPeers;
        newPeer = {
          inherit name publicKey endpoint;
          allowedIPs = [ "${privateIP}/32" ];
          persistentKeepalive = 25;
        };
      };
    in
    result.formatted;

  # Generate WireGuard config for admin
  generateConfig = { privateKey, address, peers }: ''
    [Interface]
    Address = ${address}/24
    MTU = 1200
    PrivateKey = ${privateKey}
    ListenPort = 51820

    # Peers
    ${lib.concatMapStrings formatPeerConfig 
      (lib.filter
        (peer: peer.allowedIPs != [ "${address}/32" ])
        peers)}
  '';
}
