{pkgs, ...}: let
  # All *arr services share the same .NET codebase and can deadlock.
  # When deadlocked, authenticated API requests hang forever while
  # unauthenticated ones still return 401. This health check detects
  # that condition and gracefully restarts the affected service.
  arrServices = [
    {
      name = "sonarr";
      port = 8989;
      configXml = "/var/lib/sonarr/.config/NzbDrone/config.xml";
      apiVersion = "v3";
    }
    {
      name = "radarr";
      port = 7878;
      configXml = "/var/lib/radarr/.config/Radarr/config.xml";
      apiVersion = "v3";
    }
    {
      name = "readarr";
      port = 8787;
      configXml = "/var/lib/readarr/.config/Readarr/config.xml";
      apiVersion = "v1";
    }
    {
      name = "prowlarr";
      port = 9696;
      configXml = "/var/lib/prowlarr/config.xml";
      apiVersion = "v1";
    }
  ];

  healthCheckScript = pkgs.writeShellScript "media-healthcheck" ''
    #!${pkgs.bash}/bin/bash
    set -uo pipefail

    graceful_restart() {
      local name="$1"
      echo "$name: attempting graceful stop (SIGTERM)..."
      ${pkgs.systemd}/bin/systemctl kill -s SIGTERM "$name" 2>/dev/null || true
      # Wait up to 15 seconds for graceful shutdown
      for i in $(seq 1 15); do
        if ! ${pkgs.systemd}/bin/systemctl is-active --quiet "$name" 2>/dev/null; then
          break
        fi
        sleep 1
      done
      # If still running, force kill
      if ${pkgs.systemd}/bin/systemctl is-active --quiet "$name" 2>/dev/null; then
        echo "$name: still running after SIGTERM, sending SIGKILL"
        ${pkgs.systemd}/bin/systemctl kill -s SIGKILL "$name" 2>/dev/null || true
        sleep 2
      fi
      ${pkgs.systemd}/bin/systemctl start "$name"
      echo "$name: restarted"
    }

    # Check *arr services (authenticated API test)
    check_arr() {
      local name="$1" port="$2" config="$3" api_version="$4"

      if ! ${pkgs.systemd}/bin/systemctl is-active --quiet "$name"; then
        echo "$name: not running, skipping"
        return
      fi

      local api_key
      api_key=$(${pkgs.gnugrep}/bin/grep -oP '(?<=<ApiKey>)[^<]+' "$config" 2>/dev/null)
      if [[ -z "$api_key" ]]; then
        echo "$name: could not read API key, skipping"
        return
      fi

      local http_code
      http_code=$(${pkgs.curl}/bin/curl -s -m 10 -o /dev/null -w "%{http_code}" \
        -H "X-Api-Key: $api_key" \
        "http://localhost:$port/api/$api_version/system/status" 2>/dev/null)

      if [[ "$http_code" == "200" ]]; then
        echo "$name: healthy"
      else
        echo "$name: unhealthy (HTTP $http_code)"
        graceful_restart "$name"
      fi
    }

    # Check Jellyfin (unauthenticated /health endpoint)
    check_jellyfin() {
      if ! ${pkgs.systemd}/bin/systemctl is-active --quiet jellyfin; then
        echo "jellyfin: not running, skipping"
        return
      fi

      local http_code
      http_code=$(${pkgs.curl}/bin/curl -s -m 10 -o /dev/null -w "%{http_code}" \
        "http://localhost:8096/health" 2>/dev/null)

      if [[ "$http_code" == "200" ]]; then
        echo "jellyfin: healthy"
      else
        echo "jellyfin: unhealthy (HTTP $http_code)"
        graceful_restart "jellyfin"
      fi
    }

    # Check Jellyseerr (podman container, unauthenticated /api/v1/status)
    check_jellyseerr() {
      if ! ${pkgs.systemd}/bin/systemctl is-active --quiet podman-jellyseerr; then
        echo "jellyseerr: not running, skipping"
        return
      fi

      local http_code
      http_code=$(${pkgs.curl}/bin/curl -s -m 10 -o /dev/null -w "%{http_code}" \
        "http://localhost:5055/api/v1/status" 2>/dev/null)

      if [[ "$http_code" == "200" ]]; then
        echo "jellyseerr: healthy"
      else
        echo "jellyseerr: unhealthy (HTTP $http_code)"
        graceful_restart "podman-jellyseerr"
      fi
    }

    # Run all checks
    ${builtins.concatStringsSep "\n" (map (svc: ''
        check_arr "${svc.name}" "${toString svc.port}" "${svc.configXml}" "${svc.apiVersion}"
      '')
      arrServices)}
    check_jellyfin
    check_jellyseerr
  '';
in {
  systemd.services.media-healthcheck = {
    description = "Health check for media services (Sonarr, Radarr, Readarr, Prowlarr, Jellyfin, Jellyseerr)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = healthCheckScript;
    };
  };

  systemd.timers.media-healthcheck = {
    description = "Run media health check every 5 minutes";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
      Persistent = true;
    };
  };
}
