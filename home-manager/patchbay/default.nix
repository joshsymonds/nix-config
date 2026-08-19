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

  # Shared claudex coordinates (port/key/model ids), the single source of
  # truth home-manager/claudex also imports — kept there so these can never
  # drift between the running service and these routes at it.
  claudex = import ../../lib/claudex.nix;

  # The CLIProxyAPI listener key. It only gates a localhost socket and is
  # deliberately not an agenix secret — see home-manager/claudex/default.nix
  # for the same value and the same reasoning (anyone with local shell
  # access already holds the Codex OAuth creds it fronts).
  chatgptKeyFile = pkgs.writeText "patchbay-chatgpt-key" claudex.apiKey;

  # The ChatGPT/Codex subscription upstream: the cli-proxy-api user service
  # from home-manager/claudex, translating Anthropic Messages to the Codex
  # OAuth backend.
  chatgptRoute = model: {
    base_url = "http://127.0.0.1:${toString claudex.port}";
    auth = "inject";
    api_key_env_file = "PATCHBAY_CHATGPT_KEY_FILE";
    inherit model;
    # The Codex subscription's context window, not OpenRouter's larger one.
    max_input_tokens = 372000;
  };

  routes = {
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

    "chatgpt/sol" = chatgptRoute claudex.model;
    "chatgpt/luna" = chatgptRoute claudex.fastModel;

    # Bare-model-id aliases, identical to the chatgpt/* routes above.
    #
    # The personal profile's settings.json sets ANTHROPIC_BASE_URL to
    # patchbay, and a settings-file `env` entry beats a shell export in
    # Claude Code — so the `claudex` wrapper's exported ANTHROPIC_BASE_URL
    # (which points at CLIProxyAPI directly) loses. Claudex sessions
    # therefore arrive at patchbay asking for the bare ids it also exports
    # as ANTHROPIC_MODEL / ANTHROPIC_SMALL_FAST_MODEL. These two aliases
    # route them on to CLIProxyAPI unchanged, so claudex keeps working
    # exactly as before instead of falling through to Anthropic.
    ${claudex.model} = chatgptRoute claudex.model;
    ${claudex.fastModel} = chatgptRoute claudex.fastModel;
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
  };

  config = lib.mkIf cfg.enable {
    home.packages = [patchbay];

    xdg.configFile."patchbay/routes.json".source = registryFile;

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
        Environment = [
          "PATCHBAY_LISTEN=127.0.0.1:${toString cfg.port}"
          "PATCHBAY_OPENROUTER_KEY_FILE=/run/agenix/patchbay-openrouter-key"
          "PATCHBAY_CALLER_KEY_FILE=/run/agenix/patchbay-caller-key"
          "PATCHBAY_CHATGPT_KEY_FILE=${chatgptKeyFile}"
          # Pin patchbay's ledger + registry paths to the same locations it
          # would otherwise fall back to, so the agreement holds by construction.
          # systemd expands %h to the user's home; the ledger path shares
          # ledgerSubdir with the rsync shipper, and the registry matches the
          # xdg.configFile."patchbay/routes.json" target below.
          "PATCHBAY_LEDGER_DIR=%h/${ledgerSubdir}"
          "PATCHBAY_REGISTRY=%h/.config/patchbay/routes.json"
        ];
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
