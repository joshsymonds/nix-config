# Mentat — the personal assistant daemon (github:joshsymonds/mentat).
# The NixOS module ships with the daemon's flake; this file is only the
# host concerns: the pinned claude binary, the secrets file, shimmer
# wiring, and tailnet ingress.
{
  pkgs,
  config,
  inputs,
  ...
}: {
  # The HA conversation agent bridging Assist to the daemon. Ships in the
  # mentat repo (ha/custom_components/mentat); merges with the components
  # declared in home-assistant.nix.
  services.home-assistant.customComponents = [
    (pkgs.buildHomeAssistantComponent {
      owner = "joshsymonds";
      domain = "mentat";
      version = "0.1.0";
      src = "${inputs.mentat}/ha";
    })
  ];

  # MORGEN_API_KEY, NTFY_URL, NTFY_TOKEN, CLAUDE_CODE_OAUTH_TOKEN
  # (the OAuth token is minted interactively via `claude setup-token`).
  age.secrets."mentat-env" = {
    file = ../../../secrets/hosts/ultraviolet/mentat-env.age;
    owner = "mentat";
    group = "mentat";
    mode = "0400";
  };

  services.mentat = {
    enable = true;
    claudePackage = pkgs.claudeCodeCli;
    environmentFile = config.age.secrets."mentat-env".path;
    maxBudgetUsd = 2.0;
    # Shimmer via its own tailscale-serve front: serve injects the
    # Tailscale-User-Login header (ultraviolet's node identity =
    # josh@joshsymonds.com, on shimmer's allowlist). The direct
    # 127.0.0.1:8001 bind 401s without that header — verified 2026-06-10.
    mcpConfig.shimmer = {
      type = "http";
      url = "https://ultraviolet.tail82223.ts.net:8443/mcp";
    };
    reminder.enable = true; # 09:00 daily
  };

  # Restart on secret rotation: the .age ciphertext store path changes on
  # re-encryption (the module can't do this itself — it only sees the
  # constant /run/agenix runtime path).
  systemd.services.mentatd.restartTriggers = [config.age.secrets."mentat-env".file];

  # Tailnet ingress: mentatd binds loopback only (the API is
  # unauthenticated by design); `tailscale serve` is the only way in.
  # HTTPS on 8485 — 8443 is shimmer's. NEVER `tailscale funnel`.
  #
  # No `serve reset` here: shimmer-tailnet-serve owns the reset (it runs
  # first; we order after it) and re-adding the same mapping is
  # idempotent. Resetting here would clobber shimmer's mapping when this
  # unit restarts on its own.
  #
  # partOf: shimmer's reset wipes ALL serve mappings, and a shimmer restart
  # re-runs it (Requires= propagation from shimmer-tailnet). Without restart
  # propagation here, the 8485 mapping silently dies; partOf + after means
  # this unit re-runs second and re-adds it.
  systemd.services.mentat-tailnet-serve = {
    description = "Tailscale serve front for mentatd";
    after = ["tailscaled.service" "mentatd.service" "shimmer-tailnet-serve.service"];
    requires = ["tailscaled.service" "mentatd.service"];
    wants = ["shimmer-tailnet-serve.service"];
    partOf = ["shimmer-tailnet-serve.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      for i in $(seq 1 30); do
        if ${pkgs.iproute2}/bin/ss -ltn 2>/dev/null | grep -q '127.0.0.1:8484'; then
          break
        fi
        sleep 1
      done
      exec ${pkgs.tailscale}/bin/tailscale serve --bg --https=8485 8484
    '';
  };
}
