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
  # Tailnet-only static page at https://vermissian.tail82223.ts.net:10003/.
  # The serve config is per-node and additive, so this unit adds its mapping
  # and leaves the mappings other units own untouched. It exposes nothing
  # beyond the tailnet.
  systemd.services.orrery-cheatsheet-serve = {
    description = "Tailscale serve front for the orrery cheatsheet";
    after = ["tailscaled.service"];
    requires = ["tailscaled.service"];
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
