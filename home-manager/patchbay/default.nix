# patchbay — the per-host Anthropic Messages API gateway.
#
# One process per machine, bound to loopback, that Claude Code points
# ANTHROPIC_BASE_URL at. The URL carries a /ctx/<name> prefix naming which
# Context of the registry below answers: within it, Claude models ride the
# Context's default Seat (the Anthropic forward on the caller's own
# credentials) and anything matching a public selector binds a foreign Seat —
# another upstream with its own key injected. Every request is recorded to a
# local ledger so per-project model spend is auditable.
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
  # never drift between the service and the Seats.
  codexPort = 8317;
  codexListenerKey = "patchbay-local";
  # Public selector -> upstream model id for the ChatGPT/Codex subscription.
  # Its own file because the gambit rung agents name these selectors and a
  # check asserts they agree (home-manager/claude-code/gambit-rungs.nix).
  chatgptModels = import ./chatgpt-models.nix;

  # A Seat ID from a public selector: same name, spelled in the ID grammar
  # (^[a-z0-9][a-z0-9-]*$), so "openrouter/sol" binds Seat "openrouter-sol".
  # Deterministic and readable in the ledger, where the Seat ID is what each
  # request is billed against.
  seatID = selector: lib.replaceStrings ["/" "."] ["-" "-"] selector;

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
  chatgptSeat = model: {
    upstream = "http://127.0.0.1:${toString codexPort}";
    auth_mode = "inject";
    api_key_env_file = "PATCHBAY_CHATGPT_KEY_FILE";
    inherit model;
    # The Codex subscription's context window, not OpenRouter's larger one.
    max_input_tokens = 372000;
  };

  # OpenRouter, paid per-token from the household key. Model ids and
  # context lengths verified against https://openrouter.ai/api/v1/models.
  # Keyed by public selector; the Seat itself lands in the registry under
  # seatID of that selector.
  openrouterSeats = {
    "openrouter/sol" = {
      upstream = "https://openrouter.ai/api";
      auth_mode = "inject";
      api_key_env_file = "PATCHBAY_OPENROUTER_KEY_FILE";
      model = "openai/gpt-5.6-sol";
      max_input_tokens = 1050000;
    };
    "openrouter/luna" = {
      upstream = "https://openrouter.ai/api";
      auth_mode = "inject";
      api_key_env_file = "PATCHBAY_OPENROUTER_KEY_FILE";
      model = "openai/gpt-5.6-luna";
      max_input_tokens = 1050000;
    };
    # DeepSeek V4 Flash, pinned to the 0731 snapshot: the tiltyard study's
    # matched-comparison seat, and quota insurance — when a subscription runs
    # dry mid-session this is a competent coding model one alias away, on the
    # household key. Routed through patchbay rather than pointed at directly
    # because the current Claude Code CLI makes a fatal auth probe at startup
    # that a third-party endpoint 401s; patchbay answers it locally.
    #
    # 1048576, not the 1310720 the model listing headlines: that ceiling is
    # one provider (Cloudflare) of the ~30 serving this id, while 1048576 is
    # what top_provider, DeepSeek's own endpoint, and most of the rest serve.
    "openrouter/deepseek-flash" = {
      upstream = "https://openrouter.ai/api";
      auth_mode = "inject";
      api_key_env_file = "PATCHBAY_OPENROUTER_KEY_FILE";
      model = "deepseek/deepseek-v4-flash-0731";
      max_input_tokens = 1048576;
    };
  };

  # The RunPod H100 pods, reachable only over the tailnet: two servings of the
  # same Qwen3.8-27B target, so the study can compare them across one gateway
  # on one key. What differs between them is per-route below.
  #
  # insecure: the base_url is plain http, but every byte of it rides
  # WireGuard — the tailnet IS the encrypted link, and the pods carry
  # tag:runpod with dead-end ACLs so nothing but my machines can open them.
  # Terminating TLS on a pod would add a certificate to rotate and protect
  # exactly nothing.
  #
  # strip_cache_control: prompt caching is Anthropic's, and neither SGLang nor
  # llama.cpp implements it, so the marker comes off before the request leaves
  # here.
  #
  # max_input_tokens is PROVISIONAL on both. The model's window is 262144;
  # 131072 is deliberately half that, because what a pod will actually serve
  # depends on how much KV cache the H100 has left after the weights, not on
  # what the model can nominally take. The shakedown reads the server's real
  # max-total-tokens and these numbers get corrected then. See tiltyard
  # ops/runpod-dflash2/README.md for that handoff.
  runpodSeats = {
    # bf16 on SGLang with DFlash2. Its address is constant across pod
    # recreates because tailscale state lives on the pod's network volume, so
    # this is a plain constant rather than anything host-derived.
    "runpod/qwen3.8" = {
      upstream = "http://runpod-qwen.tail82223.ts.net:8000";
      auth_mode = "inject";
      api_key_env_file = "PATCHBAY_RUNPOD_KEY_FILE";
      model = "Qwen/Qwen3.8-27B";
      max_input_tokens = 131072;
      insecure = true;
      strip_cache_control = true;
    };
    # The second flavor: the UD-Q4_K_XL GGUF quant on llama.cpp, with the
    # DFlash2 PR (#27342) pinned. This pod carries no network volume, so its
    # tailnet identity is ephemeral — if a stale device record for the name is
    # still registered when the pod comes back, tailscale hands it
    # runpod-qwen-gguf-1, then -2, and this constant silently points at
    # nothing. Delete the old machine from the tailnet before relaunching.
    #
    # model: llama-server ignores the model a request names, but patchbay
    # requires one on an inject Seat, so this carries the target's HF id —
    # what the quant was made from, and what the bf16 pod above serves.
    "runpod/qwen-gguf" = {
      upstream = "http://runpod-qwen-gguf.tail82223.ts.net:8000";
      auth_mode = "inject";
      api_key_env_file = "PATCHBAY_RUNPOD_KEY_FILE";
      model = "Qwen/Qwen3.8-27B";
      max_input_tokens = 131072;
      insecure = true;
      strip_cache_control = true;
    };
  };

  # The personal-identity Seat set, keyed by public selector: OpenRouter and
  # the RunPod pods plus, where the Codex upstream actually runs, the ChatGPT
  # subscription. The chatgpt/* selectors are only published on hosts that run
  # that upstream; elsewhere they would point at a port nothing listens on.
  # runpod/* is unconditional — the pods answer to the whole tailnet, so every
  # host that publishes them can actually reach them.
  subscriptionSeats =
    openrouterSeats
    // runpodSeats
    // lib.optionalAttrs cfg.codexUpstream.enable (
      lib.mapAttrs (_: chatgptSeat) chatgptModels
    );

  # Marked-subagent Seats: Luna with the effort pinned in the model id
  # itself — CLIProxyAPI translates a "(medium)"/"(low)" suffix to the OpenAI
  # reasoning-effort parameter. These are subagent-only destinations, so they
  # get no public selector: nothing outside the subagents policy below can
  # name them, and /v1/models never lists them.
  subagentSeats = lib.optionalAttrs cfg.codexUpstream.enable {
    chatgpt-luna-medium = chatgptSeat "gpt-5.6-luna(medium)";
    chatgpt-luna-low = chatgptSeat "gpt-5.6-luna(low)";
  };

  # Every context binds the same selectors and defaults to the anthropic
  # forward Seat, so a Claude model rides the caller's own OAuth credentials
  # untouched. What a context buys is the name the ledger records against
  # each request, which is what keeps spend attributable per project.
  #
  # Marked subagent traffic (x-claude-code-agent-id) that no public selector
  # already claims rides Luna instead of the subscription: default Explores
  # and other unlisted subagents at medium effort, haiku-slot dispatches at
  # low. Two exact pins carve out what must stay native:
  #
  #   * claude-opus-5 -> anthropic. Gambit's worker and escalation ladders
  #     TERMINATE at the opus rung, and the ladder's 100%-solve invariant is
  #     exactly that the terminal rung is native Claude. No gambit ladder ends
  #     at fable, so fable needs no pin — fable-inheriting subagents (default
  #     Explores, background forks) take the Luna default.
  #   * Both haiku spellings appear on the wire and bindings are exact, so
  #     the fast tier is pinned twice.
  #
  # Only on codexUpstream hosts: the Luna Seats live on the loopback proxy,
  # and a subagents block naming an absent Seat invalidates the registry.
  bindings = lib.mapAttrs (selector: _: seatID selector) subscriptionSeats;
  context =
    {
      default_seat = "anthropic";
      models = bindings;
    }
    // lib.optionalAttrs cfg.codexUpstream.enable {
      subagents = {
        default_seat = "chatgpt-luna-medium";
        models = {
          "claude-opus-5" = "anthropic";
          "claude-haiku-4-5" = "chatgpt-luna-low";
          "claude-haiku-4-5-20251001" = "chatgpt-luna-low";
        };
      };
    };

  # The seat-based registry: global Seats, context-local selector bindings,
  # selected per request by the /ctx/<name> URL prefix Claude Code's
  # ANTHROPIC_BASE_URL carries. Bare /v1 requests ride default_context.
  registry = {
    default_context = "personal";
    seats =
      {
        anthropic = {
          upstream = "https://api.anthropic.com";
          auth_mode = "forward";
        };
      }
      // subagentSeats
      // lib.mapAttrs' (
        selector: seat: lib.nameValuePair (seatID selector) seat
      ) subscriptionSeats;
    contexts = {
      # ~/.claude, and everything outside a work checkout.
      personal = context;
      # ~/Work/savecraft.
      savecraft = context;
      # ~/Work/attain.
      attain = context;
    };
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

  registryFile = (pkgs.formats.json {}).generate "patchbay-routes.json" registry;

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
        ExecStart = "${lib.getExe patchbay} serve";
        Restart = "on-failure";
        RestartSec = 5;
        Environment =
          [
            # No PATH: patchbay is started by absolute store path and shells
            # out to nothing.
            "PATCHBAY_LISTEN=127.0.0.1:${toString cfg.port}"
            "PATCHBAY_OPENROUTER_KEY_FILE=/run/agenix/patchbay-openrouter-key"
            "PATCHBAY_CALLER_KEY_FILE=/run/agenix/patchbay-caller-key"
            # Unconditional: tiltyard's scripts/runpod-qwen.sh writes this key
            # when it launches the pod, and patchbay reads key files per
            # request — so on a host where it never appears, the cost is a 500
            # on that one route, not a unit that refuses to start.
            "PATCHBAY_RUNPOD_KEY_FILE=%h/.config/patchbay/runpod-qwen.key"
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
