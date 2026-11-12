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

  # The default reachableCommand. Exits 0 only when tailscaled is Running and
  # either sees the node online or can reach a DERP relay (so a control-server
  # outage alone does not fail it), sshd listens on port 22, and a transient
  # unit starts and exits 0 in user.slice within 10 seconds.
  reachableProbe = pkgs.writeShellScript "ec2-fleet-reachable" ''
    status=$(${config.services.tailscale.package}/bin/tailscale status --json) || exit 1
    jq -e '.BackendState == "Running"' <<< "$status" > /dev/null || exit 1
    if ! jq -e '.Self.Online == true' <<< "$status" > /dev/null; then
      ${config.services.tailscale.package}/bin/tailscale netcheck --format=json \
        | jq -e '(.PreferredDERP // 0) != 0' > /dev/null || exit 1
    fi
    systemctl is-active --quiet sshd.service || exit 1
    ss -Htln '( sport = :22 )' | grep -q . || exit 1
    timeout 10 systemd-run --quiet --wait --collect --slice=user.slice ${pkgs.coreutils}/bin/true
  '';

  # Checked every 30 seconds. Uptime past MAX_SECONDS powers off regardless of
  # activity; otherwise the box powers off once it has been idle for
  # IDLE_SECONDS. A refused poweroff (e.g. a block inhibitor) is retried on
  # the next pass instead of ending the guard.
  idleGuard = pkgs.writeShellScript "ec2-idle-guard" ''
    set -u
    # An ssh connection carries a session when its logind scope (session-N.scope)
    # holds a process besides sshd-session: a shell, a running command, or a
    # background job left under it. A background job whose shell exited is
    # reparented, so the scope is what links it to the session. An idle
    # ControlPersist master has only its sshd-session process in the scope.
    # Two build servers linger after a build and do not count: the Roslyn
    # compiler server (VBCSCompiler) and an MSBuild node (dotnet with MSBuild.dll
    # and /nodemode: on its command line). Any other process, plain dotnet
    # included, counts.
    ssh_session_open() {
      for pid in $(ss -Htnp state established '( sport = :22 )' | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do
        cg=$(awk -F: '{print $3}' "/proc/$pid/cgroup" 2>/dev/null)
        case "$cg" in */session-*.scope) ;; *) continue ;; esac
        for q in $(cat "/sys/fs/cgroup$cg/cgroup.procs" 2>/dev/null); do
          comm=$(cat "/proc/$q/comm" 2>/dev/null) || continue
          case "$comm" in
            sshd-session|VBCSCompiler) ;;
            dotnet) grep -aqF MSBuild.dll "/proc/$q/cmdline" && grep -aqF /nodemode: "/proc/$q/cmdline" || return 0 ;;
            *) return 0 ;;
          esac
        done
      done
      return 1
    }
    last_busy=$(date +%s)
    last_reachable=$last_busy
    while true; do
      sleep 30
      now=$(date +%s)
      # The heartbeat write runs in the background under a timeout, so a
      # blocked or failing /dev/ttyS0 neither stalls the loop nor ends the guard.
      timeout 10 ${pkgs.runtimeShell} -c "echo ec2-fleet-heartbeat $now > /dev/ttyS0" 2>/dev/null &
      read -r up _ < /proc/uptime
      up=$(cut -d. -f1 <<< "$up")
      if [ "$up" -ge "$MAX_SECONDS" ]; then
        echo "uptime $up s reached the $MAX_SECONDS s lifetime; powering off"
        systemctl --no-block poweroff && exit 0
      fi
      # The probe runs under a bound shorter than the pass, so a hung probe
      # is a failed pass and the loop keeps its cadence. Failing for the whole
      # UNREACHABLE_SECONDS window powers off even a busy box.
      if timeout 20 ${pkgs.runtimeShell} -c ${lib.escapeShellArg cfg.reachableCommand}; then
        last_reachable=$now
      elif [ $((now - last_reachable)) -ge "$UNREACHABLE_SECONDS" ]; then
        reason="ec2-fleet-unreachable reachableCommand failed for $((now - last_reachable)) s"
        echo "$reason; powering off"
        printf '%s\n' "$reason" | timeout 10 tee /dev/ttyS0 > /dev/null 2>&1
        systemctl --no-block poweroff && exit 0
      fi
      busy=0
      if ssh_session_open; then busy=1; fi
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

  # systemd's kill messages, by MESSAGE_ID: the kernel's OOM kill of a unit,
  # and systemd-oomd's kill of a unit under pressure.
  kernelKillId = "fe6faa94e7774663a0da52717891d8ef";
  oomdKillId = "d989611b15e44c9dbf31e3c81256e4ed";
  killRecord = "/run/ec2-memory-kills";

  # Appends one line per unit per kill event, `<time> <unit> <kernel|oomd>`,
  # from the journal's structured fields alone. A unit under user@*.service is
  # dropped: the system manager repeats the kernel message there for every kill
  # under a user manager.
  memoryKills = pkgs.writeShellScript "ec2-memory-kills" ''
    set -eo pipefail
    touch ${killRecord}
    chmod 0644 ${killRecord}
    journalctl -f -n 0 -o json --no-pager MESSAGE_ID=${kernelKillId} MESSAGE_ID=${oomdKillId} \
      | jq -r --unbuffered '
          select(.MESSAGE_ID == "${kernelKillId}" or .MESSAGE_ID == "${oomdKillId}")
          | (.UNIT // .USER_UNIT) as $unit
          | select($unit != null and ($unit | test("^user@.*[.]service$") | not))
          | "\(.__REALTIME_TIMESTAMP | tonumber / 1000000 | strftime("%Y-%m-%dT%H:%M:%SZ")) \($unit) \(if .MESSAGE_ID == "${kernelKillId}" then "kernel" else "oomd" end)"
        ' >> ${killRecord}
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
    reachableCommand = lib.mkOption {
      type = lib.types.str;
      default = "${reachableProbe}";
      description = "Shell command the guard runs each pass under a time bound; the box is unreachable while it does not exit 0.";
    };
    memoryMaxPercent = lib.mkOption {
      type = lib.types.ints.between 1 99;
      default = 85;
      description = "Percent of the box's RAM that user.slice (ssh sessions, user units and Nix builds) may use. Past it the kernel OOM-kills inside the slice.";
    };
  };

  imports = [
    # Amazon AMI profile: image builder, EC2 kernel modules, metadata fetch.
    "${inputs.nixpkgs}/nixos/maintainers/scripts/ec2/amazon-image.nix"
    ../../modules/nix/defaults.nix
    ../../modules/nix/substituters.nix
    ./s3-cache.nix
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
      path = [pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.iproute2 pkgs.jq pkgs.systemd];
      environment = {
        IDLE_SECONDS = toString (cfg.idleMinutes * 60);
        MAX_SECONDS = toString (cfg.maxHours * 3600);
        UNREACHABLE_SECONDS = "1800";
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = "${idleGuard}";
      };
    };

    # Sessions, user units and Nix builds share one bound. nix-daemon is
    # socket-activated, so it joins user.slice when a client first connects.
    # systemd-oomd kills the heaviest unit in user.slice once memory pressure
    # stalls it 60 percent of the time for 30 seconds (oomd's default duration).
    systemd.slices.user.sliceConfig = {
      MemoryMax = "${toString cfg.memoryMaxPercent}%";
      ManagedOOMMemoryPressure = "kill";
      ManagedOOMMemoryPressureLimit = "60%";
    };
    systemd.services.nix-daemon.serviceConfig.Slice = "user.slice";

    # User managers default to OOMPolicy=kill: a user scope or service that
    # loses a process to a memory kill is torn down whole, so it never exits 0
    # as if it had finished.
    systemd.user.settings.Manager.DefaultOOMPolicy = "kill";

    # Each memory kill leaves a line in /run/ec2-memory-kills that any user can read.
    systemd.services.ec2-memory-kills = {
      description = "Record each memory kill in /run/ec2-memory-kills";
      wantedBy = ["multi-user.target"];
      path = [pkgs.coreutils pkgs.jq pkgs.systemd];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${memoryKills}";
      };
    };

    # tailscaled registers the node under the hostname it starts with, so it
    # starts only after the fleet hostname is set.
    systemd.services.tailscaled.after = ["ec2-fleet-identity.service"];

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
