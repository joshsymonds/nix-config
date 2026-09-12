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
  # The tiltyard judgment roster: selector -> the Seat that selector names in
  # the `tiltyard` context below. Its own file for the same reason, and
  # tests/gambit-rung-agents.nix asserts the roster there.
  tiltyardSeats = import ./tiltyard-seats.nix;

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
  # Messages to the Codex OAuth backend. A route carries the Seat's identity:
  # the Codex model id and, for the fast routes, the `speed` tier the Seat
  # writes into every request (chatgpt-models.nix says how that reaches
  # Codex).
  chatgptSeat = route:
    {
      upstream = "http://127.0.0.1:${toString codexPort}";
      auth_mode = "inject";
      billing = "subscription";
      api_key_env_file = "PATCHBAY_CHATGPT_KEY_FILE";
      inherit (route) model;
      # The Codex subscription's context window, not OpenRouter's larger one.
      max_input_tokens = 372000;
    }
    // lib.optionalAttrs (route ? speed) {inherit (route) speed;};

  # OpenRouter, paid per-token from the household key. Model ids and
  # context lengths verified against https://openrouter.ai/api/v1/models.
  # Keyed by public selector; the Seat itself lands in the registry under
  # seatID of that selector.
  openrouterSeats = {
    "openrouter/sol" = {
      upstream = "https://openrouter.ai/api";
      auth_mode = "inject";
      billing = "metered";
      api_key_env_file = "PATCHBAY_OPENROUTER_KEY_FILE";
      model = "openai/gpt-5.6-sol";
      max_input_tokens = 1050000;
    };
    "openrouter/luna" = {
      upstream = "https://openrouter.ai/api";
      auth_mode = "inject";
      billing = "metered";
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
      billing = "metered";
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
      billing = "self_hosted";
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
      billing = "self_hosted";
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
    // cfg.extraSeats
    // lib.optionalAttrs cfg.codexUpstream.enable (
      lib.mapAttrs (_: chatgptSeat) chatgptModels
    );

  # Marked-subagent Seats: Luna with the effort pinned in the model id
  # itself — CLIProxyAPI translates a "(medium)"/"(low)" suffix to the OpenAI
  # reasoning-effort parameter — on the fast tier like every Luna Seat. These
  # are subagent-only destinations, so they get no public selector: nothing
  # outside the subagents policy below can name them, and /v1/models never
  # lists them.
  subagentSeats = lib.optionalAttrs cfg.codexUpstream.enable {
    chatgpt-luna-medium = chatgptSeat {
      model = "gpt-5.6-luna(medium)";
      speed = "fast";
    };
    chatgpt-luna-low = chatgptSeat {
      model = "gpt-5.6-luna(low)";
      speed = "fast";
    };
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
  # Dropped while the allowance is exhausted, so every subagent rides the
  # anthropic default Seat instead of a Luna Seat that can only refuse.
  bindings = lib.mapAttrs (selector: _: seatID selector) subscriptionSeats;
  context =
    {
      default_seat = "anthropic";
      models = bindings;
    }
    // lib.optionalAttrs (cfg.codexUpstream.enable && !cfg.codexUpstream.exhausted) {
      subagents = {
        default_seat = "chatgpt-luna-medium";
        models = {
          "claude-opus-5" = "anthropic";
          "claude-haiku-4-5" = "chatgpt-luna-low";
          "claude-haiku-4-5-20251001" = "chatgpt-luna-low";
        };
      };
    };

  # The tiltyard Seats get their own ID space rather than the selector-derived
  # one: the roster selectors are bare identifiers chosen for a results table,
  # and `tiltyard-` keeps them from ever colliding with a public selector's Seat.
  # A roster entry naming a `seat` binds that existing Seat and publishes none.
  tiltyardSeatID = selector: "tiltyard-${selector}";
  tiltyardOwnSeats = lib.filterAttrs (_: entry: !(entry ? seat)) tiltyardSeats;

  # The judgment context: every roster selector bound to its pinned Seat, and
  # the anthropic forward Seat for everything else, so a judge or a harness
  # driving this context reaches a candidate only by naming it. No subagents
  # block — a judgment run's subagent traffic must ride the same Seat its
  # selector asked for, not a policy default that would silently swap the model
  # under measurement.
  tiltyardContext = {
    default_seat = "anthropic";
    models =
      lib.mapAttrs (
        selector: entry: entry.seat or (tiltyardSeatID selector)
      )
      tiltyardSeats;
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
      )
      subscriptionSeats
      // lib.mapAttrs' (
        selector: seat: lib.nameValuePair (tiltyardSeatID selector) seat
      )
      tiltyardOwnSeats;
    contexts = {
      # ~/.claude, and everything outside a work checkout.
      personal = context;
      # ~/Work/savecraft.
      savecraft = context;
      # ~/Work/attain.
      attain = context;
      # The judgment roster, for tiltyard runs and anything else comparing
      # models by name.
      tiltyard = tiltyardContext;
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

  # Sol and Luna have a second OpenRouter price tier above 272k prompt tokens,
  # but rate cards currently key only on model. Their Seats accept up to 1.05M
  # tokens, so metered rows without provider-reported cost stay explicitly
  # unknown rather than recording the known-wrong base-tier price until cards
  # become tier-aware. DeepSeek V4 Flash has a single tier, so its card remains.
  # OpenRouter has one cache-write price for it; the 5m and 1h fields mirror that
  # price so TTL-bucketed writes price at the same rate if ever reported.
  rateCardsFile = (pkgs.formats.json {}).generate "patchbay-rate-cards.json" [
    {
      model = "deepseek/deepseek-v4-flash-0731";
      effective_from = "2026-08-21T00:00:00Z";
      source = "openrouter.ai/api/v1/models 2026-08-21; no separate cache-write price — writes billed as input";
      rates_usd_per_million = {
        input = "0.08";
        output = "0.18";
        cache_read = "0.016";
        cache_creation = "0.08";
        cache_creation_5m = "0.08";
        cache_creation_1h = "0.08";
      };
    }
    # The judgment roster's three OpenRouter candidates (tiltyard-seats.nix),
    # so a graded run's rows carry a cost basis instead of unknown. Same
    # conventions as the card above: where the listing gives no separate
    # cache-write price the three cache_creation fields mirror the input price,
    # and where it gives no cache-read price that field takes the input price.
    # The source records which of those a card leans on.
    {
      model = "z-ai/glm-5.3-flash";
      effective_from = "2026-09-11T00:00:00Z";
      source = "openrouter.ai model listing 2026-09-11; no separate cache-read or cache-write price — both billed as input";
      rates_usd_per_million = {
        input = "0.15";
        output = "0.50";
        cache_read = "0.15";
        cache_creation = "0.15";
        cache_creation_5m = "0.15";
        cache_creation_1h = "0.15";
      };
    }
    {
      model = "moonshotai/kimi-k3";
      effective_from = "2026-09-11T00:00:00Z";
      source = "openrouter.ai model listing 2026-09-11; no separate cache-write price — writes billed as input";
      rates_usd_per_million = {
        input = "2.34";
        output = "11.70";
        cache_read = "0.24";
        cache_creation = "2.34";
        cache_creation_5m = "2.34";
        cache_creation_1h = "2.34";
      };
    }
    {
      model = "deepseek/deepseek-v4.1-flash";
      effective_from = "2026-09-11T00:00:00Z";
      source = "openrouter.ai model listing 2026-09-11; no separate cache-write price — writes billed as input";
      rates_usd_per_million = {
        input = "0.20";
        output = "0.60";
        cache_read = "0.006";
        cache_creation = "0.20";
        cache_creation_5m = "0.20";
        cache_creation_1h = "0.20";
      };
    }
  ];

  # Systemd user units do not inherit the session's XDG_STATE_HOME. Shared
  # strings keep the unit's paths and the NFS shippers in agreement.
  ledgerSubdir = ".local/state/patchbay/ledger";
  ledgerDir = "$HOME/${ledgerSubdir}";
  usageDbSubpath = ".local/state/patchbay/usage.sqlite";
  usageDb = "$HOME/${usageDbSubpath}";

  # Ship the ledger to the host's NFS bucket so spend across the fleet can
  # be summed in one place. /mnt/claude is a lazy systemd automount: the
  # `ls` triggers it, then findmnt checks for the NFS mount itself. Not
  # `mountpoint -q` — that passes on the autofs placeholder even when the
  # mount behind it failed, and the mkdir then fails the unit. When the NAS
  # isn't reachable this is a silent no-op.
  #
  # --no-owner --no-group, same as every other writer into this bucket (see
  # home-manager/claude-code/default.nix): the NAS export all_squashes to
  # 1024:100, so plain `rsync -a` fails its chgrp and exits 23 — measured, not
  # theoretical, which would have failed this unit every 10 minutes.
  ledgerSync = pkgs.writeShellScript "patchbay-ledger-sync" ''
    set -eu
    ${pkgs.coreutils}/bin/ls /mnt/claude >/dev/null 2>&1 || true
    ${pkgs.util-linux}/bin/findmnt -n -t nfs,nfs4 /mnt/claude >/dev/null 2>&1 || exit 0
    ${pkgs.coreutils}/bin/mkdir -p /mnt/claude/${hostname}/patchbay
    ${pkgs.rsync}/bin/rsync -a --no-owner --no-group "${ledgerDir}/" /mnt/claude/${hostname}/patchbay/
  '';

  usageSnapshotSync = pkgs.writeShellScript "patchbay-usage-snapshot-sync" ''
    set -euo pipefail
    ${pkgs.coreutils}/bin/ls /mnt/claude >/dev/null 2>&1 || true
    ${pkgs.util-linux}/bin/findmnt -n -t nfs,nfs4 /mnt/claude >/dev/null 2>&1 || exit 0
    [ -e "${usageDb}" ] || exit 0
    workdir=$(${pkgs.coreutils}/bin/mktemp -d)
    trap '${pkgs.coreutils}/bin/rm -rf "$workdir"' EXIT
    snapshot="$workdir/usage-$(${pkgs.coreutils}/bin/date -u +%Y%m%dT%H%M%SZ).sqlite"
    export PATCHBAY_USAGE_DB="${usageDb}"
    ${lib.getExe patchbay} usage snapshot "$snapshot"
    snapshots=/mnt/claude/${hostname}/patchbay/snapshots
    ${pkgs.coreutils}/bin/mkdir -p "$snapshots"
    ${pkgs.rsync}/bin/rsync -a --no-owner --no-group "$snapshot" "$snapshots/"
    ${pkgs.findutils}/bin/find "$snapshots" -maxdepth 1 -type f -name 'usage-*.sqlite' -printf '%f\n' \
      | ${pkgs.coreutils}/bin/sort -r \
      | ${pkgs.coreutils}/bin/tail -n +8 \
      | while IFS= read -r name; do ${pkgs.coreutils}/bin/rm -f -- "$snapshots/$name"; done
  '';
in {
  options.services.patchbay = {
    enable = lib.mkEnableOption "the patchbay Anthropic Messages API gateway";

    extraSeats = lib.mkOption {
      type = lib.types.attrsOf (pkgs.formats.json {}).type;
      default = {};
      description = "Additional public selector-to-Seat definitions for this host.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4100;
      description = ''
        Loopback port patchbay listens on. This is what the personal
        Claude Code profile's ANTHROPIC_BASE_URL points at.
      '';
    };

    ledgerShipper.enable = lib.mkEnableOption ''
      shipping patchbay's request ledger and daily usage SQLite snapshots to
      /mnt/claude/<host>/patchbay. Only for hosts that actually mount the NFS
      claude share
    '';

    codexUpstream.enable = lib.mkEnableOption ''
      the Codex subscription upstream: runs CLIProxyAPI (cli-proxy-api) on
      loopback :${toString codexPort}, translating Anthropic Messages to the
      ChatGPT-subscription Codex OAuth backend, and publishes the chatgpt/*
      routes at it. Enable only on hosts holding Codex OAuth creds in
      ~/.cli-proxy-api
    '';

    codexUpstream.exhausted = lib.mkEnableOption ''
      treating the Codex subscription's usage allowance as spent: the
      chatgpt/* routes stay published for anyone who names one, but marked
      subagent traffic stops defaulting to the Luna Seats and rides the
      anthropic forward Seat like everything else, and gambit dispatches from
      the Claude-only rung map. Set when the allowance runs out; clear when it
      refills
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
            # Pin patchbay's ledger, usage DB, and registry paths to their
            # fallback locations. PATCHBAY_RATE_CARDS explicitly enables rate-card
            # loading. systemd expands %h to the user's home; the ledger and usage
            # DB subpaths share strings with their shippers, and the registry
            # matches the xdg.configFile."patchbay/routes.json" target below.
            "PATCHBAY_LEDGER_DIR=%h/${ledgerSubdir}"
            "PATCHBAY_USAGE_DB=%h/${usageDbSubpath}"
            "PATCHBAY_RATE_CARDS=${rateCardsFile}"
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

    systemd.user.services.patchbay-usage-snapshot-sync = lib.mkIf cfg.ledgerShipper.enable {
      Unit = {
        Description = "Ship a daily patchbay usage SQLite snapshot to the NFS claude bucket";
        After = ["network-online.target"];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${usageSnapshotSync}";
      };
    };

    systemd.user.timers.patchbay-usage-snapshot-sync = lib.mkIf cfg.ledgerShipper.enable {
      Unit.Description = "Ship patchbay's daily usage SQLite snapshot";
      Timer = {
        # Persistent is honored for OnCalendar timers, unlike the monotonic
        # ledger timer above, so a missed daily snapshot catches up at boot.
        OnCalendar = "*-*-* 03:17:00";
        Persistent = true;
        Unit = "patchbay-usage-snapshot-sync.service";
      };
      Install.WantedBy = ["timers.target"];
    };
  };
}
