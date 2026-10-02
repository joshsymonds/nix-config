{pkgs}: let
  inherit (pkgs) lib;
  module = ../modules/services/valheim.nix;
  fakePackage = pkgs.writeShellScriptBin "valheim-server" "exit 0";
  evaluate = extraModules:
    import "${pkgs.path}/nixos/lib/eval-config.nix" {
      system = "x86_64-linux";
      specialArgs = {inherit pkgs;};
      modules = [module] ++ extraModules;
    };
  disabled = (evaluate []).config;
  enabled =
    (evaluate [
      {
        services.valheim = {
          enable = true;
          package = fakePackage;
          passwordFile = "/run/valheim-test-password";
        };
      }
    ]).config;
  passwordless =
    (evaluate [
      {
        services.valheim = {
          enable = true;
          package = fakePackage;
          passwordFile = null;
        };
      }
    ]).config.systemd.services.valheim.serviceConfig.ExecStart;
  fakePack = pkgs.runCommand "fake-bepinex-pack" {} ''
    mkdir -p "$out/BepInEx/core" "$out/BepInEx/config" "$out/doorstop_libs"
    touch "$out/BepInEx/core/BepInEx.Preloader.dll" "$out/BepInEx/config/BepInEx.cfg" \
      "$out/doorstop_libs/libdoorstop_x64.so"
  '';
  fakePlugin = pkgs.runCommand "fake-plugin" {} ''
    mkdir -p "$out"
    touch "$out/Example.dll"
  '';
  modded =
    (evaluate [
      {
        services.valheim = {
          enable = true;
          package = fakePackage;
          passwordFile = null;
          bepinex = {
            enable = true;
            pack = fakePack;
            plugins.Example = fakePlugin;
            configFiles."example.cfg" = ''
              [General]
              Key = 1
            '';
          };
        };
      }
    ]).config.systemd.services.valheim.serviceConfig.ExecStart;
  service = enabled.systemd.services.valheim;
  unit = service.serviceConfig;
  launcher = unit.ExecStart;
  stopper = unit.ExecStop;
in
  assert !(disabled.systemd.services ? valheim);
  assert !(disabled.users.users ? valheim);
  assert !(disabled.users.groups ? valheim);
  assert enabled.users.users.valheim.isSystemUser;
  assert enabled.users.users.valheim.group == "valheim";
  assert enabled.users.users.valheim.home == "/var/lib/valheim";
  assert enabled.users.groups ? valheim;
  assert service.wantedBy == ["multi-user.target"];
  assert service.environment.HOME == "/var/lib/valheim";
  assert unit.User == "valheim";
  assert unit.Group == "valheim";
  assert unit.StateDirectory == "valheim";
  assert unit.StateDirectoryMode == "0700";
  assert unit.WorkingDirectory == "/var/lib/valheim";
  assert unit.Restart == "on-failure";
  assert unit.KillSignal == "SIGINT";
  assert unit.LimitCORE == 0;
  assert unit.StandardOutput == "null";
  assert unit.StandardError == "null";
  assert unit.UMask == "0077";
    pkgs.runCommand "valheim-fast-test" {} ''
      set -eu
      grep -F -- '-nographics' ${launcher}
      grep -F -- '-batchmode' ${launcher}
      grep -F -- '-disable-crash-handler' ${launcher}
      grep -F -- '-logFile -' ${launcher}
      grep -F -- '-name Midgard' ${launcher}
      grep -F -- '-world Midgard' ${launcher}
      grep -F -- '-port 2456' ${launcher}
      grep -F -- '-public 0' ${launcher}
      grep -F -- '-savedir /var/lib/valheim' ${launcher}
      if grep -F -- '-crossplay' ${launcher}; then
        echo 'unexpected crossplay' >&2
        exit 1
      fi
      grep -F -- '/var/lib/valheim/logs' ${launcher}
      grep -F -- 'valheim-current.log' ${launcher}
      grep -F -- 'valheim invocation start' ${launcher}
      grep -F -- 'valheim invocation exit status=' ${launcher}
      grep -F -- '>> "$log_file" 2>&1' ${launcher}
      grep -F -- 'valheim_server.x86_64' ${stopper}
      grep -F -- 'kill -INT' ${stopper}
      grep -F -- 'valheim password file is missing or unreadable' ${launcher}
      grep -F -- 'valheim password is invalid' ${launcher}
      grep -F -- '-password "$password"' ${launcher}
      grep -F -- 'password=""' ${passwordless}
      grep -F -- '-password "$password"' ${passwordless}
      grep -F -- '-public 0' ${passwordless}
      if grep -Eq 'password_file=|valheim password is' ${passwordless}; then
        echo 'passwordless launcher unexpectedly requires a credential' >&2
        exit 1
      fi
      if grep -Eq 'DOORSTOP|VALHEIM_LD_PRELOAD|bepinex' ${launcher}; then
        echo 'vanilla launcher unexpectedly loads BepInEx' >&2
        exit 1
      fi
      grep -F -- 'export DOORSTOP_ENABLED=1' ${modded}
      grep -F -- 'export DOORSTOP_TARGET_ASSEMBLY="/var/lib/valheim/bepinex/BepInEx/core/BepInEx.Preloader.dll"' ${modded}
      grep -F -- 'export VALHEIM_LD_PRELOAD=${fakePack}/doorstop_libs/libdoorstop_x64.so' ${modded}
      grep -F -- '${fakePack}/BepInEx/core "/var/lib/valheim/bepinex/BepInEx/core"' ${modded}
      grep -F -- "${fakePlugin} /var/lib/valheim/bepinex/BepInEx/plugins/Example" ${modded}
      grep -F -- "/var/lib/valheim/bepinex/BepInEx/config/example.cfg" ${modded}
      grep -F -- '-password "$password"' ${modded}
      touch "$out"
    ''
