# tests/ec2-s3-cache.nix
#
# nixosTest for the fleet S3 cache mount (hosts/ec2/s3-cache.nix). Each node
# imports the real base and the commonframe class module, as mkEc2Class does,
# and sets ec2Fleet.s3Cache.enable. The mount's endpoints are mapped in the
# node config only: "refused" points them at 127.0.0.1, where nothing listens,
# and "blackholed" and "hung" point them at a routed address whose packets are
# dropped. "off" keeps the cache disabled and checks that the module adds no
# unit.
#
# mount-s3 gives up on its child process 30 s after start, and a test VM's
# sshd comes up only after the amazon-image metadata fetch gives up, later
# than that. So "hung" is powered off inside the 30 s window, and "blackholed"
# is checked after its unit has failed.
{
  pkgs,
  inputs,
  outputs,
}: let
  inherit (pkgs) lib;

  endpoints = [
    "joshsymonds-ec2-fleet-cache--usw2-az1--x-s3.s3express-usw2-az1.us-west-2.amazonaws.com"
    "s3express-usw2-az1.us-west-2.amazonaws.com"
    "s3express-control.us-west-2.amazonaws.com"
  ];

  cacheBox = extra: {
    imports = [
      ../hosts/ec2/base.nix
      ../hosts/ec2/classes/commonframe.nix
      extra
    ];
    networking.hostName = lib.mkForce "ec2-s3-cache";
    # amazon-image enables the serial console; the test driver owns it.
    systemd.services."serial-getty@ttyS0".enable = lib.mkForce false;
    # An RSA host key takes most of a minute to generate in a VM, so sshd
    # comes up on ed25519 only.
    services.openssh.hostKeys = lib.mkForce [
      {
        type = "ed25519";
        path = "/etc/ssh/ssh_host_ed25519_key";
      }
    ];
    ec2Fleet.s3Cache.enable = true;
    # Dummy credentials keep mount-s3 from asking IMDS for any.
    systemd.services.ec2-s3-cache.environment = {
      AWS_ACCESS_KEY_ID = "test";
      AWS_SECRET_ACCESS_KEY = "test";
    };
  };

  blackhole = {
    networking.hosts."192.0.2.1" = endpoints;
    networking.interfaces.lo.ipv4.routes = [
      {
        address = "192.0.2.0";
        prefixLength = 24;
      }
    ];
    networking.firewall.extraCommands = "iptables -A OUTPUT -d 192.0.2.1 -j DROP";
  };

  # The cf user writes the path the way a build does: create, rename over,
  # delete. The path must hold these writes whether or not it is mounted.
  coldWrite = ''
    runuser -u cf -- sh -c 'set -eu; d=/home/cf/.cache/commonframe; echo one > $d/a; echo two > $d/b; mv -f $d/b $d/a; test "$(cat $d/a)" = two; rm $d/a; test ! -e $d/a'
  '';
in
  pkgs.testers.runNixOSTest {
    name = "ec2-s3-cache";

    node.specialArgs = {inherit inputs outputs;};
    node.pkgsReadOnly = false;

    nodes = {
      refused = cacheBox {
        networking.hosts."127.0.0.1" = endpoints;
      };

      blackholed = cacheBox blackhole;

      hung = cacheBox blackhole;

      off = {
        imports = [
          ../hosts/ec2/base.nix
          ../hosts/ec2/classes/commonframe.nix
        ];
        networking.hostName = lib.mkForce "ec2-s3-cache-off";
        systemd.services."serial-getty@ttyS0".enable = lib.mkForce false;
      };
    };

    testScript = ''
      import re
      import time

      start_all()

      # Poweroff with the mount hung on a blackholed endpoint. The unit is
      # activating only until mount-s3 gives up, so this runs first.
      hung.wait_for_unit("basic.target")
      hung.succeed("for i in $(seq 1 20); do [ \"$(systemctl is-active ec2-s3-cache.service)\" = activating ] && exit 0; sleep 1; done; exit 1")
      hung.succeed("[ \"$(systemctl is-active ec2-s3-cache.service)\" = activating ]")
      start = time.monotonic()
      hung.shutdown()
      elapsed = time.monotonic() - start
      print(f"hung poweroff with the mount hung: {elapsed:.1f}s")
      assert elapsed < 60, f"poweroff took {elapsed:.1f}s"

      off.wait_for_unit("multi-user.target")
      off.fail("systemctl cat ec2-s3-cache.service")

      # The blackholed mount fails after its child timeout, and boot, sshd and
      # cf's writes go on.
      blackholed.wait_for_unit("sshd.service")
      blackholed.wait_until_succeeds("systemctl is-failed ec2-s3-cache.service", timeout=300)
      blackholed.wait_for_unit("multi-user.target")
      blackholed.succeed("systemctl is-active sshd.service")
      blackholed.succeed("test \"$(stat -c %U /home/cf/.cache)\" = cf")
      blackholed.succeed("test \"$(stat -c %U /home/cf/.cache/commonframe)\" = cf")
      blackholed.succeed("""${coldWrite}""")

      # The refused mount fails after its child timeout, and boot, sshd and
      # cf's writes go on.
      refused.wait_for_unit("sshd.service")
      refused.wait_until_succeeds("systemctl is-failed ec2-s3-cache.service", timeout=300)
      refused.wait_for_unit("multi-user.target")
      refused.succeed("systemctl is-active sshd.service")
      refused.succeed("test \"$(stat -c %U /home/cf/.cache)\" = cf")
      refused.succeed("test \"$(stat -c %U /home/cf/.cache/commonframe)\" = cf")
      refused.succeed("""${coldWrite}""")

      # The ExecStart carries cf's uid and gid, the fleet options and the path.
      unit = refused.succeed("systemctl cat ec2-s3-cache.service")
      exec_start = re.search(
          r"^ExecStart=.*mount-s3 --uid 1001 --gid 100 --allow-other --allow-overwrite --allow-delete"
          r" --prefix commonframe/ --region us-west-2 --cache (/\S+) --max-cache-size 61440 --memory-target 2048"
          r" joshsymonds-ec2-fleet-cache--usw2-az1--x-s3 /home/cf/\.cache/commonframe$",
          unit,
          re.M,
      )
      assert exec_start, f"ExecStart does not match the cache mount:\n{unit}"
      print(f"ExecStart: {exec_start.group(0)}")

      # Start and stop are bounded, and the mount stops before the network.
      props = dict(
          line.split("=", 1)
          for line in refused.succeed(
              "systemctl show -p After,TimeoutStartUSec,TimeoutStopUSec ec2-s3-cache.service"
          ).splitlines()
      )
      assert "network-online.target" in props["After"].split(), props["After"]
      assert props["TimeoutStartUSec"] != "infinity", props["TimeoutStartUSec"]
      assert props["TimeoutStopUSec"] != "infinity", props["TimeoutStopUSec"]
      print(f"TimeoutStartUSec={props['TimeoutStartUSec']} TimeoutStopUSec={props['TimeoutStopUSec']}")

      # Nothing boot-critical requires the mount.
      for target in ["sshd.service", "local-fs.target"]:
          deps = refused.succeed(f"systemctl list-dependencies --all --plain {target}")
          assert "ec2-s3-cache.service" not in deps, f"{target} requires the mount"
    '';
  }
