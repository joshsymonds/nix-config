# tests/ec2-idle.nix
#
# nixosTest for the fleet base's idle and lifetime guard
# (hosts/ec2/base.nix, ec2-idle-guard). Each node imports the real base and
# overrides only the guard unit's thresholds, in seconds, so the test runs in
# minutes. The defaults node keeps the unit untouched and checks that the
# options map to 60 minutes and 24 hours.
{
  pkgs,
  inputs,
  outputs,
}: let
  inherit (pkgs) lib;
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;

  fleetBox = extra: {
    imports = [../hosts/ec2/base.nix extra];
    networking.hostName = lib.mkForce "ec2-idle";
    # amazon-image enables the serial console; the test driver owns it.
    systemd.services."serial-getty@ttyS0".enable = lib.mkForce false;
    users.users.joshsymonds.openssh.authorizedKeys.keys = [keys.snakeOilEd25519PublicKey];
  };

  idleSeconds = seconds: {
    systemd.services.ec2-idle-guard.environment.IDLE_SECONDS = lib.mkForce (toString seconds);
  };

  # Stand-ins for the build processes the guard checks. A process's comm is the
  # basename of the file it executed, so each is a script named for the real
  # binary. It blocks in signal.pause(): no children, no CPU.
  vbcsCompiler = pkgs.writers.writePython3Bin "VBCSCompiler" {} ''
    import signal
    signal.pause()
  '';
  dotnet = pkgs.writers.writePython3Bin "dotnet" {} ''
    import signal
    signal.pause()
  '';
