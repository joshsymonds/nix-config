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
    };

    testScript = ''
      machine.start()

      machine.wait_for_unit("ec2-fleet-identity.service")
      machine.succeed("systemctl is-active ec2-fleet-identity.service")

      machine.succeed("test \"$(hostname)\" = commonframe-gate-mjs")
      machine.succeed("test \"$(cat /run/ec2-fleet/ts-authkey)\" = tskey-auth-test-identity")
      machine.succeed("test \"$(stat -c %a /run/ec2-fleet/ts-authkey)\" = 600")

      # The box is offline here, so autoconnect may fail. It must still start,
      # which only happens once its identity dependency is satisfied.
      machine.wait_until_succeeds("test \"$(systemctl show -p ExecMainStartTimestampMonotonic --value tailscaled-autoconnect.service)\" != 0", timeout=300)
    '';
  }
