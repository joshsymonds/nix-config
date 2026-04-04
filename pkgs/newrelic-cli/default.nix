{
  lib,
  stdenv,
  fetchurl,
}: let
  version = "0.111.3";

  sources = {
    "x86_64-linux" = {
      url = "https://github.com/newrelic/newrelic-cli/releases/download/v${version}/newrelic-cli_${version}_Linux_x86_64.tar.gz";
      hash = "sha256-P7dac+eOlDIko+FmTUjZJpehCBycOTqqW5dhfPymOEU=";
    };
  };

  info = sources.${stdenv.hostPlatform.system}
    or (throw "newrelic-cli: unsupported platform ${stdenv.hostPlatform.system}");
in
  stdenv.mkDerivation {
    pname = "newrelic-cli";
    inherit version;

    src = fetchurl {
      inherit (info) url hash;
    };

    unpackPhase = ''
      tar -xzf "$src"
    '';

    installPhase = ''
      runHook preInstall
      install -Dm755 newrelic "$out/bin/newrelic"
      runHook postInstall
    '';

    meta = with lib; {
      description = "The New Relic CLI";
      homepage = "https://github.com/newrelic/newrelic-cli";
      license = licenses.asl20;
      maintainers = [];
      platforms = builtins.attrNames sources;
    };
  }
