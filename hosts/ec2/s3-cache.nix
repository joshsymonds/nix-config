# Options for the fleet S3 directory-bucket cache; a class with cache = true enables it.
{lib, ...}: {
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
}
