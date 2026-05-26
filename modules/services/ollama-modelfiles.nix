{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.ollama-modelfiles;
in {
  options.services.ollama-modelfiles = {
    enable = lib.mkEnableOption "auto-create Ollama models from declared Modelfiles";

    modelfiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      example = lib.literalExpression ''
        {
          mymodel = ./modelfiles/mymodel;
        }
      '';
      description = ''
        Attrset of model name → Modelfile path. Each entry is materialized
        at /etc/ollama/modelfiles/<name> and registered with Ollama via
        `ollama create <name> -f <path>` after ollama.service is reachable.

        Modelfiles should NOT include SYSTEM directives — persona/system
        prompts belong in Open-WebUI (declarative-prompt-in-git is rarely
        what you want). Modelfiles here are for FROM/TEMPLATE/PARAMETER:
        which base GGUF, sampling, context, MoE offload.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.modelfiles != {}) {
    # Materialize each Modelfile at /etc/ollama/modelfiles/<name>.
    environment.etc =
      lib.mapAttrs' (name: path:
        lib.nameValuePair "ollama/modelfiles/${name}" {
          source = path;
        })
      cfg.modelfiles;

    # Runs after ollama.service is up and creates each model.
    # `ollama create` is idempotent: re-running with the same Modelfile is
    # cheap (manifest re-creation only); the expensive part is the FROM
    # pull, which is cached under /var/lib/ollama after the first run.
    # Re-running on every activation is the simplest way to pick up
    # Modelfile edits — no hash tracking needed.
    #
    # Type=exec (not oneshot): activation returns as soon as the script
    # starts, so `nh os switch` doesn't block for the duration of any
    # in-flight model pull (tens of GB on first run). Mirrors upstream
    # `services.ollama.loadModels`'s ollama-model-loader unit. Trade-off:
    # the unit transitions to "inactive (dead)" on completion rather than
    # staying "active" — check journal for the ✓ lines to confirm.
    systemd.services.ollama-create-models = {
      description = "Create Ollama models from declared Modelfiles";
      after = ["ollama.service" "network-online.target"];
      bindsTo = ["ollama.service"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target" "ollama.service"];

      script = let
        ollamaBin = "${config.services.ollama.package}/bin/ollama";
        ollamaApi = "http://${config.services.ollama.host}:${toString config.services.ollama.port}/";

        createOne = name: ''
          echo "▶  Creating Ollama model: ${name}"
          if ${ollamaBin} create ${lib.escapeShellArg name} -f /etc/ollama/modelfiles/${lib.escapeShellArg name}; then
            echo "✓  ${name}"
          else
            echo "✗  ${name} — see ollama-create-models journal for details" >&2
          fi
        '';
      in ''
        # Wait for Ollama's HTTP API to be reachable before issuing creates.
        # services.ollama declares After=network-online but the HTTP listener
        # races the unit start; polling is more robust than a fixed sleep.
        echo "Waiting for Ollama API at ${ollamaApi} ..."
        for _ in $(seq 1 60); do
          if ${pkgs.curl}/bin/curl -sf --max-time 2 ${ollamaApi} >/dev/null; then
            echo "Ollama API is up."
            break
          fi
          sleep 1
        done

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: createOne name) cfg.modelfiles)}
      '';

      serviceConfig = {
        Type = "exec";
        User = config.services.ollama.user;
        Group = config.services.ollama.group;
        # First-run pulls are tens of GB; don't cap the runtime.
        TimeoutStartSec = "infinity";
        # Ollama's HOME must match the daemon's HOME for the CLI to find
        # the same model store the daemon manages.
        Environment = ["HOME=${config.services.ollama.home}"];
      };
    };
  };
}
