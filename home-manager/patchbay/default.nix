# patchbay — the per-host Anthropic Messages API gateway.
#
# One process per machine, bound to loopback, that Claude Code points
# ANTHROPIC_BASE_URL at. The URL carries a /ctx/<name> prefix naming which
# context of the registry below answers: within it, Claude models ride the
# context's default route (the built-in Anthropic forward on the caller's own
# credentials, unless the context names another) and anything matching an
# alias gets re-pointed at a foreign upstream with a foreign key injected.
# Every request is recorded to a local ledger so per-project model spend is
# auditable.
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
  # Route key -> upstream model id for the ChatGPT/Codex subscription. Its own
  # file because the gambit rung agents name these keys and a check asserts
  # they agree (home-manager/claude-code/gambit-rungs.nix).
  chatgptModels = import ./chatgpt-models.nix;

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

  # OpenRouter, paid per-token from the household key. Model ids and
  # context lengths verified against https://openrouter.ai/api/v1/models.
  # Deliberately published in EVERY context, work included: reaching a
  # non-Claude model from a work session still spends the household key, not
  # the employer's, which is the escape hatch I want available everywhere.
  openrouterRoutes = {
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
  };

  # The personal-identity route set: OpenRouter plus, where the Codex
  # upstream actually runs, the ChatGPT subscription. The chatgpt/* routes
  # are only published on hosts that run that upstream; elsewhere they would
  # point at a port nothing listens on.
  subscriptionRoutes =
    openrouterRoutes
    // lib.optionalAttrs cfg.codexUpstream.enable (
      lib.mapAttrs (_: chatgptRoute) chatgptModels
    );

  # The Attain Bedrock default route: Claude models in the attain-bedrock
  # context are signed with SigV4 from the `attain` AWS profile instead of
  # forwarded to Anthropic. It names no base_url (the endpoint is derived
  # from the region) and no model id — the caller's Claude id is translated
  # through the model map file, which holds the per-user application-
  # inference-profile ARNs. Those ARNs embed the Attain AWS account id and
  # this repo is public, so they live in an agenix secret and only the env
  # var naming that file appears here.
  #
  # 200000: the Bedrock Claude ids carry the same context window as their
  # Anthropic-side equivalents. The 1M-context [1m] hint is a client-side
  # suffix Claude Code strips before the request, so what reaches this route
  # is always the base window.
  attainBedrockDefaultRoute = {
    auth = "sigv4";
    aws_profile = "attain";
    aws_region = "us-east-2";
    model_map_env_file = "PATCHBAY_BEDROCK_MODEL_MAP_FILE";
    max_input_tokens = 200000;
  };

  # Registry v2: named contexts, selected per request by the /ctx/<name> URL
  # prefix Claude Code's ANTHROPIC_BASE_URL carries. A context without a
  # default_route rides patchbay's built-in Anthropic forward — the caller's
  # own OAuth credentials, untouched. All four ship on every patchbay host;
  # a sigv4 request on a machine with no `attain` AWS profile fails at
  # credential exec with a clear 502 rather than routing somewhere wrong.
  contexts = {
    # ~/.claude, my own Anthropic account.
    personal.routes = subscriptionRoutes;
    # Savecraft work, same personal identity and subscriptions.
    savecraft.routes = subscriptionRoutes;
    # Attain on the Anthropic OAuth account (the `cwswitch anthropic` half).
    attain.routes = openrouterRoutes;
    # Attain on the employer's Bedrock account (the `cwswitch bedrock` half).
    "attain-bedrock" = {
      default_route = attainBedrockDefaultRoute;
      routes = openrouterRoutes;
    };
  };

  # Bedrock model map: caller model id -> application-inference-profile ARN.
  # Home-manager agenix, so its path is a literal "''${XDG_RUNTIME_DIR}/..."
  # placeholder; systemd does NOT expand that in Environment=, but a user
  # unit's %t specifier IS the runtime dir, so swap one for the other and the
  # unit still derives its path from the secret declaration.
  bedrockModelMapPath =
    lib.replaceStrings ["\${XDG_RUNTIME_DIR}"] ["%t"]
    config.age.secrets."patchbay-bedrock-model-map".path;

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
    inherit contexts;
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
    # Caller model id -> Attain application-inference-profile ARN, for the
    # attain-bedrock context's sigv4 default route. Encrypted because the
    # ARNs embed the Attain AWS account id and this repo is public.
    age.secrets."patchbay-bedrock-model-map" = {
      file = ../../secrets/user/patchbay-bedrock-model-map.age;
    };

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
        ExecStart = "${lib.getExe patchbay} serve";
        Restart = "on-failure";
        RestartSec = 5;
        Environment =
          [
            # The sigv4 default route exports AWS credentials by running
            # `aws configure export-credentials`, so the aws CLI must be on
            # the unit's PATH. Nothing else here needs a PATH: patchbay
            # itself is started by absolute store path.
            "PATH=${lib.makeBinPath [pkgs.awscli2]}"
            "PATCHBAY_LISTEN=127.0.0.1:${toString cfg.port}"
            "PATCHBAY_OPENROUTER_KEY_FILE=/run/agenix/patchbay-openrouter-key"
            "PATCHBAY_CALLER_KEY_FILE=/run/agenix/patchbay-caller-key"
            "PATCHBAY_BEDROCK_MODEL_MAP_FILE=${bedrockModelMapPath}"
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
