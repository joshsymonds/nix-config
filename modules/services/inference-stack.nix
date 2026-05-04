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
