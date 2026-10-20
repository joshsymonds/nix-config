{
  lib,
  stdenv,
  fetchurl,
}: let
  version = "0.115.2";

  sources = {
    "x86_64-linux" = {
      url = "https://github.com/newrelic/newrelic-cli/releases/download/v${version}/newrelic-cli_${version}_Linux_x86_64.tar.gz";
      hash = "sha256-IYEUcP6Nu4bNPrPMktm5lz0zRLUTPusv6Ouy5x689gg=";
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
