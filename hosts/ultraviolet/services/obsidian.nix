# Headless Obsidian with Sync support
# Access via VNC for initial login: ssh -L 5900:localhost:5900 ultraviolet
# Then connect VNC client to localhost:5900
{pkgs, ...}: let
  # Virtual display configuration
  display = ":99";
  resolution = "1920x1080x24";
  vncPort = 5900;

  # Vault location
  vaultPath = "/home/joshsymonds/obsidian-vault";
in {
  # Required packages
  environment.systemPackages = with pkgs; [
    obsidian
    xvfb-run
    x11vnc
    xdotool # Useful for automation if needed
  ];

  # Ensure vault directory exists
  systemd.tmpfiles.rules = [
    "d ${vaultPath} 0755 joshsymonds users -"
  ];

  # Xvfb virtual framebuffer service
  systemd.services.xvfb = {
    description = "X Virtual Framebuffer";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      User = "joshsymonds";
      ExecStart = "${pkgs.xorg-server}/bin/Xvfb ${display} -screen 0 ${resolution} -nolisten tcp";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # x11vnc to access the virtual display (localhost only)
  systemd.services.x11vnc = {
    description = "x11vnc VNC server for Obsidian";
    after = ["xvfb.service"];
    requires = ["xvfb.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      User = "joshsymonds";
      Environment = "DISPLAY=${display}";
      # -localhost: only allow connections from localhost (SSH tunnel)
      # -forever: don't exit after first client disconnects
      # -shared: allow multiple simultaneous connections
      # -passwdfile: password from agenix secret for macOS Screen Sharing compatibility (secured by SSH tunnel)
      ExecStart = "${pkgs.x11vnc}/bin/x11vnc -display ${display} -localhost -forever -shared -passwdfile /run/agenix/x11vnc-password -rfbport ${toString vncPort}";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Obsidian running on the virtual display
  systemd.services.obsidian = {
    description = "Obsidian (headless with Sync)";
    after = ["xvfb.service" "network-online.target"];
    requires = ["xvfb.service"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      User = "joshsymonds";
      Environment = [
        "DISPLAY=${display}"
        "HOME=/home/joshsymonds"
        # Electron flags for headless operation
        "ELECTRON_DISABLE_GPU=1"
      ];
      ExecStart = "${pkgs.obsidian}/bin/obsidian";
      Restart = "always";
      RestartSec = 10;
      # Give Obsidian time to start up
      TimeoutStartSec = 60;
    };
  };
}
