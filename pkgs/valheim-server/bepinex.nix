# BepInEx and server-side plugins for the dedicated server, pinned from
# Thunderstore. Consumed by services.valheim.bepinex (modules/services/valheim.nix),
# which copies them into the writable state directory at every start.
{
  fetchzip,
  runCommand,
}: let
  thunderstore = {
    owner,
    name,
    version,
    hash,
  }:
    fetchzip {
      name = "${owner}-${name}-${version}";
      url = "https://thunderstore.io/package/download/${owner}/${name}/${version}/";
      extension = "zip";
      stripRoot = false;
      inherit hash;
    };

  # A plugin's output is exactly the folder installed as BepInEx/plugins/<name>.
  plugin = {pluginDir, ...} @ args: let
    src = thunderstore (removeAttrs args ["pluginDir"]);
  in
    runCommand "valheim-plugin-${args.owner}-${args.name}-${args.version}" {} ''
      cp -r ${src}/${pluginDir} "$out"
    '';
in {
  # Root of the pack: BepInEx/{core,config}, doorstop_libs/, start scripts.
  pack = runCommand "bepinexpack-valheim-5.4.2350" {} ''
    cp -r ${thunderstore {
      owner = "denikson";
      name = "BepInExPack_Valheim";
      version = "5.4.2350";
      hash = "sha256-CKWxgI6Q/Hew5Sev5qxZiJk/dtOfUFuR9HN/iUTIVGY=";
    }}/BepInExPack_Valheim "$out"
  '';

  plugins = {
    spreadTheLoad = plugin {
      owner = "DeathMonger";
      name = "SpreadTheLoad";
      version = "0.2.1";
      hash = "sha256-Gzf5Ab38A4vRibQdZOrhOTr3HuoxBBM7fEjHK1+nB8Q=";
      pluginDir = "BepInEx/plugins";
    };
    valheimTune = plugin {
      owner = "Akoozie";
      name = "ValheimTune";
      version = "0.7.8";
      hash = "sha256-IpFg6SFgDYoVEMO1+50Pazq9cHMrGRPnfi8hJNvGWtU=";
      pluginDir = "plugins";
    };
    portalGhostFix = plugin {
      owner = "Sfantul";
      name = "PortalGhostFix";
      version = "1.0.0";
      hash = "sha256-isbSZoZT0ypXi7DBny6OoFksgJN08+oZyKKMiEsqK30=";
      pluginDir = "plugins/PortalGhostFix";
    };
    afkManager = plugin {
      owner = "Torokal";
      name = "AFKManager";
      version = "0.3.1";
      hash = "sha256-I63mWu7BheCpQNbjb6+rWWhLLK8egU3qM9/nZqHVzMI=";
      pluginDir = "plugins/AFKManager";
    };
  };
}
