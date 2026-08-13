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
}
