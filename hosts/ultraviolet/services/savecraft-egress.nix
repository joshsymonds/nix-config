{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  savecraft-egress = pkgs.callPackage ../../../pkgs/savecraft-egress {
    src = inputs.savecraft-egress;
  };
in {
  age.secrets."savecraft-egress-token" = {
    file = ../../../secrets/hosts/ultraviolet/savecraft-egress-token.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  age.secrets."savecraft-canary-probe-auth" = {
    file = ../../../secrets/hosts/ultraviolet/savecraft-canary-probe-auth.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  age.secrets."savecraft-canary-openrouter-key" = {
    file = ../../../secrets/hosts/ultraviolet/savecraft-canary-openrouter-key.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  age.secrets."savecraft-canary-fixture" = {
    file = ../../../secrets/hosts/ultraviolet/savecraft-canary-fixture.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  age.secrets."savecraft-canary-access-client-id" = {
    file = ../../../secrets/hosts/ultraviolet/savecraft-canary-access-client-id.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  age.secrets."savecraft-canary-access-client-secret" = {
    file = ../../../secrets/hosts/ultraviolet/savecraft-canary-access-client-secret.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  users.users.savecraft-egress = {
    isSystemUser = true;
    group = "savecraft-egress";
  };
  users.groups.savecraft-egress = {};

  systemd.services.savecraft-egress = {
    description = "Savecraft restricted rescue egress proxy";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    restartTriggers = [config.age.secrets."savecraft-egress-token".file];

    environment = {
      SAVECRAFT_EGRESS_LISTEN_ADDR = "127.0.0.1:8489";
      SAVECRAFT_EGRESS_TOKEN_FILE = "%d/token";
    };

    serviceConfig = {
      Type = "simple";
      User = "savecraft-egress";
      Group = "savecraft-egress";
      ExecStart = lib.getExe savecraft-egress;
      Restart = "always";
      RestartSec = "5s";

      LoadCredential = [
        "token:${config.age.secrets."savecraft-egress-token".path}"
      ];

      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictSUIDSGID = true;
      CapabilityBoundingSet = "";
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      UMask = "0077";
    };
  };

  systemd.services.savecraft-waf-canary = {
    description = "Savecraft OpenRouter WAF canary";
    after = ["network-online.target"];
    wants = ["network-online.target"];

    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/install -D -m 0600 %d/fixture /var/lib/savecraft-waf-canary/fixtures/blocked-request.json";
      ExecStart = "${lib.getExe' savecraft-egress "savecraft-egress-canary"} -probe-worker-url https://egress-waf-probe.josh-cc0.workers.dev -probe-auth-file %d/probe-auth -proxy-url https://or-egress.husbuddies.gay -proxy-token-file %d/proxy-token -openrouter-key-file %d/openrouter-key -state-dir /var/lib/savecraft-waf-canary -access-client-id-file %d/access-client-id -access-client-secret-file %d/access-client-secret";
      StateDirectory = "savecraft-waf-canary";
      StateDirectoryMode = "0700";

      LoadCredential = [
        "probe-auth:${config.age.secrets."savecraft-canary-probe-auth".path}"
        "proxy-token:${config.age.secrets."savecraft-egress-token".path}"
        "openrouter-key:${config.age.secrets."savecraft-canary-openrouter-key".path}"
        "fixture:${config.age.secrets."savecraft-canary-fixture".path}"
        "access-client-id:${config.age.secrets."savecraft-canary-access-client-id".path}"
        "access-client-secret:${config.age.secrets."savecraft-canary-access-client-secret".path}"
      ];

      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictSUIDSGID = true;
      CapabilityBoundingSet = "";
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      UMask = "0077";
    };
  };

  systemd.timers.savecraft-waf-canary = {
    description = "Run the Savecraft WAF canary every 15 minutes";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*:00/15";
      Persistent = true;
    };
  };
}
