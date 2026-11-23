{lib, ...}: {
  options.services.orreryGateway.port = lib.mkOption {
    type = lib.types.port;
    default = 4110;
    description = "Loopback port `orrery gateway` listens on.";
  };

  options.services.orreryGateway.serveClaude = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "When true, Claude Code's base URLs on this host (the settings env ANTHROPIC_BASE_URL and the ~/Work/attain /ctx/attain stamp) and orreryd's gateway address point at the gateway instead of patchbay.";
  };
}
