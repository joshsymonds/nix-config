# The orrery HTTP service on loopback, exposed on the tailnet through
# `tailscale serve` at the controller's tailnet name, port 8490.
{pkgs, ...}: {
  # shimmer-tailnet-serve runs `tailscale serve reset`, which wipes every serve
  # mapping on this node. So this unit orders after it and is partOf it: a
  # shimmer restart re-runs the reset, and this unit re-runs afterwards to add
  # its mapping back. The serve config is otherwise additive, so this unit adds
  # its mapping and leaves the mappings other units own untouched. It exposes
  # nothing beyond the tailnet. The orrery listener is a user unit, so this
  # system unit cannot order on it; it waits for the loopback port instead.
  systemd.services.orrery-tailnet-serve = {
    description = "Tailscale serve front for orrery";
    after = [
      "tailscaled.service"
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
        if ${pkgs.iproute2}/bin/ss -ltn 2>/dev/null | grep -q '127.0.0.1:8492'; then
          break
        fi
        sleep 1
      done
      for i in $(seq 1 10); do
        if ${pkgs.tailscale}/bin/tailscale serve --bg --https=8490 8492; then
          exit 0
        fi
        sleep 2
      done
      echo "orrery-tailnet-serve: tailscale serve kept failing" >&2
      exit 1
    '';
  };
}
