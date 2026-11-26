# The orrery cheatsheet: `orrery help --html` built from the pinned orrery
# package at nix build time, served as a static page on the tailnet only.
{
  inputs,
  pkgs,
  ...
}: let
  orrery = inputs.orrery.packages.${pkgs.stdenv.hostPlatform.system}.default;
  page = pkgs.runCommand "orrery-cheatsheet.html" {} ''
    ${orrery}/bin/orrery help --html > $out
  '';
in {
  # Tailnet-only static page at the controller's tailnet name, port 10003.
  # shimmer-tailnet-serve runs `tailscale serve reset`, which wipes every serve
  # mapping on this node. So this unit orders after it and is partOf it, and
  # re-adds its mapping whenever that unit re-runs. It exposes nothing beyond
  # the tailnet.
  systemd.services.orrery-cheatsheet-serve = {
    description = "Tailscale serve front for the orrery cheatsheet";
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
      for i in $(seq 1 10); do
        if ${pkgs.tailscale}/bin/tailscale serve --bg --https=10003 ${page}; then
          exit 0
        fi
        sleep 2
      done
      echo "orrery-cheatsheet-serve: tailscale serve kept failing" >&2
      exit 1
    '';
  };
}
