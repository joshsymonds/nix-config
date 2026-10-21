# Restart policies for all native services.
# Without these, a crashed service stays down until manual intervention.
# Uses lib.mkDefault so service-specific NixOS modules can override.
{lib, ...}: let
  restartPolicy = {
    Restart = lib.mkDefault "on-failure";
    RestartSec = lib.mkDefault "10s";
  };
  startLimits = {
    startLimitIntervalSec = lib.mkDefault 300;
    startLimitBurst = lib.mkDefault 5;
  };
in {
  systemd.services = {
    jellyfin =
      {serviceConfig = restartPolicy;}
      // startLimits;

    sonarr =
      {serviceConfig = restartPolicy;}
      // startLimits;

    radarr =
      {serviceConfig = restartPolicy;}
      // startLimits;

    prowlarr =
      {serviceConfig = restartPolicy;}
      // startLimits;

    # invidious and caddy already have restart policies via their NixOS modules
  };
}
