{
  inputs,
  config,
  pkgs,
  hostname ? "unknown",
  ...
}: let
  # Determine if this host should run as a server or client
  isServer = hostname == "ultraviolet" || hostname == "vermissian";
  isDarwin = hostname == "cloudbank" || hostname == "ninuan";
in {
  imports = [inputs.linkpearl.homeManagerModules.default];

  # Linkpearl configuration - server mode for ultraviolet, client mode for others
  services.linkpearl = {
    enable = true;
    secretFile = "${config.xdg.configHome}/linkpearl/secret";

    # Server mode: listen on port, no join addresses
    # Client mode: don't listen, join ultraviolet (and vermissian for Darwin)
    listen =
      if isServer
      then ":9437"
      else null;
    join =
      if hostname == "vermissian"
      then ["ultraviolet:9437"] # vermissian is server but also joins ultraviolet
      else if isServer
      then [] # ultraviolet doesn't join anyone
      else if isDarwin
      then ["ultraviolet:9437" "vermissian:9437"]
      else ["ultraviolet:9437"];

    nodeId = hostname;
    verbose = false;
    pollInterval = "500ms";

    # Use the package from the linkpearl flake
    package = inputs.linkpearl.packages.${pkgs.stdenv.hostPlatform.system}.default;
  };
}
