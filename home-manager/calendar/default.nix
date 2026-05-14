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
      Unit = "morgen-notifier.service";
    };
    Install.WantedBy = ["timers.target"];
  };
}
