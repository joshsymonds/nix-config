# Options and the mount for the fleet S3 directory-bucket cache; a class with cache = true enables it.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.ec2Fleet.s3Cache;
  owner = config.users.users.${cfg.user};
  group = config.users.groups.${owner.group};
in {
  options.ec2Fleet.s3Cache = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Mount the fleet S3 cache bucket at path for user.";
    };
    bucket = lib.mkOption {
      type = lib.types.str;
      default = "joshsymonds-ec2-fleet-cache--usw2-az1--x-s3";
      description = "S3 directory bucket holding the fleet cache.";
    };
    region = lib.mkOption {
      type = lib.types.str;
      default = "us-west-2";
      description = "AWS region of the cache bucket.";
    };
    prefix = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Key prefix within the bucket mounted at path.";
    };
    path = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Absolute mount point of the cache on the box.";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "User that owns and reads the mounted cache.";
    };
  };

  # The mount is not a boot dependency: nothing that sshd or local-fs.target
  # needs names it, and it starts after the network so a refused or hung
  # endpoint only leaves path cold.
  config = lib.mkIf cfg.enable {
    # The parent is created for the user too, or tmpfiles would make it root-owned.
    systemd.tmpfiles.rules = [
      "d ${dirOf cfg.path} 0755 ${cfg.user} ${owner.group} -"
      "d ${cfg.path} 0755 ${cfg.user} ${owner.group} -"
    ];

    systemd.services.ec2-s3-cache = {
      description = "Mount the fleet S3 cache at ${cfg.path}";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      after = ["network-online.target"];
      serviceConfig = {
        # mount-s3 daemonizes once mounted, so start ends only when the mount is up.
        Type = "forking";
        CacheDirectory = "ec2-s3-cache";
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.mountpoint-s3}/bin/mount-s3"
          "--uid ${toString owner.uid}"
          "--gid ${toString group.gid}"
          "--allow-other --allow-overwrite --allow-delete"
          "--prefix ${cfg.prefix}"
          "--region ${cfg.region}"
          "--cache /var/cache/ec2-s3-cache"
          "--max-cache-size 61440"
          "--memory-target 2048"
          cfg.bucket
          cfg.path
        ];
        TimeoutStartSec = "60s";
        TimeoutStopSec = "15s";
      };
    };
  };
}
