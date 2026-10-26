# parlor — the `parlor serve` daemon and the `parlor-score` CLI, both from the
# parlor flake, the `joshify` rewriter command, and a nightly backup of
# parlor's work to the NAS.
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
  backupCfg = config.services.parlor-backup;
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
          Host that runs joshify over ssh. When null, joshify runs here, from
          the parlor flake's joshify package.
        '';
      };
    };

    services.parlor-backup = {
      enable = lib.mkEnableOption "the nightly backup of parlor's work to the NAS";
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
      # The package carries numpy and the CUDA llama-server, no torch, and the
      # profile keeps it from garbage collection. The rewriter GGUF and its log
      # stay under ~/.local/share/parlor.
      home.packages = [
        (
          if joshifyCfg.host == null
          then inputs.parlor.packages.${system}.joshify
          else
            pkgs.writeShellScriptBin "joshify" ''
              # stdin and stderr pass through ssh. --rate finds no terminal there
              # and logs without ratings.
              exec ssh ${joshifyCfg.host} joshify ''${1+"$(printf '%q ' "$@")"}
            ''
        )
      ];
    })

    (lib.mkIf backupCfg.enable (let
      home = config.home.homeDirectory;
      backup = pkgs.writeShellApplication {
        name = "parlor-backup";
        runtimeInputs = with pkgs; [coreutils gawk git openssh rsync util-linux];
        text = ''
          # Trigger each automount, then require its NAS backing, so a missing
          # mount fails the run instead of filling a local directory.
          require_nas() {
            stat "$1/." >/dev/null
            if ! findmnt -rn -T "$1" -o FSTYPE,SOURCE \
              | awk -v source="$2" '$1 ~ /^nfs4?$/ && $2 == source { found = 1 } END { exit !found }'; then
              echo "parlor-backup: $2 is not mounted at $1" >&2
              exit 1
            fi
          }
          require_nas /mnt/backup 172.31.0.100:/volume1/backup
          require_nas /mnt/claude 172.31.0.100:/volume1/claude
          # The NAS ignores the umask, so each copy sets its own mode.
          private=("--chmod=Du=rwx,Dgo=,Fu=rw,Fgo=")

          # Records that exist only on this machine: the gambit epics, every
          # parlor branch, and nix-config's parlor branches, some of which
          # stay off the public remote. Each bundle replaces the last only
          # once it is complete.
          dest=/mnt/backup/vermissian/parlor
          mkdir -p "$dest"
          chmod 700 "$dest"
          rsync -rlt "''${private[@]}" ${home}/.gambit/parlor-b80ba08/ "$dest/gambit/"
          git -C ${home}/Personal/parlor bundle create -q "$dest/parlor.bundle.tmp" --all
          chmod 600 "$dest/parlor.bundle.tmp"
          mv "$dest/parlor.bundle.tmp" "$dest/parlor.bundle"
          git -C ${home}/nix-config bundle create -q "$dest/nix-config-parlor.bundle.tmp" --branches='*parlor*'
          chmod 600 "$dest/nix-config-parlor.bundle.tmp"
          mv "$dest/nix-config-parlor.bundle.tmp" "$dest/nix-config-parlor.bundle"

          # The prompt history is a corpus source; the transcripts beside it
          # already live on this share.
          rsync -t "''${private[@]}" ${home}/.claude/history.jsonl /mnt/claude/vermissian/personal/history.jsonl

          # gnomon is not on the backup export, so its trained models come
          # through here. The base models are public and are not copied.
          mkdir -p /mnt/backup/gnomon/parlor
          chmod 700 /mnt/backup/gnomon /mnt/backup/gnomon/parlor
          rsync -rltR "''${private[@]}" \
            'gnomon:.local/share/parlor/./rewriter/adapters' \
            'gnomon:.local/share/parlor/./rewriter/exports' \
            'gnomon:.local/share/parlor/./rewriter/recall.idx' \
            'gnomon:.local/share/parlor/./model' \
            'gnomon:.local/share/parlor/./model.backup-*' \
            /mnt/backup/gnomon/parlor/
        '';
      };
    in {
      home.packages = [backup];

      systemd.user.services.parlor-backup = {
        Unit = {
          Description = "Back up parlor's records and models to the NAS";
          After = ["network-online.target"];
        };
        Service = {
          Type = "oneshot";
          ExecStart = "${backup}/bin/parlor-backup";
        };
      };

      systemd.user.timers.parlor-backup = {
        Unit.Description = "Back up parlor nightly at 03:30";
        Timer = {
          OnCalendar = "*-*-* 03:30:00";
          Persistent = true;
          Unit = "parlor-backup.service";
        };
        Install.WantedBy = ["timers.target"];
      };
    }))
  ];
}
