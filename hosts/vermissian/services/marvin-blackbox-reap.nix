{pkgs, ...}: {
  # Enforces the marvin-blackbox test harness's resource-reap policy: clusters
  # idle >12h, caches idle >7d, and registry tag GC. Policy lives in kluno at
  # tools/marvin-blackbox/scripts/reap.sh, versioned with the harness itself
  # rather than here.
  #
  # reap.sh currently exists only on an unmerged kluno branch, so
  # ConditionPathExists makes this a clean journaled no-op until that branch
  # merges to main.
  systemd.services.marvin-blackbox-reap = {
    description = "Reap idle marvin-blackbox clusters/caches and GC stale registry tags";
    after = ["docker.service"];
    unitConfig = {
      ConditionPathExists = "/home/joshsymonds/Work/attain/kluno/tools/marvin-blackbox/scripts/reap.sh";
    };
    path = [
      pkgs.jq
      pkgs.curl
      pkgs.docker
      pkgs.kind
      pkgs.ctlptl
      pkgs.gawk
      pkgs.coreutils
      pkgs.findutils
      pkgs.util-linux
      pkgs.bash
      pkgs.procps
      "/run/wrappers"
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "joshsymonds";
      Group = "docker";
      Environment = ["HOME=/home/joshsymonds"];
      ExecStart = "/home/joshsymonds/Work/attain/kluno/tools/marvin-blackbox/scripts/reap.sh";
    };
  };

  systemd.timers.marvin-blackbox-reap = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "hourly";
      RandomizedDelaySec = 300;
      Persistent = true;
    };
  };
}
