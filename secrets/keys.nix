# Age public keys for agenix secret encryption.
#
# Structure:
#   hosts    — system SSH host keys (from /etc/ssh/ssh_host_ed25519_key.pub)
#   users    — user SSH keys (from ~/.ssh/<key>.pub, converted via ssh-to-age)
#
# Output attributes match what secrets.nix expects:
#   keys.<hostname>  — host key + user key (for system-level agenix)
#   keys.joshsymonds — all user keys (for home-manager agenix)
#
# To audit a machine:
#   ssh-to-age -i /etc/ssh/ssh_host_ed25519_key.pub   # host key (NixOS only)
#   ssh-to-age -i ~/.ssh/github.pub                     # user key
let
  # Agenix identity keys (used by agenix at boot to decrypt system secrets)
  # On a fresh install this is derived from /etc/ssh/ssh_host_ed25519_key.
  # After a reimage+restore, this may be the restored key at /etc/age/<host>.agekey.
  # Verify with: sudo age-keygen -y /etc/age/<host>.agekey
  hosts = {
    ultraviolet = "age1l48gfpefgh5p4phelwc760pg24pm6qwxju2zlxcgvcamw6pzjgrqq8r3g3";
    vermissian = "age1gk07t276expcprxg4el8rsmap4ry3vq9ungmhs9ap3rtwljge9qsqdvnkw";
    ninuan = "age1kyf60tq3yg9msawwtjrvxzqlhspsje3qedtqj2f4aexj7th7juwsg938nu";
    # TODO: audit and add
    # bluedesert = "...";
    # echelon = "...";
  };

  # User keys (from ~/.ssh/<key>.pub, converted via ssh-to-age)
  users = {
    "joshsymonds@ultraviolet" = "age1yyrhr0zpg3xnxtstq6g3u0zrxglfhnur6387f5znwmehg36rh4cs39apxy";
    "joshsymonds@vermissian" = "age10kwzaeajuyvfuyuh03tk6ywand899699rdxlrskh2f6x6ru9t56s02d6pg";
    "joshsymonds@ninuan" = "age1fx2ktlav7rraljux7ypkngd2my64lnr0c8w4hs8jfztgc2dxdqns38264l";
    # TODO: audit and add
    # "joshsymonds@bluedesert" = "...";
    # "joshsymonds@echelon" = "...";
  };

  allUserKeys = builtins.attrValues users;
in {
  # Per-host: host key + user key (system-level agenix needs host key to decrypt at boot)
  ultraviolet = [hosts.ultraviolet users."joshsymonds@ultraviolet"];

  # All user keys across machines (home-manager agenix)
  joshsymonds = allUserKeys;

  vermissian = [hosts.vermissian users."joshsymonds@vermissian"];
}
