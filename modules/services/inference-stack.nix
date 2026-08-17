{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  cfg = config.services.inference-stack;
  caches = import ../../lib/caches.nix;

  # Bleeding-edge llama-cpp + llama-swap from nixpkgs-inference (a dedicated
  # side-channel input pinned to unstable HEAD; see flake.nix). The inference
  # toolchain (llama.cpp upstream) ships new model arches and perf flags on
  # a weekly cadence — riding the edge here decouples those bumps from the
  # main nixpkgs lock (which would trigger 200+ package rebuilds).
  inferencePkgs = import inputs.nixpkgs-inference {
    system = pkgs.stdenv.hostPlatform.system;
    config = {
      allowUnfree = true;
      cudaSupport = true;
      # Gnomon's RTX 5070 Ti is Blackwell compute capability 12.0. Keeping the
      # side-channel closure host-specific avoids sandboxed `-arch=native`
      # falling back to sm_75 and avoids compiling eight irrelevant targets.
      cudaCapabilities = ["12.0"];
    };
  };
  openWebUIPkgs = import inputs.nixpkgs-open-webui {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
  llamaCpp = inferencePkgs.llama-cpp;
  llamaSwap = inferencePkgs.llama-swap;
  llamaServer = "${llamaCpp}/bin/llama-server";

  modelsDir = "/var/lib/llama-models";

  # Per-model spec consumed by llama-swap. ggufUrl is the direct HF
  # `resolve/main/<file>.gguf` URL — fetched by fetch-llama-models.service
  # at activation time and stashed under modelsDir. `flags` is whatever
  # extra llama-server flags this model wants (sampling, KV cache, fit,
  # ubatch, etc.). The Modelfile abstraction is gone; this is the
  # llama-swap replacement.
  modelType = lib.types.submodule {
    options = {
      ggufUrl = lib.mkOption {
        type = lib.types.str;
        description = ''
          Direct download URL for the GGUF file. Typically a HuggingFace
          `resolve/main/<file>.gguf` URL. Fetched once at activation if
          the local file is missing.
        '';
      };

      flags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Extra `llama-server` flags for this model (sampling, cache, fit, etc.).";
        example = lib.literalExpression ''
          [
            "--fit" "on" "--fit-ctx" "16384" "--fit-target" "256"
            "-np" "1" "-fa" "on" "--mlock" "--no-mmap"
            "-b" "2048" "-ub" "2048"
            "-ctk" "q8_0" "-ctv" "q8_0"
            "--temp" "1.0" "--top-p" "0.95" "--top-k" "64" "--min-p" "0.0"
          ]
        '';
      };
    };
  };
in {
  options.services.inference-stack = {
    enable = lib.mkEnableOption "llama-swap + llama-server inference stack with Open-WebUI frontend";

    swap = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = ''
          Address llama-swap's OpenAI-compatible listener binds. Only the
          llama-swap front door widens with this; the per-model llama-server
          backends and Open-WebUI's upstream URL always use 127.0.0.1, so
          setting "0.0.0.0" exposes exactly one unauthenticated port
          (`swap.port`) — pair it with `openFirewall` deliberately.
        '';
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 11434;
        description = "Port llama-swap listens on (OpenAI-compatible endpoint).";
      };
    };

    models = lib.mkOption {
      type = lib.types.attrsOf modelType;
      default = {};
      description = ''
        Attrset of model name → spec. Each entry becomes an llama-swap
        backend; the model name is what shows up in Open-WebUI's picker
        and in the OpenAI `model` field. GGUFs are fetched to
        `${modelsDir}/<name>.gguf` from `ggufUrl` if missing.
      '';
    };

    openWebUI = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the Open-WebUI frontend pointed at llama-swap.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Host/interface Open-WebUI listens on.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "Port Open-WebUI listens on.";
      };
    };

    cudaCache = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Add cache.nixos-cuda.org as an extra-substituter (saves CUDA closure build time).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open firewall ports for llama-swap and (if enabled) Open-WebUI.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # ── CLI clients ─────────────────────────────────────────────────────
      # qwen-code: the headless coding-agent harness for the local models
      # this stack serves (point it at llama-swap with
      # OPENAI_BASE_URL=http://localhost:11434/v1, OPENAI_API_KEY=local,
      # OPENAI_MODEL=<llama-swap entry>). Built from pkgs/qwen-code — a
      # local bump to upstream latest; nixpkgs (even at the inference
      # input's rev) is stuck five minor versions behind at 0.16.0.
      environment.systemPackages = [
        (inferencePkgs.callPackage ../../pkgs/qwen-code/package.nix {})
      ];

      # ── llama-swap ──────────────────────────────────────────────────────
      # Hands `${PORT}` to llama-swap; llama-swap substitutes a free port
      # at spawn time and routes accordingly. Each model command launches
      # a llama-server bound to that port serving exactly one model. With
      # MAX_LOADED_MODELS implicit-1 semantics (default), swapping models
      # in Open-WebUI kills the previous llama-server and spawns the new.
      services.llama-swap = {
        enable = true;
        package = llamaSwap;
        listenAddress = cfg.swap.host;
        port = cfg.swap.port;
        settings = {
          # Drop idle backends to free VRAM after some inactivity. 5 min
          # mirrors what Ollama's OLLAMA_KEEP_ALIVE defaulted to.
          healthCheckTimeout = 60;
          models =
            lib.mapAttrs (name: m: {
              cmd = lib.concatStringsSep " " ([
                  llamaServer
                  # Backends stay on loopback regardless of swap.host: only
                  # llama-swap fronts them, and each spawns on an ephemeral
                  # port that must not become a second unauthenticated door.
                  "--host"
                  "127.0.0.1"
                  "--port"
                  "\${PORT}"
                  "-m"
                  "${modelsDir}/${name}.gguf"
                ]
                ++ m.flags);
              # llama-swap kills idle backends after ttl seconds. 300s = 5m.
              ttl = 300;
            })
            cfg.models;
        };
      };

      # Override the upstream llama-swap unit's ProtectHome=true so it can
      # read GGUFs from modelsDir (under /var/lib, not /home, so technically
      # unaffected — but explicit ReadOnlyPaths anchors the model dir for
      # the runner subprocesses spawned via execve).
      systemd.services.llama-swap.serviceConfig = {
        # llama-swap forks llama-server, which inherits the unit's sandbox.
        # llama-server needs to mlock the GGUF (we pass --mlock), which is
        # blocked by default sandbox; widen capabilities.
        AmbientCapabilities = ["CAP_IPC_LOCK"];
        CapabilityBoundingSet = ["CAP_IPC_LOCK"];
        LimitMEMLOCK = "infinity";
        # Loosen MemoryDenyWriteExecute — CUDA runtime JIT-compiles kernels
        # and needs PROT_EXEC on anonymous mappings. Without this the first
        # llama-server invocation segfaults inside libcuda.
        MemoryDenyWriteExecute = lib.mkForce false;
        # llama-server writes to its own stderr/stdout, no filesystem state.
        ReadOnlyPaths = [modelsDir];
        # Pass through CUDA env required by NVIDIA driver discovery.
        PrivateDevices = lib.mkForce false;
      };

      # ── GGUF fetcher ────────────────────────────────────────────────────
      # llama.cpp has no `pull` equivalent; we curl GGUFs directly from HF
      # to modelsDir on activation. Resumable (`curl -C -`) so a partial
      # download survives a reboot. Type=exec so activation doesn't block
      # on multi-GB downloads — first chat request to a not-yet-downloaded
      # model will fail with "model file missing" until the fetcher
      # finishes for that one.
      systemd.tmpfiles.rules = [
        "d ${modelsDir} 0755 root root - -"
      ];

      systemd.services.fetch-llama-models = {
        description = "Fetch GGUFs declared by services.inference-stack.models";
        after = ["network-online.target"];
        wants = ["network-online.target"];
        wantedBy = ["multi-user.target"];
        # Don't block llama-swap startup — fetcher runs in parallel.
        before = [];

        path = [pkgs.curl pkgs.coreutils];

        # All declared models fetch in parallel — HuggingFace throttles
        # per connection (~13 MB/s sustained per stream), so two parallel
        # downloads finish in ~half the wall time of running them
        # sequentially. `wait` at the end joins all of them.
        script = let
          fetchOne = name: m: ''
            (
              target="${modelsDir}/${name}.gguf"
              if [ -s "$target" ] && [ "$(stat -c%s "$target")" -gt 1000000 ]; then
                echo "✓ ${name}: already present ($(du -h "$target" | cut -f1))"
              else
                echo "▶ ${name}: fetching from ${m.ggufUrl}"
                # HuggingFace occasionally truncates a connection mid-stream
                # ("end of response with N bytes missing"); --retry-all-errors
                # makes curl retry on that class of failure too, not just
                # connection setup. Without it the GGUF stays at .partial
                # and the parent service exits "successfully" — a silent
                # broken-state we hit on the first run. Retry 10× with
                # exponential-ish backoff via --retry-delay floor.
                curl -L -C - --fail --retry 10 --retry-all-errors \
                  --retry-delay 5 --retry-max-time 0 \
                  --output "$target.partial" \
                  "${m.ggufUrl}"
                mv "$target.partial" "$target"
                echo "✓ ${name}: fetched ($(du -h "$target" | cut -f1))"
              fi
            ) &
          '';
        in ''
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList fetchOne cfg.models)}
          wait
          echo "✓ all model fetches complete"
        '';

        serviceConfig = {
          Type = "exec";
          # Runs as root because modelsDir lives under /var/lib; tmpfiles
          # created it root:root. Kept simple — GGUFs are public, no auth.
          User = "root";
          Group = "root";
          # Tens of GB on first run; don't time out.
          TimeoutStartSec = "infinity";
        };
      };

      networking.firewall.allowedTCPPorts =
        lib.optionals cfg.openFirewall [cfg.swap.port]
        ++ lib.optionals (cfg.openFirewall && cfg.openWebUI.enable) [cfg.openWebUI.port];
    }

    # ── CUDA cache ────────────────────────────────────────────────────────
    (lib.mkIf cfg.cudaCache {
      nix.settings.extra-substituters = [caches.cuda.url];
      nix.settings.extra-trusted-public-keys = [caches.cuda.publicKey];
    })

    # ── Open-WebUI pointing at llama-swap ────────────────────────────────
    (lib.mkIf cfg.openWebUI.enable {
      services.open-webui = {
        enable = true;
        # Chat response handling changes quickly upstream. Consume the narrow
        # Open WebUI edge input without moving the host's primary nixpkgs pin.
        package = openWebUIPkgs.open-webui;
        host = cfg.openWebUI.host;
        port = cfg.openWebUI.port;
        environment = {
          # llama-swap exposes an OpenAI-compatible endpoint at /v1/.
          # Open-WebUI's OpenAI client adds /v1 to whatever's configured
          # via the *_URLS env vars itself when the value already ends
          # in /v1 it doesn't double up. Pass it explicitly for clarity.
          # Always loopback: Open-WebUI is co-located with llama-swap, and
          # swap.host may be a wildcard bind address that is not a valid
          # connect target.
          OPENAI_API_BASE_URLS = "http://127.0.0.1:${toString cfg.swap.port}/v1";
          # llama-swap doesn't require auth. Open-WebUI requires SOMETHING
          # in the keys list; supply a placeholder.
          OPENAI_API_KEYS = "sk-llama-swap-no-auth";
          # Hide the (now-removed) Ollama tab.
          ENABLE_OLLAMA_API = "False";
        };
      };

      # Open-WebUI persists chat history + RAG + personas in /var/lib/open-webui;
      # DynamicUser would rotate the UID and break ownership of that state.
      systemd.services.open-webui.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "open-webui";
        Group = "open-webui";
      };

      users.users.open-webui = {
        isSystemUser = true;
        group = "open-webui";
        home = "/var/lib/open-webui";
      };

      users.groups.open-webui = {};
    })
  ]);
}
