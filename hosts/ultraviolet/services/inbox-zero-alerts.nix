# Watcher that alerts via Home Assistant (notify.mobile_app_spire) when an
# Inbox Zero email account's Gmail refresh token has been revoked. The signal
# is the literal string Google returns on every webhook attempt once a refresh
# token is dead: "Token has been expired or revoked."
#
# The HA long-lived token is read from the same file hass-cli already uses
# (~/.config/home-assistant/token, mode 0600) — root reads it at run time, so
# no agenix secret is needed. If that file is rotated, both this watcher and
# hass-cli pick up the new value with no further changes.
{
  pkgs,
  config,
  ...
}: let
  haTokenPath = "/home/joshsymonds/.config/home-assistant/token";
  stateDir = "/var/lib/inbox-zero-alerts";
  realertAfterSeconds = 24 * 3600;

  notifyScript = pkgs.writeShellScript "inbox-zero-alerts" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    TOKEN=$(${pkgs.coreutils}/bin/cat ${haTokenPath})

    # Scan the last 10 minutes (timer fires every 5min — overlap absorbs jitter).
    JOURNAL=$(${pkgs.systemd}/bin/journalctl -u podman-inbox-zero-web \
      --since "10 minutes ago" --no-pager -o cat)

    # Walk the journal: when we see a Gmail-scope refresh failure, capture the
    # next "email" field that appears within the same error block (within
    # 10 lines). Inbox Zero also logs Calendar-scope revocations ("Error
    # refreshing Calendar access token") with the same "Token has been
    # expired or revoked." descriptor, but those don't affect the inbox flow
    # and aren't surfaced in the IZ frontend — so we match only the Gmail
    # variant to avoid false positives.
    EMAILS=$(${pkgs.gawk}/bin/awk '
      /Error refreshing Gmail access token/ { window = 10; next }
      window > 0 {
        if (match($0, /"email":[[:space:]]*"([^"]+)"/, arr)) {
          print arr[1]
          window = 0
          next
        }
        window--
      }
    ' <<<"$JOURNAL" | ${pkgs.coreutils}/bin/sort -u)

    if [ -z "$EMAILS" ]; then
      exit 0
    fi

    NOW=$(${pkgs.coreutils}/bin/date +%s)

    while IFS= read -r EMAIL; do
      [ -z "$EMAIL" ] && continue
      SAFE=$(${pkgs.coreutils}/bin/printf '%s' "$EMAIL" | ${pkgs.coreutils}/bin/tr '@.' '__')
      STATE_FILE=${stateDir}/alerted-$SAFE

      if [ -f "$STATE_FILE" ]; then
        LAST=$(${pkgs.coreutils}/bin/cat "$STATE_FILE")
        if [ $((NOW - LAST)) -lt ${toString realertAfterSeconds} ]; then
          continue
        fi
      fi

      PAYLOAD=$(${pkgs.jq}/bin/jq -nc --arg email "$EMAIL" '{
        title: "Inbox Zero token revoked",
        message: ("Re-authorize " + $email + " at https://inbox.husbuddies.gay — Gmail says invalid_grant.")
      }')

      ${pkgs.curl}/bin/curl --fail --silent --show-error \
        -X POST http://localhost:8123/api/services/notify/mobile_app_spire \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        --data "$PAYLOAD" >/dev/null

      ${pkgs.coreutils}/bin/printf '%s' "$NOW" > "$STATE_FILE"
      echo "[alerts] notified about $EMAIL"
    done <<<"$EMAILS"
  '';

  onFailureScript = pkgs.writeShellScript "inbox-zero-alerts-onfail" ''
    #!${pkgs.bash}/bin/bash
    # If the watcher itself fails, fire a meta-notification so silent breakage
    # of the alert pipeline is also surfaced.
    TOKEN=$(${pkgs.coreutils}/bin/cat ${haTokenPath} 2>/dev/null || echo "")
    [ -z "$TOKEN" ] && exit 0
    ${pkgs.curl}/bin/curl --fail --silent --show-error \
      -X POST http://localhost:8123/api/services/notify/mobile_app_spire \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      --data '{"title":"Inbox Zero watcher failed","message":"Check journalctl -u inbox-zero-alerts on ultraviolet."}' \
      >/dev/null || true
  '';
in {
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 root root -"
  ];

  systemd.services.inbox-zero-alerts = {
    description = "Inbox Zero OAuth revocation watcher";
    after = ["podman-inbox-zero-web.service" "home-assistant.service"];
    unitConfig.OnFailure = ["inbox-zero-alerts-onfail.service"];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = notifyScript;
    };
  };

  systemd.services.inbox-zero-alerts-onfail = {
    description = "Meta-alert when inbox-zero-alerts itself fails";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = onFailureScript;
    };
  };

  systemd.timers.inbox-zero-alerts = {
    description = "Run Inbox Zero OAuth revocation watcher";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      Persistent = true;
      RandomizedDelaySec = "30s";
    };
  };
}
