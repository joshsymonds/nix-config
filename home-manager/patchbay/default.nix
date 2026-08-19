# patchbay — the per-host Anthropic Messages API gateway.
#
# One process per machine, bound to loopback, that Claude Code points
# ANTHROPIC_BASE_URL at. Claude models ride patchbay's built-in default
# route straight through to Anthropic on the caller's own credentials;
# anything matching an alias in the registry below gets re-pointed at a
# foreign upstream with a foreign key injected. Every request is recorded
# to a local ledger so per-project model spend is auditable.
#
# The registry is declarative: routes.json is generated here and lives in
# /nix/store, and patchbay re-reads it whenever the symlink target moves.
# A rebuild therefore takes effect on the next request with nothing to
# restart.
{
  config,
  hostname,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.patchbay;

  patchbay = pkgs.callPackage ../../pkgs/patchbay {
    src = inputs.patchbay;
  };

  # CLIProxyAPI coordinates. This module both runs the proxy (below, under
  # codexUpstream) and routes at it, so these are defined once here and can
  # never drift between the service and the routes.
  codexPort = 8317;
  codexListenerKey = "patchbay-local";
  # fastModel is the fast tier for haiku-slot work (summaries, small tool
  # calls). Confirmed present in the codex channel's /v1/models.
  codexModel = "gpt-5.6-sol";
  codexFastModel = "gpt-5.6-luna";

  # The CLIProxyAPI listener key. It is world-readable in /nix/store and only
  # gates the loopback listener — loopback is reachable by host-network
  # containers on the same machine, so treat it as a label, not a secret. The
  # actual credential is the Codex OAuth state in ~/.cli-proxy-api, which only
  # exists on hosts where codexUpstream is enabled; that per-host gating is the
  # real containment.
  chatgptKeyFile = pkgs.writeText "patchbay-chatgpt-key" codexListenerKey;

  # The ChatGPT/Codex subscription upstream: the cli-proxy-api user service
  # this module runs when codexUpstream is enabled, translating Anthropic
  # Messages to the Codex OAuth backend.
  chatgptRoute = model: {
    base_url = "http://127.0.0.1:${toString codexPort}";
    auth = "inject";
    api_key_env_file = "PATCHBAY_CHATGPT_KEY_FILE";
    inherit model;
    # The Codex subscription's context window, not OpenRouter's larger one.
    max_input_tokens = 372000;
  };

  routes =
    {
      # OpenRouter, paid per-token from the household key. Model ids and
      # context lengths verified against https://openrouter.ai/api/v1/models.
      "openrouter/sol" = {
        base_url = "https://openrouter.ai/api";
        auth = "inject";
        api_key_env_file = "PATCHBAY_OPENROUTER_KEY_FILE";
        model = "openai/gpt-5.6-sol";
        max_input_tokens = 1050000;
      };
      "openrouter/luna" = {
        base_url = "https://openrouter.ai/api";
        auth = "inject";
        api_key_env_file = "PATCHBAY_OPENROUTER_KEY_FILE";
        model = "openai/gpt-5.6-luna";
        max_input_tokens = 1050000;
      };
    }
    # Only published on hosts that actually run the Codex upstream; elsewhere
    # these routes would point at a port nothing listens on.
    // lib.optionalAttrs cfg.codexUpstream.enable {
      "chatgpt/sol" = chatgptRoute codexModel;
      "chatgpt/luna" = chatgptRoute codexFastModel;
    };

  # CLIProxyAPI: an Anthropic-compatible endpoint over the ChatGPT Codex
  # subscription. It runs as a user service bound to loopback. OAuth state
  # lives in ~/.cli-proxy-api (mutable, like ~/.codex) — authenticate once per
  # machine:
  #   cli-proxy-api --config ~/.config/cliproxyapi/config.yaml --codex-login
  # (or --codex-device-login on headless hosts; it prints a URL + code to enter
  # from any browser).
  proxyConfig = (pkgs.formats.yaml {}).generate "cliproxyapi-config.yaml" {
    host = "127.0.0.1";
    port = codexPort;
    auth-dir = "~/.cli-proxy-api";
    api-keys = [codexListenerKey];
    # Empty secret-key disables the management API and its control panel
    # (which otherwise auto-downloads a web UI from GitHub at runtime).
    remote-management = {
      allow-remote = false;
      secret-key = "";
      disable-control-panel = true;
    };
  };

  registryFile = (pkgs.formats.json {}).generate "patchbay-routes.json" {
    inherit routes;
  };

  # The ledger directory patchbay writes to, home-relative. Systemd user
  # units don't inherit the session's XDG_STATE_HOME, so patchbay falls back
  # to this $HOME-relative default. One string derives both the PATCHBAY_LEDGER_DIR
  # the unit pins (%h/${ledgerSubdir}) and the path the rsync shipper reads
  # ($HOME/${ledgerSubdir}), so pinning and shipping agree by construction.
  ledgerSubdir = ".local/state/patchbay/ledger";
  ledgerDir = "$HOME/${ledgerSubdir}";

  # Ship the ledger to the host's NFS bucket so spend across the fleet can
  # be summed in one place. /mnt/claude is a lazy systemd automount; the
  # mountpoint guard makes this a silent no-op (rather than an automount
  # trigger and a failed unit) when the NAS isn't reachable.
  #
  # --no-owner --no-group, same as every other writer into this bucket (see
  # home-manager/claude-code/default.nix): the NAS export all_squashes to
  # 1024:100, so plain `rsync -a` fails its chgrp and exits 23 — measured, not
  # theoretical, which would have failed this unit every 10 minutes.
  ledgerSync = pkgs.writeShellScript "patchbay-ledger-sync" ''
    set -eu
    ${pkgs.util-linux}/bin/mountpoint -q /mnt/claude || exit 0
    ${pkgs.coreutils}/bin/mkdir -p /mnt/claude/${hostname}/patchbay
    ${pkgs.rsync}/bin/rsync -a --no-owner --no-group ${ledgerDir}/ /mnt/claude/${hostname}/patchbay/
  '';
