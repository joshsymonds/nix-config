# ntfy-sh is orrery's push relay: loopback HTTP, exposed on the tailnet through
# `tailscale serve` at the controller's tailnet name, port 8491. The push host
# that orreryd and orrery serve name is the controller's tailnet name, so the
# relay runs on the controller.
{
  config,
  pkgs,
  ...
}: let
  fleet = config.home-manager.users.joshsymonds.services.orreryFleet;
in {
  services.ntfy-sh = {
    enable = true;
    settings = {
      listen-http = "127.0.0.1:2586";
      base-url = "https://${fleet.controller}.${fleet.domain}:8491";
      behind-proxy = true;
    };
  };

  # shimmer-tailnet-serve runs `tailscale serve reset`, which wipes every serve
  # mapping on this node. So this unit orders after it and is partOf it, and
  # re-adds its mapping whenever that unit re-runs. It exposes nothing beyond
  # the tailnet.
  systemd.services.ntfy-tailnet-serve = {
    description = "Tailscale serve front for ntfy";
    after = [
      "tailscaled.service"
      "ntfy-sh.service"
      "shimmer-tailnet-serve.service"
    ];
    requires = ["tailscaled.service"];
    wants = ["shimmer-tailnet-serve.service"];
    partOf = ["shimmer-tailnet-serve.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      for i in $(seq 1 30); do
        if ${pkgs.iproute2}/bin/ss -ltn 2>/dev/null | grep -q '127.0.0.1:2586'; then
          break
        fi
        sleep 1
      done
      for i in $(seq 1 10); do
        if ${pkgs.tailscale}/bin/tailscale serve --bg --https=8491 2586; then
          exit 0
        fi
        sleep 2
      done
      echo "ntfy-tailnet-serve: tailscale serve kept failing" >&2
      exit 1
    '';
  };
}