in
  pkgs.testers.runNixOSTest {
    name = "ec2-idle";

    node.specialArgs = {inherit inputs outputs;};
    node.pkgsReadOnly = false;

    nodes = {
      defaults = fleetBox {};

      idleOnly = fleetBox (idleSeconds 60);

      lifetime = fleetBox {
        systemd.services.ec2-idle-guard.environment.MAX_SECONDS = lib.mkForce "120";
      };

      sshSession = fleetBox (idleSeconds 120);

      busyGate = fleetBox {
        ec2Fleet.busyCommand = "test -e /run/ec2-busy";
        systemd.services.ec2-idle-guard.environment.IDLE_SECONDS = lib.mkForce "120";
      };

      # A client VM reaches the box over the test network. Only this test node
      # opens port 22 there; the real box keeps sshd on tailscale0.
      muxBox = fleetBox ((idleSeconds 120)
        // {
          networking.firewall.allowedTCPPorts = [22];
        });

      muxClient = {};

      # A session holding only sshd-session, a VBCSCompiler and an MSBuild
      # worker node (dotnet with MSBuild.dll and /nodemode:) is not busy.
      buildServers = fleetBox ((idleSeconds 120)
        // {
          environment.systemPackages = [vbcsCompiler dotnet];
        });

      # A session holding a plain dotnet process, without /nodemode:, is busy.
      plainDotnet = fleetBox ((idleSeconds 120)
        // {
          environment.systemPackages = [dotnet];
        });

      # Every guard pass writes its heartbeat to /dev/ttyS0; the default
      # thresholds keep this node up for the whole run.
      heartbeat = fleetBox {};

      # The guard sees a FIFO with no reader as /dev/ttyS0, so each heartbeat
      # write blocks. The bind is local to the guard's unit: the test driver's
      # backdoor shell keeps the real port. The guard must still power off at
      # its idle threshold. The window is long so the node's own checks, which
      # run after the other sessions are set up, still find it up.
      blockedSerial = fleetBox {
        systemd.tmpfiles.rules = ["p /run/blocked-ttyS0 0600 root root -"];
        systemd.services.ec2-idle-guard = {
          environment.IDLE_SECONDS = lib.mkForce "480";
          serviceConfig.BindPaths = ["/run/blocked-ttyS0:/dev/ttyS0"];
        };
      };
    };

    testScript = ''
      import datetime
      import re
      import time

      start_all()

      # A bare heartbeat line at the start of a serial line. The tty turns
      # newlines into CRLF, hence the optional CR.
      heartbeat_line = re.compile(r"(?m)^ec2-fleet-heartbeat (\d+)\r?$")

      def heartbeats(node):
          return [int(e) for e in heartbeat_line.findall(node.get_console_log())]

      heartbeat.wait_for_unit("ec2-idle-guard.service")
      blockedSerial.wait_for_unit("ec2-idle-guard.service")

      idleOnly.wait_for_unit("ec2-idle-guard.service")
      lifetime.wait_for_unit("ec2-idle-guard.service")
      sshSession.wait_for_unit("ec2-idle-guard.service")
      sshSession.wait_for_unit("sshd.service")
      busyGate.wait_for_unit("ec2-idle-guard.service")
      muxBox.wait_for_unit("ec2-idle-guard.service")
      buildServers.wait_for_unit("ec2-idle-guard.service")
      buildServers.wait_for_unit("sshd.service")
      plainDotnet.wait_for_unit("ec2-idle-guard.service")
      plainDotnet.wait_for_unit("sshd.service")

      # The ssh session and the busy file go up before the idle threshold can
      # expire, so each one is what holds its box up.
      sshSession.succeed("install -m 0600 ${keys.snakeOilEd25519PrivateKey} /run/idle-key")
      sshSession.succeed("ssh -n -i /run/idle-key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null joshsymonds@localhost 'sleep 600' >/dev/null 2>&1 & echo $! > /run/idle-ssh.pid")
      sshSession.wait_until_succeeds("ss -Htn state established '( sport = :22 )' | grep -q .", timeout=60)
      busyGate.succeed("touch /run/ec2-busy")

      # The build-server session and the plain dotnet session open inside
      # their idle windows too. The build session's dotnet worker is started
      # in the background; the compiler server replaces the shell in the
      # foreground, so the session holds only those two processes.
      buildServers.succeed("install -m 0600 ${keys.snakeOilEd25519PrivateKey} /run/build-key")
      buildServers.succeed("ssh -n -i /run/build-key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null joshsymonds@localhost '${dotnet}/bin/dotnet /usr/share/dotnet/sdk/10.0.401/MSBuild.dll /noautoresponse /nologo /nodemode:1 /nodeReuse:true /low:false & exec ${vbcsCompiler}/bin/VBCSCompiler -pipename:build' >/dev/null 2>&1 &")
      buildServers.wait_until_succeeds("pgrep -x VBCSCompiler", timeout=60)
      buildServers.wait_until_succeeds("pgrep -x dotnet", timeout=60)
      buildServers.succeed("test \"$(cat /proc/$(pgrep -x VBCSCompiler)/comm)\" = VBCSCompiler")
      buildServers.succeed("test \"$(cat /proc/$(pgrep -x dotnet)/comm)\" = dotnet")
      buildServers.succeed("grep -qaF MSBuild.dll /proc/$(pgrep -x dotnet)/cmdline && grep -qaF /nodemode:1 /proc/$(pgrep -x dotnet)/cmdline")
      buildServers.wait_until_succeeds("ss -Htn state established '( sport = :22 )' | grep -q .", timeout=60)

      plainDotnet.succeed("install -m 0600 ${keys.snakeOilEd25519PrivateKey} /run/plain-key")
      plainDotnet.succeed("ssh -n -i /run/plain-key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null joshsymonds@localhost 'exec ${dotnet}/bin/dotnet /usr/share/dotnet/test/Tests.dll' >/dev/null 2>&1 & echo $! > /run/plain-ssh.pid")
      plainDotnet.wait_until_succeeds("pgrep -x dotnet", timeout=60)
      plainDotnet.succeed("test \"$(cat /proc/$(pgrep -x dotnet)/comm)\" = dotnet")
      plainDotnet.succeed("! grep -qaF /nodemode: /proc/$(pgrep -x dotnet)/cmdline")
      plainDotnet.wait_until_succeeds("ss -Htn state established '( sport = :22 )' | grep -q .", timeout=60)

      # The blocked node's guard attempts each heartbeat write into the FIFO,
      # where it sits in open(). The pattern avoids matching this command's text.
      blockedSerial.succeed("test -p /run/blocked-ttyS0")
      blockedSerial.wait_until_succeeds("pgrep -f 'heartbea[t]' >/dev/null", timeout=90)

      # A ControlPersist master left open after a command holds an established
      # :22 connection but no session. The box must still power off once idle
      # expires. The client connects right after boot, inside the idle window.
      muxBox.wait_for_unit("sshd.service")
      # Every node is named ec2-idle, so the test network cannot resolve the
      # box by name; address it by its test-network IP.
      mux_ip = muxBox.succeed("ip -4 -brief addr show dev eth1 | awk '{print $3}' | cut -d/ -f1").strip()
      muxClient.succeed("install -m 0600 ${keys.snakeOilEd25519PrivateKey} /run/mux-key")
      muxClient.succeed(f"ssh -n -i /run/mux-key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ControlMaster=auto -o ControlPath=/run/mux-ctl -o ControlPersist=2h joshsymonds@{mux_ip} true >/dev/null 2>&1")
      muxClient.succeed(f"ssh -O check -o ControlPath=/run/mux-ctl joshsymonds@{mux_ip}")
      muxBox.wait_until_succeeds("ss -Htn state established '( sport = :22 )' | grep -q .", timeout=60)
      muxBox.wait_for_shutdown(timeout=datetime.timedelta(seconds=300))

      # Uptime past the lifetime threshold powers off. Idle stays at its
      # 60-minute default, so only the lifetime check can fire here.
      lifetime.wait_for_shutdown()

      # Idle past the threshold, with nothing open and no load, powers off.
      idleOnly.wait_for_shutdown()

      # Build servers only: the session holds sshd-session, VBCSCompiler and
      # the MSBuild worker, so the box powers off within its idle window while
      # the connection stays open.
      buildServers.wait_for_shutdown(timeout=datetime.timedelta(seconds=300))

      defaults.wait_for_unit("multi-user.target")
      defaults.succeed("systemctl show -p Environment --value ec2-idle-guard.service | grep -Fw IDLE_SECONDS=3600")
      defaults.succeed("systemctl show -p Environment --value ec2-idle-guard.service | grep -Fw MAX_SECONDS=86400")

      # Load must settle so that only the session or busy file holds the box.
      sshSession.wait_until_succeeds("awk '{exit !($1 < 0.5)}' /proc/loadavg", timeout=300)
      busyGate.wait_until_succeeds("awk '{exit !($1 < 0.5)}' /proc/loadavg", timeout=300)

      # Both boxes stay up well past their idle threshold.
      sshSession.sleep(180)
      sshSession.succeed("ss -Htn state established '( sport = :22 )' | grep -q . && kill -0 $(cat /run/idle-ssh.pid)")
      busyGate.succeed("test -e /run/ec2-busy")

      # The plain dotnet session stays up after twice its idle window.
      plainDotnet.sleep(240)
      plainDotnet.succeed("pgrep -x dotnet && ss -Htn state established '( sport = :22 )' | grep -q . && kill -0 $(cat /run/plain-ssh.pid)")

      # Closing the session lets idle expire and the box powers off.
      sshSession.succeed("kill $(cat /run/idle-ssh.pid)")
      sshSession.wait_for_shutdown()

      # Releasing busy lets idle expire and the box powers off.
      busyGate.succeed("rm /run/ec2-busy")
      busyGate.wait_for_shutdown()

      # Ending the plain dotnet process closes its session; the box powers off.
      plainDotnet.succeed("pkill -x dotnet")
      plainDotnet.wait_for_shutdown(timeout=datetime.timedelta(seconds=300))

      # The blocked serial write does not stop the idle rule, nor delay it: the
      # guard's journal line, forwarded to the console with the uptime, comes
      # within boot plus one pass of the 480 s threshold.
      blockedSerial.wait_for_shutdown(timeout=datetime.timedelta(seconds=900))
      idle_off = re.search(r"\[\s*(\d+)\.\d+\] [^\n]*idle for 480 s; powering off", blockedSerial.get_console_log())
      assert idle_off is not None, "the blocked node's guard never logged its idle power-off"
      assert int(idle_off.group(1)) <= 600, f"the blocked node powered off at uptime {idle_off.group(1)} s, past its 480 s idle threshold"

      # The heartbeat node stays up with default thresholds, so its console
      # holds every pass since boot. The first pass lands within 90 seconds of
      # guard start; the newest is within 60 seconds of the VM clock; another
      # pass adds a line with a later epoch.
      guard_started = int(heartbeat.succeed('date -d "$(systemctl show -p ActiveEnterTimestamp --value ec2-idle-guard.service)" +%s').strip())
      deadline = time.monotonic() + 90
      while not heartbeats(heartbeat):
          assert time.monotonic() < deadline, "no heartbeat line on the serial console within 90 seconds"
          time.sleep(1)
      seen = heartbeats(heartbeat)
      assert seen[0] <= guard_started + 90, f"first heartbeat {seen[0]} is more than 90s after guard start {guard_started}"
      vm_now = int(heartbeat.succeed("date +%s").strip())
      assert abs(vm_now - seen[-1]) <= 60, f"heartbeat epoch {seen[-1]} is more than 60s from VM time {vm_now}"
      heartbeat.sleep(35)
      later = heartbeats(heartbeat)
      assert len(later) > len(seen) and later[-1] > seen[-1], f"no later heartbeat after another pass: {later}"
    '';
  }
