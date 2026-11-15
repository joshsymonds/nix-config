{
  config,
  pkgs,
  ...
}: let
  cfg = config.services.jellyfin;
  infuseSyncDir = "${cfg.dataDir}/plugins/InfuseSync_${pkgs.infusesync.version}.0";
in {
  services.jellyfin = {
    enable = true;
    package = pkgs.jellyfin;
    group = "users";
    openFirewall = true;
    user = "jellyfin";
  };

  users.users.jellyfin.extraGroups = ["video" "render"];

  # InfuseSync (pkgs/infusesync) lets Infuse's Library Mode pull deltas instead
  # of re-crawling the library. Jellyfin loads plugins from
  # <dataDir>/plugins/<Name>_<version>/ and writes its own state back into that
  # dir's meta.json, so it gets a writable copy, not a store symlink. Refreshed
  # on every start; other InfuseSync versions are removed so an upgrade doesn't
  # leave two copies for Jellyfin to choose between.
  systemd.services.jellyfin.preStart = ''
    for d in ${cfg.dataDir}/plugins/InfuseSync_*; do
      if [ -e "$d" ] && [ "$d" != ${infuseSyncDir} ]; then
        rm -rf -- "$d"
      fi
    done
    rm -rf -- ${infuseSyncDir}
    mkdir -p ${infuseSyncDir}
    cp -- ${pkgs.infusesync}/* ${infuseSyncDir}/
    chmod -R u+w ${infuseSyncDir}
  '';

  services.caddy.virtualHosts."jellyfin.home.husbuddies.gay".extraConfig = ''
    reverse_proxy /* localhost:8096
    import cloudflare
  '';
}
