# EC2 fleet classes. flake.nix builds nixosConfigurations.ec2-<class> from
# each entry, applying idleMinutes and maxHours to ec2Fleet and importing
# module on top of the base. The remaining fields are for the launcher.
{
  commonframe-gate = {
    instanceType = "c8a.16xlarge";
    diskGb = 200;
    spot = true;
    idleMinutes = 30;
    maxHours = 24;
    module = ./classes/commonframe-gate.nix;
  };

  muniment-runner = {
    instanceType = "c8a.16xlarge";
    diskGb = 400;
    spot = false;
    idleMinutes = 60;
    maxHours = 48;
    module = ./classes/muniment-runner.nix;
  };
}
