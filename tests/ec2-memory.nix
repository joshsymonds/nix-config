# tests/ec2-memory.nix
#
# nixosTest for the fleet base's memory bound (hosts/ec2/base.nix,
# ec2Fleet.memoryMaxPercent). user.slice carries MemoryMax as a percentage of
# RAM, and nix-daemon.service runs in user.slice, so ssh sessions, user units
# and Nix builds share one bound. Every node has 2 GiB. The defaults node keeps
# the production default of 85 percent; the half node sets 50.
{
  pkgs,
  inputs,
  outputs,
}: let
  inherit (pkgs) lib;
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;

  fleetBox = extra: {
    imports = [../hosts/ec2/base.nix extra];
    networking.hostName = lib.mkForce "ec2-memory";
    # amazon-image enables the serial console; the test driver owns it.
    systemd.services."serial-getty@ttyS0".enable = lib.mkForce false;
    users.users.joshsymonds.openssh.authorizedKeys.keys = [keys.snakeOilEd25519PublicKey];
    # A lingering user keeps a user manager running, so systemd-run --user
    # has a user@UID.service to start units under.
    users.users.joshsymonds.linger = true;
    virtualisation.memorySize = 2048;
    # The VM test driver sets vm.panic_on_oom = 2 (testing/test-instrumentation.nix),
    # which turns a cgroup OOM into a kernel panic. The box keeps the kernel
    # default of 0, so a process past the bound is killed, not the VM.
    boot.kernel.sysctl."vm.panic_on_oom" = 0;
  };

  # Evaluates the real base module with one memoryMaxPercent value and reports
  # whether the option type accepts it. builtins.tryEval turns the type error
  # into a boolean.
  memoryMaxPercentAccepted = value:
    (builtins.tryEval (builtins.deepSeq
        (import "${inputs.nixpkgs}/nixos/lib/eval-config.nix" {
          system = pkgs.stdenv.hostPlatform.system;
          specialArgs = {inherit inputs outputs;};
          modules = [
            ../hosts/ec2/base.nix
            {ec2Fleet.memoryMaxPercent = value;}
          ];
        })
    .config.ec2Fleet.memoryMaxPercent
        true)).success;

  # Allocates and writes the number of bytes it is given, so every page is
  # resident before the process exits. A process past the bound is killed by
  # the kernel with SIGKILL.
  hog = pkgs.writers.writePython3Bin "hog" {} ''
    import sys
    block = b"\x01" * int(sys.argv[1])
    print("allocated", len(block))
  '';

  # Holds anonymous memory and refaults disk-backed file pages from several
  # readers; see tests/ec2-memory-thrash.py.
  thrash = pkgs.writers.writePython3Bin "ec2-memory-thrash" {} (builtins.readFile ./ec2-memory-thrash.py);
