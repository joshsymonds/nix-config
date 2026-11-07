# EC2 fleet classes. flake.nix builds nixosConfigurations.ec2-<class> from
# each entry, applying idleMinutes and maxHours to ec2Fleet and importing
# module on top of the base. The remaining fields are for the launcher.
# reboot = true (absent means false) deploys the class with
# switch-to-configuration boot, reboots the box, and waits for a new boot id
# instead of switching in place. cache = true (absent means false) enables the
# fleet S3 cache mount on the box (ec2Fleet.s3Cache.enable).
{
  commonframe-gate = {
    instanceType = "c8a.16xlarge";
    diskGb = 200;
    spot = true;
    cache = true;
    idleMinutes = 30;
    maxHours = 24;
    module = ./classes/commonframe-gate.nix;
  };

  halmasuit-lab = {
    instanceType = "g4dn.xlarge";
    diskGb = 100;
    spot = true;
    reboot = true;
    idleMinutes = 30;
    maxHours = 4;
    module = ./classes/halmasuit-lab.nix;
  };

  commonframe-gpu = {
    instanceType = "g4dn.2xlarge";
    diskGb = 200;
    spot = true;
    cache = true;
    idleMinutes = 30;
    maxHours = 12;
    reboot = true;
    module = ./classes/commonframe-gpu.nix;
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
