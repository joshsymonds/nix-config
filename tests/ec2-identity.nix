# tests/ec2-identity.nix
#
# nixosTest for the fleet box identity unit (hosts/ec2/base.nix,
# ec2-fleet-identity). The node imports the real base and stubs only
# fetch-ec2-metadata, which would otherwise read IMDS. The stub writes the
# user-data that pkgs/ec2/ec2.sh sends, so apply-ec2-data and the identity
# unit run for real.
{
  pkgs,
  inputs,
  outputs,
}: let
  inherit (pkgs) lib;

  userData = ''
    EC2_FLEET_NAME=commonframe-gate-mjs
    EC2_FLEET_TS_AUTHKEY=tskey-auth-test-identity
  '';
in
  pkgs.testers.runNixOSTest {
    name = "ec2-identity";

    node.specialArgs = {inherit inputs outputs;};
    node.pkgsReadOnly = false;

    nodes.machine = {
      imports = [../hosts/ec2/base.nix];
      # Production leaves the hostname to user-data, so it stays empty.
      networking.hostName = lib.mkForce "";
      # amazon-image enables the serial console; the test driver owns it.
      systemd.services."serial-getty@ttyS0".enable = lib.mkForce false;
      systemd.services.fetch-ec2-metadata.script = lib.mkForce ''
        mkdir -p /etc/ec2-metadata
        printf '%s' ${lib.escapeShellArg userData} > /etc/ec2-metadata/user-data
      '';
      # Records the boot id and the hostname each time tailscaled starts, so
      # the testScript can read the name the daemon saw on every boot.
      systemd.tmpfiles.rules = ["d /var/lib/ec2-identity-test 0755 root root -"];
      systemd.services.tailscaled.serviceConfig.ExecStartPre = [
        (pkgs.writeShellScript "record-tailscaled-start" ''
          read -r boot < /proc/sys/kernel/random/boot_id
          read -r host < /proc/sys/kernel/hostname
          printf '%s %s\n' "$boot" "$host" >> /var/lib/ec2-identity-test/tailscaled-starts
        '')
      ];
    };

    testScript = ''
      record = "/var/lib/ec2-identity-test/tailscaled-starts"

      def tailscaled_start_names():
          return machine.succeed(
              "awk -v boot=$(cat /proc/sys/kernel/random/boot_id) '$1 == boot { print $2 }' " + record
          ).split()

      def assert_tailscaled_saw_fleet_name():
          machine.wait_until_succeeds(
              "test -n \"$(awk -v boot=$(cat /proc/sys/kernel/random/boot_id) '$1 == boot' " + record + ")\"",
              timeout=300,
          )
          names = tailscaled_start_names()
          assert names and set(names) == {"commonframe-gate-mjs"}, names

      machine.start()

      machine.wait_for_unit("ec2-fleet-identity.service")
      machine.succeed("systemctl is-active ec2-fleet-identity.service")

      machine.succeed("test \"$(hostname)\" = commonframe-gate-mjs")
      machine.succeed("test \"$(cat /run/ec2-fleet/ts-authkey)\" = tskey-auth-test-identity")
      machine.succeed("test \"$(stat -c %a /run/ec2-fleet/ts-authkey)\" = 600")

      # The box is offline here, so autoconnect may fail. It must still start,
      # which only happens once its identity dependency is satisfied.
      machine.wait_until_succeeds("test \"$(systemctl show -p ExecMainStartTimestampMonotonic --value tailscaled-autoconnect.service)\" != 0", timeout=300)

      # The tailnet node takes its name from the hostname tailscaled starts with.
      assert_tailscaled_saw_fleet_name()

      # A reboot clears the transient hostname; the identity unit must set it
      # again before tailscaled starts.
      machine.shutdown()
      machine.start()

      machine.wait_for_unit("ec2-fleet-identity.service")
      assert_tailscaled_saw_fleet_name()
    '';
  }
