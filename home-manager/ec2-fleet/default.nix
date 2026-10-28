{
  config,
  pkgs,
  ...
}: {
  # The ec2 fleet launcher and the agenix user secrets it reads. Imported only
  # by hosts that launch fleet boxes; the fleet boxes themselves (hosts/ec2.nix)
  # carry no agenix secrets and no IAM role.
  age.secrets = {
    "ec2-fleet-aws".file = ../../secrets/user/ec2-fleet-aws.age;
    "tailscale-fleet-oauth".file = ../../secrets/user/tailscale-fleet-oauth.age;
    "ec2-fleet-tofu-passphrase".file = ../../secrets/user/ec2-fleet-tofu-passphrase.age;
  };

  home = {
    packages = [pkgs.ec2];

    sessionVariables = {
      EC2_FLEET_AWS_ENV_FILE = config.age.secrets."ec2-fleet-aws".path;
      EC2_FLEET_TS_ENV_FILE = config.age.secrets."tailscale-fleet-oauth".path;
      EC2_FLEET_TOFU_PASSPHRASE_FILE = config.age.secrets."ec2-fleet-tofu-passphrase".path;
    };
  };
}
