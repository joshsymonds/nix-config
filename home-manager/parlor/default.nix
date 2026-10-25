# parlor — the `parlor serve` daemon and the `parlor-score` CLI, both from the
# parlor flake, and the `joshify` rewriter command.
#
# The daemon runs as a user service. Its model directory defaults to a path
# under the user's home (parlor's own default), so weights never enter the
# nix store.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.parlor;
  scoreCfg = config.programs.parlor-score;
  joshifyCfg = config.programs.joshify;
  system = pkgs.stdenv.hostPlatform.system;
in {
  options = {
    services.parlor = {
      enable = lib.mkEnableOption "the parlor serve daemon";

      port = lib.mkOption {
        type = lib.types.port;
        default = 4110;
        description = "Port the parlor daemon listens on.";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "Address the parlor daemon binds to.";
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = inputs.parlor.packages.${system}.parlor;
        defaultText = lib.literalExpression "inputs.parlor.packages.\${system}.parlor";
        description = "The parlor package to run.";
      };
    };

    programs.parlor-score = {
      enable = lib.mkEnableOption "the parlor-score CLI";
    };

    programs.joshify = {
      enable = lib.mkEnableOption "the joshify rewriter command";

      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "gnomon";
        description = ''
          Host that runs joshify over ssh. When null, joshify runs here, in
          the CUDA shell of the parlor checkout at ~/Personal/parlor.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.user.services.parlor = {
        Unit.Description = "parlor — serve daemon";
        Service = {
          ExecStart = "${cfg.package}/bin/parlor serve --host ${cfg.host} --port ${toString cfg.port}";
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install.WantedBy = ["default.target"];
      };
    })

    (lib.mkIf scoreCfg.enable {
      home.packages = [inputs.parlor.packages.${system}.parlor-score];
      # The voice pointer lives in the private parlor repo; only the import
      # wiring is public.
      programs.claudeCode.memoryImports."parlor.md" = inputs.parlor + "/voice/CLAUDE.md";
    })

    (lib.mkIf joshifyCfg.enable {
      home.packages = [
        (pkgs.writeShellScriptBin "joshify" (
          if joshifyCfg.host == null
          then ''
            # The checkout's editable install resolves the package from $PWD,
            # so this cds into it, after turning a relative --gguf into an
            # absolute path. The rewriter GGUF and its log stay under
            # ~/.local/share/parlor.
            args=()
            while [ $# -gt 0 ]; do
              case $1 in
                --gguf) args+=("$1" "$(realpath -m -- "$2")"); shift 2 ;;
                --gguf=*) args+=("--gguf=$(realpath -m -- "''${1#--gguf=}")"); shift ;;
                *) args+=("$1"); shift ;;
              esac
            done
            cd "$HOME/Personal/parlor" || exit 1
            exec nix develop .#cuda -c parlor joshify "''${args[@]}"
          ''
          else ''
            # stdin and stderr pass through ssh. --rate finds no terminal there
            # and logs without ratings.
            exec ssh ${joshifyCfg.host} joshify ''${1+"$(printf '%q ' "$@")"}
          ''
        ))
      ];
    })
  ];
}
