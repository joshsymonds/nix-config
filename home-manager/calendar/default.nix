{
  config,
  lib,
  pkgs,
  ...
}: let
  configHome = config.xdg.configHome;
  dataHome = config.xdg.dataHome;

  # khal expects a vdir-style directory of one-event-per-.ics files; the
  # morgen-fetch tool below writes there, and the path is also the `path`
  # we hand khal in its config so both ends agree.
  vdirPath = "${dataHome}/vdirs/morgen";
  # morgen-fetch is a real package now (pkgs/morgen-fetch/) — see overlay
  # `morgen-fetch` entry. It polls Morgen's REST API and writes ICS files
  # into a vdir; tests live next to its source.
in {
  # khal is still pulled in by DMS's enableCalendarEvents toggle; we just
  # add the fetcher.
  home.packages = [pkgs.morgen-fetch];

  # Morgen API key — encrypted with joshsymonds's age key (see
  # secrets/secrets.nix). agenix decrypts at activation into a path under
  # /run/user/$UID/agenix/ owned by the user; the systemd unit passes
  # that path to morgen-fetch via $MORGEN_FETCH_KEY_FILE.
  age.secrets."morgen-api-key" = {
    file = ../../secrets/user/morgen-api-key.age;
  };

  # The HTTP trigger URL for the morgen-mirror-workflow Custom
  # Workflow (https://github.com/joshsymonds/morgen-mirror-workflow).
  # Anyone with this URL can fire the workflow against Josh's
  # account, so it's agenix-encrypted alongside the API key.
  age.secrets."morgen-mirror-trigger-url" = {
    file = ../../secrets/user/morgen-mirror-trigger-url.age;
  };

  # khal config. `type = discover` walks subdirectories of `path` and treats
  # each as a collection — morgen-fetch writes everything into a single
  # `primary/` subdirectory, so we get one collection containing all of the
  # user's Google + M365 events flattened into the bar widget's view.
  xdg.configFile."khal/config".text = ''
    [calendars]
    [[morgen]]
    path = ${vdirPath}/*
    type = discover

    [locale]
    timeformat = %H:%M
    dateformat = %Y-%m-%d
    longdateformat = %Y-%m-%d
    datetimeformat = %Y-%m-%d %H:%M
    longdatetimeformat = %Y-%m-%d %H:%M
    firstweekday = 0
  '';

  # 5-minute timer on the wall clock (:00, :05, …). OnCalendar+Persistent
  # catches up missed runs after sleep/reboot: if the last successful run
  # was >5 min ago, systemd fires once on next activation. Do NOT swap
  # back to OnUnitActiveSec — monotonic timers + Persistent across reboots
  # leave NextElapseUSecMonotonic=infinity (the wedge that prompted this:
  # fetcher silently stopped for 19h, pill displayed past events as "now").
  # Oneshot service so `systemctl status` shows the last run's exit code.
  systemd.user.services.morgen-fetch = {
    Unit = {
      Description = "Fetch upcoming events from Morgen API into khal vdir";
      Documentation = "https://docs.morgen.so/events";
    };
    Service = {
      Type = "oneshot";
      Environment = "MORGEN_FETCH_KEY_FILE=${config.age.secrets."morgen-api-key".path}";
      ExecStart = "${pkgs.morgen-fetch}/bin/morgen-fetch";
    };
  };

  systemd.user.timers.morgen-fetch = {
    Unit.Description = "Poll Morgen API every 5 minutes";
    Timer = {
      OnCalendar = "*:0/5";
      Unit = "morgen-fetch.service";
      Persistent = true;
    };
    Install.WantedBy = ["timers.target"];
  };

  # morgen-mirror-workflow runs on Morgen's V8 isolate but doesn't
  # self-trigger — Morgen exposes a per-workflow HTTP trigger URL we
  # poke on a schedule. GET on the URL runs the workflow
  # synchronously and returns logs; we discard stdout (logs are
  # available via the API if we need them, and surfacing them on
  # every cron run would spam systemd-journal).
  systemd.user.services.morgen-mirror-trigger = {
    Unit = {
      Description = "Fire the n-way-busy-mirror workflow on Morgen";
      Documentation = "https://github.com/joshsymonds/morgen-mirror-workflow";
    };
    Service = {
      Type = "oneshot";
      # config.age.secrets.<name>.path emits a literal
      # `''${XDG_RUNTIME_DIR}/agenix/<name>` string that systemd does
      # NOT shell-expand in Environment= — references to it in a
      # bash $VAR substitution come back unexpanded. Reference
      # XDG_RUNTIME_DIR directly in the script (it's already in the
      # user manager's env) rather than threading through the
      # placeholder.
      ExecStart = pkgs.writeShellScript "morgen-mirror-trigger" ''
        set -eu
        URL="$(cat "$XDG_RUNTIME_DIR/agenix/morgen-mirror-trigger-url")"
        ${pkgs.curl}/bin/curl --silent --show-error --max-time 180 \
          --request GET --output /dev/null --fail "$URL"
      '';
    };
  };

  systemd.user.timers.morgen-mirror-trigger = {
    Unit.Description = "Trigger the n-way-busy-mirror workflow every 5 minutes";
    Timer = {
      OnCalendar = "*:0/5";
      Unit = "morgen-mirror-trigger.service";
      Persistent = true;
    };
    Install.WantedBy = ["timers.target"];
  };

  # morgen-notifier fires notify-send at T-10 min and T-2 min for each
  # upcoming meeting from upcoming-events.json. 60-second timer cadence
  # is the maximum that still hits every threshold (the tool uses a
  # ±30 s tolerance band; widening the cadence would let notifications
  # slip between ticks).
  #
  # Suspend / resume note: Persistent= is intentionally omitted even
  # though this is now an OnCalendar= timer. Burst-firing missed T-10
  # and T-2 notifications on wake would be worse than dropping them —
  # the user does not want 12 stacked "meeting in 10 min" toasts for
  # meetings they slept through. The pill (still showing correct
  # urgency-colored countdown on resume) is the primary at-a-glance
  # signal; the notifier is secondary and may drop missed instants.
  #
  # No Environment= needed: morgen-notifier reads upcoming-events.json
  # from the user's data dir and writes its dedup state to the user's
  # cache dir; no secrets, no per-user paths to inject.
  systemd.user.services.morgen-notifier = {
    Unit = {
      Description = "Fire notify-send at T-10 and T-2 for upcoming Morgen meetings";
      Documentation = "https://github.com/joshsymonds/nix-config/tree/main/pkgs/morgen-notifier";
      After = ["morgen-fetch.service"];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.morgen-notifier}/bin/morgen-notifier";
    };
  };

  systemd.user.timers.morgen-notifier = {
    Unit.Description = "Run morgen-notifier every 60 seconds";
    Timer = {
      OnCalendar = "minutely";
      # AccuracySec=1s preserves the ±30 s tolerance band documented
      # above. systemd's default AccuracySec=1min lets consecutive fires
      # of a minutely timer drift up to 60 s within their respective
      # slots, so the gap between two ticks can reach ~120 s — wider
      # than the notifier's ±30 s window, leaving room for a T-10 / T-2
      # instant to fall in the gap and never fire. 1 s costs nothing on
      # this workload (one JSON read + a stat check per tick) and keeps
      # consecutive fires within ~61 s, so coverage is effectively
      # gap-free.
      AccuracySec = "1s";
      Unit = "morgen-notifier.service";
    };
    Install.WantedBy = ["timers.target"];
  };
}
