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

  # 5-minute timer. OnBootSec=30s so the bar lights up shortly after login
  # rather than waiting a full 5 min for the first poll. Persistent=true
  # makes a missed run (laptop asleep) fire on next wake instead of
  # silently skipping. Oneshot service so `systemctl status` shows the
  # last run's exit code — handy for debugging API auth failures.
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
      OnBootSec = "30s";
      OnUnitActiveSec = "5m";
      Unit = "morgen-fetch.service";
      Persistent = true;
    };
    Install.WantedBy = ["timers.target"];
  };
}
