{
  inputs,
  config,
  lib,
  pkgs,
  ...
}: let
  userData = "/etc/ec2-metadata/user-data";
  identityDir = "/run/ec2-fleet";
  cfg = config.ec2Fleet;

  busyCheck = lib.optionalString (cfg.busyCommand != null) ''
    if ${pkgs.runtimeShell} -c ${lib.escapeShellArg cfg.busyCommand}; then busy=1; fi
  '';

  # Checked every 30 seconds. Uptime past MAX_SECONDS powers off regardless of
  # activity; otherwise the box powers off once it has been idle for
  # IDLE_SECONDS. A refused poweroff (e.g. a block inhibitor) is retried on
  # the next pass instead of ending the guard.
  idleGuard = pkgs.writeShellScript "ec2-idle-guard" ''
    set -u
    last_busy=$(date +%s)
    while true; do
      sleep 30
      now=$(date +%s)
      read -r up _ < /proc/uptime
      up=$(cut -d. -f1 <<< "$up")
      if [ "$up" -ge "$MAX_SECONDS" ]; then
        echo "uptime $up s reached the $MAX_SECONDS s lifetime; powering off"
        systemctl --no-block poweroff && exit 0
      fi
      busy=0
      if ss -Htn state established '( sport = :22 )' | grep -q .; then busy=1; fi
      if awk '{exit !($1 >= 1.0)}' /proc/loadavg; then busy=1; fi
      ${busyCheck}
      if [ "$busy" -eq 1 ]; then
        last_busy=$now
      elif [ $((now - last_busy)) -ge "$IDLE_SECONDS" ]; then
        echo "idle for $IDLE_SECONDS s; powering off"
        systemctl --no-block poweroff && exit 0
      fi
    done
  '';
in {
  options.ec2Fleet = {
    idleMinutes = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Minutes without an ssh session, load, or busyCommand before the box powers off.";
    };
    maxHours = lib.mkOption {
      type = lib.types.int;
      default = 24;
      description = "Hours of uptime after which the box powers off, busy or not.";
    };
    busyCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Shell command; while it exits 0 the box counts as busy.";
    };
  };

  imports = [
    # Amazon AMI profile: image builder, EC2 kernel modules, metadata fetch.
    "${inputs.nixpkgs}/nixos/maintainers/scripts/ec2/amazon-image.nix"
    ../../modules/nix/defaults.nix
    ../../modules/nix/substituters.nix
  ];

  config = {
    system.stateVersion = "25.05";

    amazonImage.format = "raw";

    # The box reads its own user-data (see ec2-fleet-identity below), so the
    # generic amazon-init provisioning stays off.
    virtualisation.amazon-init.enable = false;

    # Name and Tailscale key come from user-data. The name becomes the
    # hostname, which Tailscale uses as the node name. Runs after
    # apply-ec2-data, which otherwise resets the hostname to the IMDS ip-… name.
    systemd.services.ec2-fleet-identity = {
      description = "Set the fleet hostname and stage the Tailscale auth key from EC2 user-data";
      wantedBy = ["multi-user.target"];
      requires = ["fetch-ec2-metadata.service"];
      after = ["fetch-ec2-metadata.service" "apply-ec2-data.service"];
      before = ["tailscaled-autoconnect.service"];
      path = [pkgs.coreutils pkgs.gnused pkgs.systemd];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        [ -s ${userData} ] || { echo "no EC2 user-data at ${userData}" >&2; exit 1; }

        name=$(sed -n 's/^EC2_FLEET_NAME=//p' ${userData} | head -n1)
        key=$(sed -n 's/^EC2_FLEET_TS_AUTHKEY=//p' ${userData} | head -n1)
        if [ -z "$name" ] || [ -z "$key" ]; then
          echo "user-data must set EC2_FLEET_NAME and EC2_FLEET_TS_AUTHKEY" >&2
          exit 1
        fi

        hostnamectl set-hostname --transient "$name"

        install -d -m 0700 ${identityDir}
        (umask 077 && printf '%s' "$key" > ${identityDir}/ts-authkey)
      '';
    };

    systemd.services.ec2-idle-guard = {
      description = "Power off the fleet box when idle or past its lifetime";
      wantedBy = ["multi-user.target"];
      path = [pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.iproute2 pkgs.systemd];
      environment = {
        IDLE_SECONDS = toString (cfg.idleMinutes * 60);
        MAX_SECONDS = toString (cfg.maxHours * 3600);
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = "${idleGuard}";
      };
    };

    systemd.services.tailscaled-autoconnect = {
      after = ["ec2-fleet-identity.service"];
      requires = ["ec2-fleet-identity.service"];
    };

    services.tailscale = {
      enable = true;
      authKeyFile = "${identityDir}/ts-authkey";
      extraUpFlags = ["--advertise-tags=tag:ec2"];
    };

    # sshd is reachable over the tailnet only: the global firewall stays
    # closed, and tailscale0 alone admits port 22.
    services.openssh = {
      enable = true;
      openFirewall = false;
      settings = {
        # amazon-image sets "prohibit-password" at normal priority; this box
        # never allows root login.
        PermitRootLogin = lib.mkForce "no";
        PasswordAuthentication = false;
      };
    };
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [22];

    users.users.joshsymonds = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      openssh.authorizedKeys.keys = import ../../lib/ssh-keys.nix;
    };

    security.sudo.extraRules = [
      {
        users = ["joshsymonds"];
        commands = [
          {
            command = "ALL";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];
  };
}
