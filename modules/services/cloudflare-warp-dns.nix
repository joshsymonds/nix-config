{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.cloudflareWarpDns;
  device = "sys-subsystem-net-devices-${cfg.interface}.device";
  tailscaleDevice = "sys-subsystem-net-devices-${config.services.tailscale.interfaceName}.device";
in {
  options.services.cloudflareWarpDns = {
    enable = lib.mkEnableOption ''
      routing DNS through the Cloudflare WARP resolver whenever the WARP
      interface is up.

      The upstream cloudflare-warp service points /etc/resolv.conf at the WARP
      stub resolver, but glibc resolves through nsswitch -> systemd-resolved,
      which answers from the physical link instead and never consults that
      file. Gateway then sees none of the lookups, so it cannot attribute a
      hostname to a connection and FQDN-based Gateway policies never match.

      Setting the resolver on the WARP link itself, with a "~." routing domain
      so it becomes the default route for DNS, is what makes those policies
      apply. It is scoped to the link on purpose: while WARP is disconnected
      the interface is gone, nothing points at a dead stub resolver, and
      ordinary DNS is untouched
    '';

    interface = lib.mkOption {
      type = lib.types.str;
      default = "CloudflareWARP";
      description = "Name of the WARP tunnel interface.";
    };

    resolvers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["127.0.2.2" "127.0.2.3"];
      description = ''
        Stub resolver addresses the WARP client listens on. Defaults match what
        the client writes into /etc/resolv.conf.
      '';
    };

    tailnetDomain = lib.mkOption {
      type = lib.types.str;
      default = "tail82223.ts.net";
      description = ''
        MagicDNS suffix of the tailnet. With Tailscale on the host, its names
        are routed to the Tailscale resolver on the tailscale0 link, and the
        suffix doubles as the search domain so short host names resolve.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.resolved.enable;
        message = "services.cloudflareWarpDns needs systemd-resolved, which owns the per-link DNS configuration it sets.";
      }
    ];

    # networkd defaults to ManageForeignRoutingPolicyRules=yes: every restart
    # (any rebuild whose networkd config changed) deletes routing policy rules
    # it does not own, including warp-svc's `not fwmark 0x100cf lookup 65743`.
    # warp-svc only reinstalls that rule on reconnect, and in full-tunnel mode
    # its leak-protection nftables table keeps dropping all egress in the
    # meantime — the host loses DNS and internet until WARP is bounced.
    systemd.network.config.networkConfig.ManageForeignRoutingPolicyRules = false;

    # Bound to the interface's device unit rather than to cloudflare-warp.service:
    # the link appears on connect and disappears on disconnect, so this reapplies
    # on every reconnect and after a reboot without ordering against the daemon.
    #
    # The interface stays unmanaged by systemd-networkd. Claiming it with a
    # .network file would also hand networkd the addresses and routes that
    # warp-svc maintains itself.
    systemd.services.cloudflare-warp-dns = {
      description = "Route DNS through the Cloudflare WARP resolver";
      bindsTo = [device];
      after = [device];
      wantedBy = [device];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = [
          "${pkgs.systemd}/bin/resolvectl dns ${cfg.interface} ${lib.concatStringsSep " " cfg.resolvers}"
          # "~." makes this link the default route for DNS. More specific
          # routing domains still win, so Tailscale keeps resolving its own
          # MagicDNS names on tailscale0.
          "${pkgs.systemd}/bin/resolvectl domain ${cfg.interface} '~.'"
        ];
      };
    };

    # Tailscale must not manage DNS on a WARP host. While WARP is connected it
    # owns /etc/resolv.conf as a plain file, so a tailscaled (re)start detects
    # no systemd-resolved, falls back to its direct manager and rewrites the
    # file. WARP reverts it, tailscaled restarts systemd-resolved on every
    # "trample", and resolved hits its start limit: DNS is dead for the whole
    # host (vermissian, 2026-10-20, on a switch that bumped tailscale). With
    # --accept-dns=false tailscaled leaves DNS alone, and the MagicDNS route it
    # would have programmed into resolved is set here instead.
    services.tailscale.extraSetFlags = lib.mkIf config.services.tailscale.enable ["--accept-dns=false"];

    # Bound to the tailscale0 device for the same reason as above: tailscaled
    # recreates the link on every restart, which drops its per-link DNS.
    systemd.services.tailscale-magicdns = lib.mkIf config.services.tailscale.enable {
      description = "Route MagicDNS names to the Tailscale resolver";
      bindsTo = [tailscaleDevice];
      after = [tailscaleDevice];
      wantedBy = [tailscaleDevice];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = [
          "${pkgs.systemd}/bin/resolvectl dns ${config.services.tailscale.interfaceName} 100.100.100.100 fd7a:115c:a1e0::53"
          # Routing and search domain at once (no "~"): MagicDNS names go to
          # quad100 ahead of WARP's "~.", and short host names expand.
          "${pkgs.systemd}/bin/resolvectl domain ${config.services.tailscale.interfaceName} ${cfg.tailnetDomain}"
        ];
      };
    };
  };
}
