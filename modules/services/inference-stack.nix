{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.inference-stack;
in {
  options.services.inference-stack = {
    enable = mkEnableOption "Ollama + Open-WebUI inference stack with CUDA binary cache";

    ollama = {
      package = mkOption {
        type = types.package;
        default = pkgs.ollama-cuda;
        defaultText = literalExpression "pkgs.ollama-cuda";
        description = "Ollama package. Default is the CUDA build.";
      };
      host = mkOption {
        type = types.str;
        default = "0.0.0.0";
        description = "Host/interface Ollama listens on.";
      };
      port = mkOption {
        type = types.port;
        default = 11434;
        description = "Port Ollama listens on.";
      };
    };

    openWebUI = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Run the Open-WebUI frontend pointed at Ollama.";
      };
      host = mkOption {
        type = types.str;
        default = "0.0.0.0";
        description = "Host/interface Open-WebUI listens on.";
      };
      port = mkOption {
        type = types.port;
        default = 8080;
        description = "Port Open-WebUI listens on.";
      };
    };

    cudaCache = mkOption {
      type = types.bool;
      default = true;
      description = "Add cache.nixos-cuda.org as an extra-substituter (saves CUDA closure build time).";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open firewall ports for Ollama and (if enabled) Open-WebUI.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
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

    (mkIf cfg.cudaCache {
      nix.settings.extra-substituters = ["https://cache.nixos-cuda.org"];
      nix.settings.extra-trusted-public-keys = ["cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="];
    })

    (mkIf cfg.openWebUI.enable {
      services.open-webui = {
        enable = true;
        host = cfg.openWebUI.host;
        port = cfg.openWebUI.port;
        environment.OLLAMA_API_BASE_URL = "http://127.0.0.1:${toString cfg.ollama.port}";
      };

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
