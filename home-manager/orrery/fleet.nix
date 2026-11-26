{lib, ...}: {
  # Fleet-wide orrery settings. Options only: no host sets or reads them yet.
  options.services.orreryFleet = {
    controller = lib.mkOption {
      type = lib.types.str;
      default = "ultraviolet";
      description = "Tailnet node name of the host that runs orrery's controller: orreryd --sessions, orrery serve, and the store. Every controller name reads this option.";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "tail82223.ts.net";
      description = "Tailnet domain suffix. Fleet node names resolve under it.";
    };

    addresses = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        ultraviolet = "100.66.32.65";
        vermissian = "100.94.194.116";
        gnomon = "100.108.237.97";
      };
      description = "Tailnet IPv4 address of each fleet host, keyed by tailnet node name.";
    };

    relayPort = lib.mkOption {
      type = lib.types.port;
      default = 7450;
      description = "TCP port of the fleet relay on the controller host.";
    };

    agentPort = lib.mkOption {
      type = lib.types.port;
      default = 7451;
      description = "TCP port each agent's `orrery node` listens on.";
    };

    agents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["vermissian" "gnomon"];
      description = "Tailnet node names of the hosts that run `orrery node` as agents of the controller.";
    };

    defaultHost = lib.mkOption {
      type = lib.types.str;
      default = "vermissian";
      description = "Tailnet node name of the agent a session runs on when none is named.";
    };

    agentRoots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["Personal" "Work" "nix-config"];
      description = "Home-relative folders an agent serves, in this order. Personal is first because it takes fresh clones.";
    };

    secretFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/agenix/orrery-fleet-secret";
      description = "Path to the fleet secret file on each host, decrypted by agenix.";
    };
  };

  options.services.orreryNode.enable = lib.mkEnableOption "running `orrery node` as an agent of the fleet's controller";
}
