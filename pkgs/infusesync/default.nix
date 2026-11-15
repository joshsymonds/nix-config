# Firecore's InfuseSync Jellyfin plugin, from the release zip (InfuseSync.dll
# plus meta.json). It records library changes while Infuse clients are away so
# Infuse's Library Mode syncs deltas instead of re-crawling the server — without
# it, new episodes reach the Apple TV only when Infuse gets round to a full
# rescan. hosts/ultraviolet/services/jellyfin.nix copies $out into Jellyfin's
# plugins dir. Keep `version` in step with a release whose meta.json targetAbi
# matches the Jellyfin major in nixpkgs (1.5.3 = targetAbi 12.0.0.0).
{
  lib,
  fetchzip,
}:
fetchzip rec {
  pname = "infusesync";
  version = "1.5.3";
  url = "https://github.com/firecore/InfuseSync/releases/download/v${version}/InfuseSync-jellyfin-${version}.zip";
  stripRoot = false;
  hash = "sha256-5rQOOG5MB96bva1EFSCzOONBO3sL8hKX5d77QPUEs2U=";

  meta = {
    description = "Jellyfin plugin that tracks media changes for fast Infuse library sync";
    homepage = "https://github.com/firecore/InfuseSync";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.all;
  };
}
