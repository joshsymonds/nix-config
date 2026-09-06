{
  lib,
  pkgs,
}: let
  system = pkgs.stdenv.hostPlatform.system;
  binaries = {
    x86_64-linux = "agent-browser-linux-musl-x64";
    aarch64-linux = "agent-browser-linux-musl-arm64";
    x86_64-darwin = "agent-browser-darwin-x64";
    aarch64-darwin = "agent-browser-darwin-arm64";
  };
  binary = binaries.${system} or (throw "agent-browser: unsupported platform ${system}");
  chromiumAvailable = lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.chromium;
  # Nixpkgs Chromium is Linux-only today. Darwin must already have this
  # explicitly installed application; we never discover personal Chrome or
  # download a browser. --executable-path can explicitly select another one.
  chromiumExecutable =
    if chromiumAvailable
    then lib.getExe pkgs.chromium
    else if pkgs.stdenv.hostPlatform.isDarwin
    then "/Applications/Chromium.app/Contents/MacOS/Chromium"
    else throw "agent-browser requires a supported Nixpkgs Chromium package";

  config = pkgs.writeText "pi-agent-browser.json" (builtins.toJSON {
    executablePath = chromiumExecutable;
    headed = false;
    autoConnect = false;
    allowFileAccess = false;
    noWebmcp = true;
    # Deliberately omit profile/state/restore/provider/CDP. Upstream creates
    # a UUID temporary profile per browser daemon and removes it on close.
  });

  native = pkgs.stdenvNoCC.mkDerivation {
    pname = "agent-browser-native";
    version = "0.36.0";
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/agent-browser/-/agent-browser-0.36.0.tgz";
      hash = "sha256-hYp1N2ADTXPGvBfdiV+RFB7wPD/MqXg0izeOJtLWF+Q=";
    };
    sourceRoot = "package";
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      install -Dm755 bin/${binary} "$out/bin/agent-browser-native"
      install -Dm644 LICENSE "$out/share/licenses/agent-browser/LICENSE"
      install -Dm644 cli/src/native/a11y/LICENSE-axe-core.txt "$out/share/licenses/agent-browser/LICENSE-axe-core.txt"
      install -Dm644 cli/src/native/a11y/LICENSE-axe-core-THIRD-PARTY.txt "$out/share/licenses/agent-browser/LICENSE-axe-core-THIRD-PARTY.txt"
      runHook postInstall
    '';
    meta = {
      description = "Pinned upstream native agent-browser, without npm or installers";
      license = lib.licenses.asl20;
      platforms = builtins.attrNames binaries;
    };
  };
in {
  extension = pkgs.fetchzip {
    name = "pi-agent-browser-native-0.6.6";
    url = "https://registry.npmjs.org/pi-agent-browser-native/-/pi-agent-browser-native-0.6.6.tgz";
    hash = "sha256-B5bORvUtLetBJrnUHhJQU9nB0kTZbV9NcJJEU8od5IQ=";
  };

  # Also available to the Pi launcher, so extension-side launch/restore
  # planning sees the same defaults. The CLI wrapper reasserts this even
  # when script mode strips AGENT_BROWSER_* from the child environment.
  inherit config chromiumExecutable;
  cli = pkgs.writeShellScriptBin "agent-browser" ''
    # Defaults, not a sandbox: explicit upstream CLI flags (including
    # --config, --profile and --cdp) retain their normal precedence.
    # Keep only routing/timeout/lifecycle env required by the extension;
    # do not inherit personal profiles, providers, proxies, restore state,
    # browser args/extensions, auto-connect, CDP, or alternate config.
    for name in "''${!AGENT_BROWSER_@}"; do
      case "$name" in
        AGENT_BROWSER_SESSION|AGENT_BROWSER_NAMESPACE|AGENT_BROWSER_SOCKET_DIR|AGENT_BROWSER_DEFAULT_TIMEOUT|AGENT_BROWSER_IDLE_TIMEOUT_MS|AGENT_BROWSER_AUTOSAVE_INTERVAL_MS) ;;
        *) unset "$name" ;;
      esac
    done
    export AGENT_BROWSER_CONFIG=${lib.escapeShellArg (toString config)}
    exec ${native}/bin/agent-browser-native "$@"
  '';
}
