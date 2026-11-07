{
  pkgs,
  lib,
  osConfig,
  ...
}: let
  # ssh-vpn: ssh with its connection carried through the host's VPN exit
  # (modules/services/vpn-exit.nix) by HTTP CONNECT on the exit's proxy. If the
  # exit is down the connection fails; it never goes out directly. Present
  # where the exit publishes its proxy and nowhere else. GitHub's SSH is also
  # on ssh.github.com:443 for proxies that only allow 443.
  exit = osConfig.services.vpn-exit or {};
  enabled = (exit.enable or false) && (exit.httpProxy.enable or false);
  port = toString (exit.httpProxy.port or 8888);

  sshVpn = pkgs.writeShellScriptBin "ssh-vpn" ''
    exec ${pkgs.openssh}/bin/ssh \
      -o "ProxyCommand=${pkgs.netcat-openbsd}/bin/nc -X connect -x 127.0.0.1:${port} %h %p" \
      "$@"
  '';
in {
  config = lib.mkIf enabled {
    home.packages = [sshVpn];
  };
}
