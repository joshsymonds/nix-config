# Fleet ssh client config. Uses `programs.ssh.settings` (the current HM
# schema, upstream ssh_config directive names): `matchBlocks` was
# deprecated to a warning-only shim that renders NOTHING — the per-host
# blocks below silently vanished from ~/.ssh/config fleet-wide until this
# migration (discovered when `ssh shrike` dialed port 22).
_: {
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    settings = {
      "*" = {
        # Kitty terminal integration: pass the terminal type through.
        SendEnv = "TERM COLORTERM";

        ForwardAgent = "yes";

        # Performance optimizations
        Compression = "yes";
        TCPKeepAlive = "yes";
        Ciphers = "aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com";

        # Reuse connections for faster subsequent connections
        ControlMaster = "auto";
        ControlPath = "~/.ssh/control-%C";
        ControlPersist = "2h";

        # Latency / liveness
        ServerAliveInterval = 60;
        ServerAliveCountMax = 3;
        ConnectTimeout = 10;
        EnableEscapeCommandline = "yes";
        IPQoS = "lowdelay throughput";
      };

      ultraviolet = {
        HostName = "ultraviolet";
        User = "joshsymonds";
        ForwardX11 = "yes";
        ForwardX11Trusted = "yes";
      };

      bluedesert = {
        HostName = "bluedesert";
        User = "joshsymonds";
        ForwardX11 = "yes";
        ForwardX11Trusted = "yes";
      };

      echelon = {
        HostName = "echelon";
        User = "joshsymonds";
        ForwardX11 = "yes";
        ForwardX11Trusted = "yes";
      };

      # shrike (Pixel 11, nix-on-droid): tailnet-only, sshd on 8022 started
      # by opening the app (see hosts/shrike). `ssh shrike update` converges
      # the phone remotely.
      shrike = {
        HostName = "shrike";
        User = "nix-on-droid";
        Port = 8022;
      };
    };
  };
}
