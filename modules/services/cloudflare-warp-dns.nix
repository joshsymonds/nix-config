{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.cloudflareWarpDns;
  device = "sys-subsystem-net-devices-${cfg.interface}.device";
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
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.resolved.enable;
        message = "services.cloudflareWarpDns needs systemd-resolved, which owns the per-link DNS configuration it sets.";
      }
    ];

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
  };
}
