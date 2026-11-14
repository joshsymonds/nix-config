# ntfy-sh is orrery's push relay: loopback HTTP, exposed on the tailnet through
# `tailscale serve` at https://vermissian.tail82223.ts.net:8491/.
# ntfy state is ephemeral by design under the impermanent root: a reboot drops cached pushes.
{pkgs, ...}: {
  services.ntfy-sh = {
    enable = true;
    settings = {
      listen-http = "127.0.0.1:2586";
      base-url = "https://vermissian.tail82223.ts.net:8491";
      behind-proxy = true;
    };
  };

  # The serve config is per-node and additive, so this unit adds its mapping
  # and leaves the mappings other units own untouched. It exposes nothing
  # beyond the tailnet.
  systemd.services.ntfy-tailnet-serve = {
    description = "Tailscale serve front for ntfy";
    after = [
      "tailscaled.service"
      "ntfy-sh.service"
    ];
    requires = ["tailscaled.service"];
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
