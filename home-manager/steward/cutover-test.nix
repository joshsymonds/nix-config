let
  nixpkgsLib = import <nixpkgs/lib>;
  lib = nixpkgsLib // {
    hm.dag = {
      entryAfter = _: value: value;
      entryBefore = _: value: value;
    };
  };
  system = "x86_64-linux";
  fake = path: extra:
    {
      __toString = _: path;
      outPath = path;
    }
    // extra;
  stewardPackage = fake "@STEWARD_PACKAGE@" {};
  stewardRuntime = fake "@STEWARD_RUNTIME@" {
    extensionRoot = "@STEWARD_EXTENSION_ROOT@";
    nodeModules = "@STEWARD_NODE_MODULES@";
  };
  checkedRunCommand = name: _: script:
    assert !(builtins.elem name ["pi-tasks-0.9.0" "pi-goal-0.54.3" "pi-lsp-0.49.7"])
      || lib.hasInfix "@STEWARD_NODE_MODULES@/typebox" script;
      fake "/nix/store/fixture-${name}" {inherit script;};
  pkgs = rec {
    inherit lib;
    stdenv.hostPlatform.system = system;
    fetchzip = args: fake "/nix/store/fixture-source" {inherit args;};
    runCommand = checkedRunCommand;
    linkFarm = name: _: fake "/nix/store/fixture-${name}" {};
    writeShellScript = name: text: fake "@SCRIPT_${name}@" {inherit text;};
    writeText = name: text: fake "@BASE@" {inherit text;};
    coreutils = fake "@COREUTILS@" {};
    jq = fake "@JQ@" {};
    yq-go = fake "@YQ@" {};
    python3 = fake "@PYTHON@" {};
    tmux = fake "@TMUX@" {};
    git = fake "@GIT@" {};
    typescript = fake "/nix/store/fixture-typescript" {};
  };
  inputs = {
    steward.packages.${system} = {
      default = stewardPackage;
      steward-pi-runtime = stewardRuntime;
    };
    gambit.packages.${system} = {};
    openai-plugins = fake "/nix/store/fixture-openai-plugins" {};
  };
  baseConfig = {
    home.homeDirectory = "/home/tester";
    xdg.cacheHome = "/home/tester/.cache";
    age.secrets = {
      "ntfy-url".path = "\${XDG_RUNTIME_DIR}/agenix/ntfy-url";
      "ntfy-token".path = "\${XDG_RUNTIME_DIR}/agenix/ntfy-token";
    };
    services.patchbay = {
      enable = true;
      port = 4242;
    };
  };
  stewardOptionModule = {lib, ...}: {
    options = {
      age.secrets = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            file = lib.mkOption {type = lib.types.raw;};
            path = lib.mkOption {type = lib.types.str;};
          };
        });
        default = {};
      };
      home = {
        homeDirectory = lib.mkOption {type = lib.types.str;};
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.raw;
          default = [];
        };
        sessionVariables = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
        };
        activation = lib.mkOption {
          type = lib.types.attrsOf lib.types.raw;
          default = {};
        };
      };
      services.patchbay = {
        enable = lib.mkOption {type = lib.types.bool;};
        port = lib.mkOption {type = lib.types.int;};
      };
      systemd.user.services = lib.mkOption {
        type = lib.types.attrsOf lib.types.raw;
        default = {};
      };
      xdg.cacheHome = lib.mkOption {type = lib.types.str;};
    };
    config = baseConfig;
  };
  mkSteward = overrides:
    (nixpkgsLib.evalModules {
      modules = [
        stewardOptionModule
        ({config, ...}: import ./default.nix {inherit config inputs lib pkgs;})
        {config.home.sessionVariables = overrides;}
      ];
    }).config;
  steward = mkSteward {};
  stewardOverride = mkSteward {
    STEWARD_HELPER_BIN = "helper ' $(touch @SHELL_SENTINEL@) ;";
    STEWARD_MODEL_PROVIDER = "";
    STEWARD_MODEL_ID = "model \"$HOME\"; false";
    STEWARD_MODEL_THINKING = "";
  };
  pi = import ../pi/default.nix {inherit inputs lib pkgs;};
  codex = import ../codex/default.nix {
    hostname = "fixture";
    inherit inputs lib pkgs;
  };
  managedCodex = import ../codex/managed-config.nix {
    gambitHasCodex = false;
    inherit lib pkgs stewardPackage;
  };
  common = import ../common.nix {
    config = baseConfig;
    inherit inputs lib pkgs;
  };
  exposeSteward = effective: {
    packages = map toString effective.home.packages;
    sessionVariables = effective.home.sessionVariables;
    secretNames = builtins.attrNames effective.age.secrets;
    secretFiles = lib.mapAttrs (_: secret: toString secret.file) effective.age.secrets;
    serviceNames = builtins.attrNames effective.systemd.user.services;
    activationNames = builtins.attrNames effective.home.activation;
    service = effective.systemd.user.services.steward-notifyd;
    serviceScript = effective.systemd.user.services.steward-notifyd.Service.ExecStart.text;
  };
in {
  steward = exposeSteward steward // {
    imports = map toString common.imports;
  };
  stewardOverride = exposeSteward stewardOverride;
  pi = {
    package = toString pi.programs.pi-coding-agent.package;
    packages = pi.programs.pi-coding-agent.settings.packages;
    defaultProvider = pi.programs.pi-coding-agent.settings.defaultProvider;
    defaultModel = pi.programs.pi-coding-agent.settings.defaultModel;
    defaultThinkingLevel = pi.programs.pi-coding-agent.settings.defaultThinkingLevel;
    models = builtins.fromJSON pi.home.file.".pi/agent/models.json".text;
    lsp =
      if pi.home.file ? ".pi/agent/pi-lsp.json"
      then builtins.fromJSON pi.home.file.".pi/agent/pi-lsp.json".text
      else null;
    tasks = builtins.fromJSON pi.home.file.".pi/agent/tasks-config.json".text;
    goal = builtins.fromJSON pi.home.file.".pi/agent/pi-goal.json".text;
    subagents = builtins.fromJSON pi.home.file.".pi/agent/subagents.json".text;
    homeFileNames = builtins.attrNames pi.home.file;
  };
  codex = {
    managed = managedCodex.text;
    activation = codex.home.activation.codexConfig;
  };
}
