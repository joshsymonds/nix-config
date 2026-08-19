# LiveKit — the self-hosted SFU carrying voice between browser clients and
# the Mentat voice agent. Tailnet-only by construction: signaling is
# loopback-bound behind `tailscale serve`, media is firewalled to
# tailscale0, and ICE advertises nothing but the 100.x address.
{
  pkgs,
  config,
  ...
}: let
  # ultraviolet's tailnet IPv4, from `tailscale ip -4 ultraviolet`
  # (2026-08-19). Hardcoded because livekit needs the ICE candidate address
  # at config-generation time and `rtc.use_external_ip` STUN discovery would
  # find the *public* IP — exactly the address we don't want advertised.
  tailnetIPv4 = "100.66.32.65";

  # Signaling/RoomService HTTP port (loopback only; `tailscale serve` fronts it).
  signalPort = 7880;
  # HTTPS port `tailscale serve` publishes on the tailnet. 8443 is shimmer's,
  # 8485 is mentatd's.
  servePort = 7443;
  # ICE/TCP fallback listener. livekit's own default is 7881; pinned here so
  # the firewall rule below and the server agree on one number.
  iceTcpPort = 7881;
  # UDP media range. Matches the nixpkgs module's defaults, pinned for the
  # same reason.
  mediaPortStart = 50000;
  mediaPortEnd = 51000;

  tailnetHost = "ultraviolet.tail82223.ts.net";
in {
  # `<api-key>: <api-secret>` YAML map. root:root 0400 rather than the
  # service user: the module runs livekit under DynamicUser and hands the
  # file over with LoadCredential, which systemd reads as PID 1 before
  # dropping privileges (same reason as atticd-env).
  age.secrets."livekit-keys" = {
    file = ../../../secrets/hosts/ultraviolet/livekit-keys.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  services.livekit = {
    enable = true;
    keyFile = config.age.secrets."livekit-keys".path;

    # Media ports are opened on tailscale0 only, below. openFirewall would
    # open them on every interface.
    openFirewall = false;

    settings = {
      port = signalPort;
      # The API is unauthenticated at the network layer in the same spirit as
      # mentatd: binding loopback makes `tailscale serve` the only way in.
      bind_addresses = ["127.0.0.1"];

      rtc = {
        port_range_start = mediaPortStart;
        port_range_end = mediaPortEnd;
        tcp_port = iceTcpPort;
        # Advertise the tailnet address and nothing else. use_external_ip
        # takes precedence over node_ip, so it must stay false for node_ip
        # to have any effect.
        use_external_ip = false;
        node_ip = tailnetIPv4;
      };
    };
  };

  # Restart on secret rotation: the .age ciphertext store path changes on
  # re-encryption, and the unit only ever sees the constant /run/agenix path.
  systemd.services.livekit.restartTriggers = [config.age.secrets."livekit-keys".file];

  # Media is reachable from the tailnet only. tailscale0 is already in
  # `trustedInterfaces`, so these rules are belt-and-braces — the property
  # that actually matters is that these ports appear in NO global
  # allowedTCPPorts/allowedUDPPortRanges, so LAN and WAN traffic hits the
  # default drop.
  networking.firewall.interfaces."tailscale0" = {
    allowedUDPPortRanges = [
      {
        from = mediaPortStart;
        to = mediaPortEnd;
      }
    ];
    allowedTCPPorts = [iceTcpPort];
  };

  # Tailnet ingress for signaling. HTTPS on 7443 — 8443 is shimmer's, 8485
  # is mentatd's. NEVER `tailscale funnel`.
  #
  # No `serve reset` here: shimmer-tailnet-serve owns the reset (it runs
  # first; we order after it) and re-adding the same mapping is idempotent.
  # Resetting here would clobber shimmer's and mentatd's mappings whenever
  # this unit restarts on its own.
  #
  # partOf: shimmer's reset wipes ALL serve mappings, and a shimmer restart
  # re-runs it. Without restart propagation here the 7443 mapping silently
  # dies; partOf + after means this unit re-runs afterwards and re-adds it.
  systemd.services.livekit-tailnet-serve = {
    description = "Tailscale serve front for livekit";
    after = ["tailscaled.service" "livekit.service" "shimmer-tailnet-serve.service"];
    requires = ["tailscaled.service" "livekit.service"];
    wants = ["shimmer-tailnet-serve.service"];
    partOf = ["shimmer-tailnet-serve.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      for i in $(seq 1 30); do
        if ${pkgs.iproute2}/bin/ss -ltn 2>/dev/null | grep -q '127.0.0.1:${toString signalPort}'; then
          break
        fi
        sleep 1
      done
      exec ${pkgs.tailscale}/bin/tailscale serve --bg --https=${toString servePort} ${toString signalPort}
    '';
  };

  # Mints a 24h join token for the pinned "office" room and prints the
  # meet.livekit.io URL that uses it. Reads the API keypair out of the
  # agenix runtime path, which is root-only — run it as `sudo voice-token`.
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "voice-token";
      text = ''
        keyfile=${config.age.secrets."livekit-keys".path}

        if [ ! -r "$keyfile" ]; then
          echo "voice-token: cannot read $keyfile — run as root (sudo voice-token)" >&2
          exit 1
        fi

        # The key file is a one-entry YAML map: `<api-key>: <api-secret>`.
        api_key=$(${pkgs.gnused}/bin/sed -n 's/^\([^:[:space:]]\+\)[[:space:]]*:.*$/\1/p' "$keyfile" | ${pkgs.coreutils}/bin/head -n 1)
        api_secret=$(${pkgs.gnused}/bin/sed -n 's/^[^:]\+:[[:space:]]*\(.\+\)$/\1/p' "$keyfile" | ${pkgs.coreutils}/bin/head -n 1)

        if [ -z "$api_key" ] || [ -z "$api_secret" ]; then
          echo "voice-token: could not parse '<api-key>: <api-secret>' out of $keyfile" >&2
          exit 1
        fi

        token=$(${pkgs.livekit-cli}/bin/lk token create \
          --api-key "$api_key" \
          --api-secret "$api_secret" \
          --join \
          --room office \
          --identity gnomon \
          --valid-for 24h \
          --token-only)

        echo "$token"
        echo
        echo "https://meet.livekit.io/custom?liveKitUrl=wss%3A%2F%2F${tailnetHost}%3A${toString servePort}&token=$token"
      '';
    })
  ];
}
