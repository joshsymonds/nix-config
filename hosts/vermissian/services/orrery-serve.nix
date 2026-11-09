# The orrery HTTP service on loopback, exposed on the tailnet through
# `tailscale serve` at https://vermissian.tail82223.ts.net:8490/.
{pkgs, ...}: {
  # The serve config is per-node and additive, so this unit adds its mapping
  # and leaves the mappings other units own untouched. It exposes nothing
  # beyond the tailnet. The orrery listener is a user unit, so this system
  # unit cannot order on it; it waits for the loopback port instead.
  systemd.services.orrery-tailnet-serve = {
    description = "Tailscale serve front for orrery";
    after = ["tailscaled.service"];
    requires = ["tailscaled.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      for i in $(seq 1 30); do
        if ${pkgs.iproute2}/bin/ss -ltn 2>/dev/null | grep -q '127.0.0.1:8489'; then
          break
        fi
        sleep 1
      done
      for i in $(seq 1 10); do
        if ${pkgs.tailscale}/bin/tailscale serve --bg --https=8490 8489; then
          exit 0
        fi
        sleep 2
      done
      echo "orrery-tailnet-serve: tailscale serve kept failing" >&2
      exit 1
    '';
  };
}
