{
  pkgs,
  lib,
  osConfig,
  ...
}: let
  # A second Firefox that only ever talks through the host's VPN exit
  # (modules/services/vpn-exit.nix), present where the exit publishes its
  # HTTP proxy and nowhere else. Desktops only; ssh-vpn is in ./default.nix.
  exit = osConfig.services.vpn-exit or {};
  enabled = (exit.enable or false) && (exit.httpProxy.enable or false);
  port = toString (exit.httpProxy.port or 8888);
  provider = exit.serviceProvider or "vpn";

  appId = "firefox-vpn";
  profileDir = ".mozilla/firefox-vpn";

  # Loud on purpose, so this window is never mistaken for the everyday one.
  # Mullvad's own yellow and navy.
  yellow = "#ffd524";
  navy = "#192e45";
  label = "VPN · ${provider}";

  # Firefox's proxy settings, plus every path that would go around the proxy.
  # The everyday profile's ui.key.menuAccessKey=0 applies here for the same
  # reason (home-manager/firefox).
  userJs = pkgs.writeText "firefox-vpn-user.js" ''
    // Managed by nix-config (home-manager/vpn-exit). Do not edit.
    user_pref("network.proxy.type", 1);
    user_pref("network.proxy.http", "127.0.0.1");
    user_pref("network.proxy.http_port", ${port});
    user_pref("network.proxy.ssl", "127.0.0.1");
    user_pref("network.proxy.ssl_port", ${port});
    user_pref("network.proxy.share_proxy_settings", true);
    user_pref("network.proxy.failover_direct", false);
    // WebRTC can reveal the real address; DoH and DNS prefetch resolve outside
    // the proxy; HTTP/3 is UDP, which an HTTP proxy doesn't carry.
    user_pref("media.peerconnection.enabled", false);
    user_pref("network.trr.mode", 5);
    user_pref("network.dns.disablePrefetch", true);
    user_pref("network.prefetch-next", false);
    user_pref("network.predictor.enabled", false);
    user_pref("network.http.http3.enable", false);
    // No Firefox account: signing in would tie this profile to the everyday one.
    user_pref("identity.fxaccounts.enabled", false);
    user_pref("datareporting.healthreport.uploadEnabled", false);
    user_pref("toolkit.telemetry.enabled", false);
    user_pref("browser.startup.page", 3);
    user_pref("ui.key.menuAccessKey", 0);
    user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
  '';

  userChrome = ''
    /* Managed by nix-config (home-manager/vpn-exit). */
    #navigator-toolbox, #TabsToolbar, #nav-bar, #PersonalToolbar {
      background: ${yellow} !important;
      color: ${navy} !important;
    }
    #nav-bar { border-bottom: 3px solid ${navy} !important; }
    #urlbar-background {
      background: #fff6c4 !important;
      border: 2px solid ${navy} !important;
    }
    #urlbar-input, .tab-label { color: ${navy} !important; }
    .tabbrowser-tab[selected] .tab-background { background: ${navy} !important; }
    .tabbrowser-tab[selected] .tab-label { color: ${yellow} !important; }
    .toolbarbutton-1, .tab-close-button { fill: ${navy} !important; color: ${navy} !important; }
    #TabsToolbar-customization-target::before {
      content: "${label}";
      align-self: center;
      padding: 0 12px;
      font-weight: bold;
      letter-spacing: 0.1em;
      color: ${navy};
    }
  '';

  userContent = ''
    /* Managed by nix-config (home-manager/vpn-exit). */
    @-moz-document url("about:newtab"), url("about:home"), url("about:blank") {
      html, body {
        --newtab-background-color: ${navy} !important;
        background-color: ${navy} !important;
      }
    }
  '';

  # Refuses to start unless the proxy answers from inside the tunnel, so a
  # down exit never shows up as a browser that quietly fails.
  check =
    if provider == "mullvad"
    then ''
      reply=$(${pkgs.curl}/bin/curl -fsS --max-time 10 --proxy "$proxy" https://am.i.mullvad.net/connected 2>&1) || true
      [[ $reply == "You are connected to Mullvad"* ]]
    ''
    else ''
      reply=$(${pkgs.curl}/bin/curl -fsS --max-time 10 --proxy "$proxy" -o /dev/null -w '%{http_code}' https://example.com 2>&1) || true
      [[ $reply == 200 ]]
    '';

  launcher = pkgs.writeShellScriptBin "firefox-vpn" ''
    set -euo pipefail
    proxy=http://127.0.0.1:${port}
    if ! { ${check} }; then
      ${pkgs.libnotify}/bin/notify-send -u critical "Firefox (${label})" "Not starting: the VPN exit at $proxy isn't connected. $reply"
      echo "firefox-vpn: not starting, the VPN exit at $proxy isn't connected: $reply" >&2
      exit 1
    fi
    # --name sets the Wayland app-id, which keeps links opened from other
    # apps out of this instance and gives niri something to match.
    exec ${pkgs.firefox}/bin/firefox --name ${appId} --profile "$HOME/${profileDir}" "$@"
  '';
in {
  config = lib.mkIf enabled {
    home.packages = [launcher];

    home.file = {
      "${profileDir}/user.js".source = userJs;
      "${profileDir}/chrome/userChrome.css".text = userChrome;
      "${profileDir}/chrome/userContent.css".text = userContent;
    };

    # No MimeType, so it never becomes the handler for links.
    xdg.desktopEntries.${appId} = {
      name = "Firefox (${label})";
      genericName = "Web Browser";
      exec = "firefox-vpn %U";
      icon = "firefox";
      terminal = false;
      categories = ["Network" "WebBrowser"];
      settings.StartupWMClass = appId;
    };

    # A yellow frame drawn on the window itself, focused or not.
    programs.niri.settings.window-rules = [
      {
        matches = [{app-id = "^${appId}$";}];
        border = {
          enable = true;
          width = 4;
          active.color = yellow;
          inactive.color = yellow;
        };
        focus-ring.active.color = yellow;
      }
    ];
  };
}
