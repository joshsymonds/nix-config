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

  # LIVEKIT_API_KEY/LIVEKIT_API_SECRET (the SFU keypair, the same values
  # livekit-keys carries) plus LIVEKIT_INFERENCE_API_KEY/SECRET for LiveKit
  # Cloud's hosted STT/TTS.
  #
  # The inference pair ships as REPLACE_ME placeholders on purpose: the
  # LiveKit Cloud project is created by hand, and the user swaps the values
  # in with `agenix -e`. A placeholder key fails per-job at STT
  # construction, not as a unit crashloop — so the agent deploys, stays up,
  # and only the individual voice job errors until the real keys land.
  #
  # root:root 0400 rather than the service user: the module runs
  # mentat-voice under DynamicUser, so there is no stable UID to own this,
  # and systemd opens EnvironmentFile as PID 1 before dropping to the
  # transient user (same reason as livekit-keys).
  age.secrets."mentat-voice-env" = {
    file = ../../../secrets/hosts/ultraviolet/mentat-voice-env.age;
    owner = "root";
    group = "root";
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

    # The LiveKit voice agent. livekitUrl and mentatUrl are left at their
    # defaults on purpose — both services are loopback-bound on this very
    # host (ws://127.0.0.1:7880 is livekit.nix's signalPort, and mentatd
    # listens on 8484).
    voice = {
      enable = true;
      environmentFile = config.age.secrets."mentat-voice-env".path;
    };
  };

  # Restart on secret rotation: the .age ciphertext store path changes on
  # re-encryption (the module can't do this itself — it only sees the
  # constant /run/agenix runtime path).
  systemd.services.mentatd.restartTriggers = [config.age.secrets."mentat-env".file];
  systemd.services.mentat-voice.restartTriggers = [config.age.secrets."mentat-voice-env".file];

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