in
  if lib.all memoryMaxPercentAccepted [1 85 99] && lib.all (value: !memoryMaxPercentAccepted value) [0 100 "1G"]
  then
    pkgs.testers.runNixOSTest {
      name = "ec2-memory";

      node.specialArgs = {inherit inputs outputs;};
      node.pkgsReadOnly = false;

      nodes = {
        defaults = fleetBox {environment.systemPackages = [hog];};

        half = fleetBox {ec2Fleet.memoryMaxPercent = 50;};

        # The pressure node lowers the bound to 50 percent, oomd's limit to 1
        # percent and its duration to 10 seconds, so the thrash workload holds
        # user.slice above the limit long enough for oomd to act within the
        # test. The defaults node keeps the production values.
        pressure = fleetBox {
          ec2Fleet.memoryMaxPercent = 50;
          virtualisation.diskSize = 4096;
          environment.systemPackages = [thrash];
          systemd.slices.user.sliceConfig = {
            ManagedOOMMemoryPressureLimit = lib.mkForce "1%";
            ManagedOOMMemoryPressureDurationSec = "10s";
          };
        };
      };

      testScript = ''
        SSH = "ssh -n -i /run/mem-key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null joshsymonds@localhost"

        def mem_total(node):
            return int(node.succeed("awk '/^MemTotal:/{print $2*1024}' /proc/meminfo").strip())

        def user_slice_bound(node):
            return int(node.succeed("systemctl show user.slice -p MemoryMax --value").strip())

        def main_pid(node, unit):
            return node.succeed(f"systemctl show -p MainPID --value {unit}").strip()

        def expect_percent_of_ram(node, percent):
            total = mem_total(node)
            expected = total * percent // 100
            bound = user_slice_bound(node)
            assert abs(bound - expected) < 4096, (
                f"user.slice MemoryMax {bound} is not {percent}% of MemTotal {total} ({expected})"
            )

        start_all()

        defaults.wait_for_unit("multi-user.target")
        half.wait_for_unit("multi-user.target")
        pressure.wait_for_unit("multi-user.target")
        defaults.wait_for_unit("sshd.service")
        defaults.wait_for_unit("ec2-idle-guard.service")
        defaults.wait_for_unit("tailscaled.service")

        # R1: the bound is a percentage of RAM, at the default and at 50.
        expect_percent_of_ram(defaults, 85)
        expect_percent_of_ram(half, 50)

        # R3: production pressure kill on user.slice: kill at a 60 percent
        # limit, oomd's default 30 second duration. systemctl renders the limit
        # as a uint32 fraction of UINT32_MAX: 60% is 2576980377.
        for prop, value in [("ManagedOOMMemoryPressure", "kill"), ("ManagedOOMMemoryPressureLimit", "2576980377")]:
            got = defaults.succeed(f"systemctl show user.slice -p {prop} --value").strip()
            assert got == value, f"user.slice {prop} is {got!r}, expected {value!r}"

        # R1: nix-daemon is socket-activated; the first client connection
        # starts it in user.slice.
        defaults.succeed("NIX_REMOTE=daemon nix-store -q --references /run/current-system >/dev/null")
        daemon_pid = main_pid(defaults, "nix-daemon.service")
        assert daemon_pid != "0", "nix-daemon.service has no MainPID after a client connected"
        defaults.succeed(f"grep -qx '0::/user.slice/nix-daemon.service' /proc/{daemon_pid}/cgroup")

        # R1: an unprivileged user's transient unit and an ssh session both sit
        # under user.slice.
        defaults.succeed("install -m 0600 ${keys.snakeOilEd25519PrivateKey} /run/mem-key")
        defaults.wait_until_succeeds(f"{SSH} true", timeout=60)
        defaults.succeed(f"{SSH} 'systemd-run --user --scope cat /proc/self/cgroup' | grep -q '/user.slice/'")
        defaults.succeed(f"{SSH} 'cat /proc/self/cgroup' | grep -q '/user.slice/'")

        # R2: remember the processes that must survive the bound.
        survivors = ["sshd.service", "tailscaled.service", "ec2-idle-guard.service"]
        before = {unit: main_pid(defaults, unit) for unit in survivors}
        for unit, pid in before.items():
            assert pid != "0", f"{unit} has no MainPID before the test"

        # R2: an unprivileged process that touches more memory than the bound
        # is killed with 137. It is asked for all of RAM, which is above 85
        # percent of it.
        total = mem_total(defaults)
        rc = defaults.succeed(f"{SSH} 'hog {total} >/dev/null 2>&1; echo rc=$?'").strip()
        assert rc == "rc=137", f"hog exited with {rc}, expected rc=137"

        # R2: the kill came from the bound, not the box-wide killer.
        events = dict(
            line.split()
            for line in defaults.succeed("cat /sys/fs/cgroup/user.slice/memory.events.local").splitlines()
        )
        assert int(events["oom"]) >= 1, f"user.slice memory.events.local oom is {events['oom']}"

        # R2: sshd, tailscaled and the guard stay up with the same MainPID, and
        # the system slice saw no OOM kill.
        for unit, pid in before.items():
            defaults.succeed(f"systemctl is-active {unit}")
            assert main_pid(defaults, unit) == pid, f"{unit} MainPID changed from {pid}"
        system_events = dict(
            line.split()
            for line in defaults.succeed("cat /sys/fs/cgroup/system.slice/memory.events").splitlines()
        )
        assert int(system_events["oom_kill"]) == 0, f"system.slice oom_kill is {system_events['oom_kill']}"

        # R3: on the pressure node, an idle ssh session holds the box open while
        # a thrash unit in user.slice stalls on memory and oomd kills it.
        pressure.succeed("install -m 0600 ${keys.snakeOilEd25519PrivateKey} /run/mem-key")
        pressure.wait_until_succeeds(f"{SSH} true", timeout=60)
        pressure.succeed(f"{SSH} 'sleep 900' >/dev/null 2>&1 & echo $! > /run/pressure-ssh.pid")
        pressure.wait_until_succeeds("ss -Htn state established '( sport = :22 )' | grep -q .", timeout=60)

        def user_slice_oom(node):
            events = dict(
                line.split()
                for line in node.succeed("cat /sys/fs/cgroup/user.slice/memory.events.local").splitlines()
            )
            return int(events["oom"])

        oom_before = user_slice_oom(pressure)
        pressure.succeed(
            f"{SSH} 'systemd-run --user --unit=ec2-memory-thrash ${thrash}/bin/ec2-memory-thrash "
            f"${toString (900 * 1024 * 1024)} /var/tmp/ec2-memory-thrash.dat ${toString (1024 * 1024 * 1024)} 4'"
        )
        # Logs user.slice's memory.pressure every few seconds until oomd kills
        # the thrash unit, so the log shows the pressure oomd acted on.
        thrash_killed = f"{SSH} 'systemctl --user show -p Result --value ec2-memory-thrash.service' | grep -qx oom-kill"
        for _ in range(120):
            if pressure.execute(thrash_killed)[0] == 0:
                break
            pressure.log(
                "user.slice memory.pressure: "
                + pressure.succeed("cat /sys/fs/cgroup/user.slice/memory.pressure").replace("\n", " | ")
                + " memory.current: " + pressure.succeed("cat /sys/fs/cgroup/user.slice/memory.current").strip()
                + " memory.events: " + pressure.succeed("cat /sys/fs/cgroup/user.slice/memory.events").replace("\n", " ")
            )
            pressure.succeed("sleep 5")
        else:
            pressure.log(pressure.execute("oomctl dump; journalctl -b -u systemd-oomd --no-pager | tail -60")[1])
            raise AssertionError("oomd did not kill the thrash unit within 600 seconds")

        # R3: the kill is systemd-oomd's, not the kernel's: user.slice's
        # memory.events.local oom did not rise across it.
        oom_after = user_slice_oom(pressure)
        assert oom_after == oom_before, f"user.slice memory.events.local oom rose from {oom_before} to {oom_after}"

        # R3: the systemd-oomd kill journal entry names the thrash unit.
        journal = pressure.succeed("journalctl -b -o cat MESSAGE_ID=d989611b15e44c9dbf31e3c81256e4ed")
        assert "ec2-memory-thrash.service" in journal, f"no systemd-oomd kill of the thrash unit in the journal:\n{journal}"

        # R3: the idle ssh session stayed open through the kill.
        pressure.succeed("kill -0 $(cat /run/pressure-ssh.pid) && ss -Htn state established '( sport = :22 )' | grep -q .")
      '';
    }
  else throw "ec2Fleet.memoryMaxPercent must accept 1, 85 and 99 and reject 0, 100 and \"1G\""