in {
  options.services.patchbay = {
    enable = lib.mkEnableOption "the patchbay Anthropic Messages API gateway";

    port = lib.mkOption {
      type = lib.types.port;
      default = 4100;
      description = ''
        Loopback port patchbay listens on. This is what the personal
        Claude Code profile's ANTHROPIC_BASE_URL points at.
      '';
    };

    ledgerShipper.enable = lib.mkEnableOption ''
      shipping patchbay's request ledger to /mnt/claude/<host>/patchbay.
      Only for hosts that actually mount the NFS claude share
    '';

    codexUpstream.enable = lib.mkEnableOption ''
      the Codex subscription upstream: runs CLIProxyAPI (cli-proxy-api) on
      loopback :${toString codexPort}, translating Anthropic Messages to the
      ChatGPT-subscription Codex OAuth backend, and publishes the chatgpt/*
      routes at it. Enable only on hosts holding Codex OAuth creds in
      ~/.cli-proxy-api
    '';
  };

  config = lib.mkIf cfg.enable {
    # cliproxyapi is also the one-time login CLI:
    #   cli-proxy-api --config ~/.config/cliproxyapi/config.yaml --codex-login
    # (--codex-device-login on headless hosts), so it belongs on PATH wherever
    # the upstream runs.
    home.packages = [patchbay] ++ lib.optional cfg.codexUpstream.enable pkgs.cliproxyapi;

    xdg.configFile."patchbay/routes.json".source = registryFile;

    xdg.configFile."cliproxyapi/config.yaml" = lib.mkIf cfg.codexUpstream.enable {
      source = proxyConfig;
    };

    systemd.user.services.cli-proxy-api = lib.mkIf cfg.codexUpstream.enable {
      Unit = {
        Description = "CLIProxyAPI — Anthropic-compatible endpoint over the ChatGPT Codex subscription";
        After = ["network-online.target"];
        Wants = ["network-online.target"];
      };
      Service = {
        ExecStart = "${lib.getExe pkgs.cliproxyapi} --config ${config.xdg.configHome}/cliproxyapi/config.yaml";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = ["default.target"];
    };

    systemd.user.services.patchbay = {
      Unit = {
        Description = "patchbay — per-host Anthropic Messages API gateway";
        After = ["network-online.target"];
        Wants = ["network-online.target"];
      };
      Service = {
        ExecStart = lib.getExe patchbay;
        Restart = "on-failure";
        RestartSec = 5;
        Environment =
          [
            "PATCHBAY_LISTEN=127.0.0.1:${toString cfg.port}"
            "PATCHBAY_OPENROUTER_KEY_FILE=/run/agenix/patchbay-openrouter-key"
            "PATCHBAY_CALLER_KEY_FILE=/run/agenix/patchbay-caller-key"
            # Pin patchbay's ledger + registry paths to the same locations it
            # would otherwise fall back to, so the agreement holds by construction.
            # systemd expands %h to the user's home; the ledger path shares
            # ledgerSubdir with the rsync shipper, and the registry matches the
            # xdg.configFile."patchbay/routes.json" target below.
            "PATCHBAY_LEDGER_DIR=%h/${ledgerSubdir}"
            "PATCHBAY_REGISTRY=%h/.config/patchbay/routes.json"
          ]
          ++ lib.optional cfg.codexUpstream.enable "PATCHBAY_CHATGPT_KEY_FILE=${chatgptKeyFile}";
      };
      Install.WantedBy = ["default.target"];
    };

    systemd.user.services.patchbay-ledger-sync = lib.mkIf cfg.ledgerShipper.enable {
      Unit = {
        Description = "Ship patchbay's request ledger to the NFS claude bucket";
        After = ["network-online.target"];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${ledgerSync}";
      };
    };

    systemd.user.timers.patchbay-ledger-sync = lib.mkIf cfg.ledgerShipper.enable {
      Unit.Description = "Ship patchbay's ledger every 10 minutes";
      Timer = {
        # No Persistent: systemd only honors it on OnCalendar= timers, and
        # this is monotonic. OnBootSec=2min already provides after-boot catch-up.
        OnBootSec = "2min";
        OnUnitActiveSec = "10min";
        Unit = "patchbay-ledger-sync.service";
      };
      Install.WantedBy = ["timers.target"];
    };
  };
}
