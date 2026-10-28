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
    };

    testScript = ''
      start_all()

      idleOnly.wait_for_unit("ec2-idle-guard.service")
      lifetime.wait_for_unit("ec2-idle-guard.service")
      sshSession.wait_for_unit("ec2-idle-guard.service")
      sshSession.wait_for_unit("sshd.service")
      busyGate.wait_for_unit("ec2-idle-guard.service")
      muxBox.wait_for_unit("ec2-idle-guard.service")

      # The ssh session and the busy file go up before the idle threshold can
      # expire, so each one is what holds its box up.
      sshSession.succeed("install -m 0600 ${keys.snakeOilEd25519PrivateKey} /run/idle-key")
      sshSession.succeed("ssh -n -i /run/idle-key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null joshsymonds@localhost 'sleep 600' >/dev/null 2>&1 & echo $! > /run/idle-ssh.pid")
      sshSession.wait_until_succeeds("ss -Htn state established '( sport = :22 )' | grep -q .", timeout=60)
      busyGate.succeed("touch /run/ec2-busy")

      # A ControlPersist master left open after a command holds an established
      # :22 connection but no session. The box must still power off once idle
      # expires. The client connects right after boot, inside the idle window.
      import datetime
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

      # Closing the session lets idle expire and the box powers off.
      sshSession.succeed("kill $(cat /run/idle-ssh.pid)")
      sshSession.wait_for_shutdown()

      # Releasing busy lets idle expire and the box powers off.
      busyGate.succeed("rm /run/ec2-busy")
      busyGate.wait_for_shutdown()
    '';
  }
