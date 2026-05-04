# Keep NextDNS linked IP updated.
# NextDNS identifies this network by public IP. When the ISP rotates it,
# queries arrive with "no profile". This timer pings the linked-IP endpoint
# every 5 minutes so NextDNS always knows our current address.
{
  pkgs,
  config,
  ...
}: {
  age.secrets."nextdns-linkip-url" = {
    file = ../../../secrets/hosts/ultraviolet/nextdns-linkip-url.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  systemd.services.nextdns-linkip = {
    description = "Update NextDNS linked IP";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "nextdns-linkip" ''
        URL=$(${pkgs.coreutils}/bin/cat ${config.age.secrets."nextdns-linkip-url".path})
        ${pkgs.curl}/bin/curl -sf "$URL" > /dev/null
      '';
      User = "root";
    };
  };

  systemd.timers.nextdns-linkip = {
    description = "Update NextDNS linked IP every 5 minutes";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
      Persistent = true;
    };
  };
}
