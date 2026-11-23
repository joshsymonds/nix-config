{
  config,
  lib,
  pkgs,
  ...
}: let
  # The gateway reads route seats' *_env_file variables, so it needs patchbay's
  # key-file variables and awscli2 for the sigv4 Bedrock seat. The variables are
  # filtered out of patchbay's own unit so the paths stay patchbay's, never copied.
  patchbayKeyFileEnv =
    lib.filter
    (entry: lib.hasSuffix "_FILE" (lib.head (lib.splitString "=" entry)))
    config.systemd.user.services.patchbay.Service.Environment;
in {
  options.services.orreryGateway.port = lib.mkOption {
    type = lib.types.port;
    default = 4110;
    description = "Loopback port `orrery gateway` listens on.";
  };

  options.services.orreryGateway.serveClaude = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "When true, Claude Code's base URLs on this host (the settings env ANTHROPIC_BASE_URL and the ~/Work/attain /ctx/attain stamp) and orreryd's gateway address point at the gateway instead of patchbay.";
  };

  config.systemd.user.services.orrery-gateway = {
    Unit = {
      Description = "orrery gateway";
      After = ["network-online.target"];
      Wants = ["network-online.target"];
    };
    Service = {
      ExecStart = "${config.programs.orrery.package}/bin/orrery gateway --listen 127.0.0.1:${toString config.services.orreryGateway.port}";
      Restart = "on-failure";
      RestartSec = 5;
      Environment =
        [
          "PATH=${lib.makeBinPath [pkgs.awscli2]}"
        ]
        ++ patchbayKeyFileEnv;
    };
    Install.WantedBy = ["default.target"];
  };
}
