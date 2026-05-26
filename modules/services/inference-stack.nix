{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.inference-stack;
  caches = import ../../lib/caches.nix;
in {
  options.services.inference-stack = {
    enable = lib.mkEnableOption "Ollama + Open-WebUI inference stack with CUDA binary cache";

    ollama = {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.ollama-cuda;
        defaultText = lib.literalExpression "pkgs.ollama-cuda";
        description = "Ollama package. Default is the CUDA build.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Host/interface Ollama listens on. Default is localhost; widen to 0.0.0.0 for LAN access.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 11434;
        description = "Port Ollama listens on.";
      };
    };

    openWebUI = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the Open-WebUI frontend pointed at Ollama.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Host/interface Open-WebUI listens on. Default is localhost; widen to 0.0.0.0 for LAN access.";
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
      description = "Open firewall ports for Ollama and (if enabled) Open-WebUI. Default off; opt in for LAN exposure.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.ollama = {
        enable = true;
        package = cfg.ollama.package;
        host = cfg.ollama.host;
        port = cfg.ollama.port;
        user = "ollama";
        group = "ollama";
      };

      # Upstream `services.ollama` hard-codes DynamicUser = true even when
      # cfg.user/cfg.group are set explicitly. DynamicUser pushes the
      # StateDirectory through systemd's /var/lib/private/<name> bind-mount
      # indirection, which collides with our impermanence bind mount on
      # /var/lib/ollama (visible as "Failed to set up special execution
      # directory in /var/lib: Device or resource busy"). Force it off so
      # the static "ollama" user (which the upstream module already declares
      # under users.users.ollama when staticUser is true) is what actually
      # runs the daemon. Same pattern is applied to Open-WebUI below for
      # the same reason.
      systemd.services.ollama.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "ollama";
        Group = "ollama";
      };

      # KV cache quantization + flash attention. Gemma 4 has unusually fat
      # KV cache (500 MB-3 GB per context checkpoint per upstream reports),
      # which on a 16 GB card pushes even a 14 GB weight model into partial
      # CPU offload at modest context lengths. q8_0 cuts KV memory ~50%
      # with minimal quality impact; flash attention is its prerequisite.
      # Both are daemon-wide knobs (not Modelfile params), so they live
      # here.
      #
      # MAX_LOADED_MODELS=1: with multiple large quants that individually
      # eat most of the 16 GB card, the default scheduler tries to keep
      # both resident in parallel — switching from IQ4_XS to Q5_K_M within
      # OLLAMA_KEEP_ALIVE (5m) leaves 169 MiB free for a 19 GB load attempt
      # and the llama runner panics with exit status 2. Forcing a single
      # loaded model evicts the previous one before loading the new one,
      # which is the right policy for single-GPU + multi-quant.
      systemd.services.ollama.environment = {
        OLLAMA_FLASH_ATTENTION = "1";
        OLLAMA_KV_CACHE_TYPE = "q8_0";
        OLLAMA_MAX_LOADED_MODELS = "1";
      };

      # systemd's StateDirectory only creates dirs that don't already
      # exist — but impermanence pre-creates /var/lib/ollama (root-owned),
      # so StateDirectory leaves it alone and the ollama daemon can't
      # write to it. cfg.models defaults to ${home}/models, and
      # ReadWritePaths in the upstream unit references both; without the
      # models subdir existing, mount namespacing fails with
      # "Failed to set up mount namespacing: /var/lib/ollama/models:
      # No such file or directory". tmpfiles fixes both: chowns the
      # existing top-level dir and creates the models subdir under it.
      systemd.tmpfiles.rules = [
        "d ${config.services.ollama.home} 0755 ollama ollama - -"
        "d ${config.services.ollama.models} 0755 ollama ollama - -"
      ];

      networking.firewall.allowedTCPPorts =
        lib.optionals cfg.openFirewall [cfg.ollama.port]
        ++ lib.optionals (cfg.openFirewall && cfg.openWebUI.enable) [cfg.openWebUI.port];
    }

    (lib.mkIf cfg.cudaCache {
      nix.settings.extra-substituters = [caches.cuda.url];
      nix.settings.extra-trusted-public-keys = [caches.cuda.publicKey];
    })

    (lib.mkIf cfg.openWebUI.enable {
      services.open-webui = {
        enable = true;
        host = cfg.openWebUI.host;
        port = cfg.openWebUI.port;
        environment.OLLAMA_API_BASE_URL = "http://127.0.0.1:${toString cfg.ollama.port}";
      };

      # Open-WebUI persists chat history + uploaded models in /var/lib/open-webui;
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
