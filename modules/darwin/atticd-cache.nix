{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.atticd-cache;
in {
  # Darwin twin of modules/services/atticd-cache.nix. Same option surface for
  # consumer + publisher; writes to determinateNix.customSettings (Determinate
  # owns nix.conf on Darwin) and detaches uploads via `nohup &` since there is
  # no systemd-run.
  #
  # No `enable` (server) submodule — the cache server only runs on NixOS.
  options.services.atticd-cache = {
    consumer = {
      enable = lib.mkEnableOption "use the household atticd as a substituter (pull-only)";

      url = lib.mkOption {
        type = lib.types.str;
        default = "http://ultraviolet:8081/nix-config";
        description = "Cache URL for clients to pull from.";
      };

      publicKey = lib.mkOption {
        type = lib.types.str;
        default = "nix-config:oFasWpcTwQxVGCxSBTLw8gGNZNjhRLZsnWnZQIyU4HY=";
        description = "Cache signing public key (from `attic cache info`). Public keys are not secret.";
      };
    };

    publisher = {
      enable = lib.mkEnableOption "push successful nix builds to the household atticd";

      tokenFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to a file containing the atticd push token (single line, no trailing newline).
          On Darwin there is no system agenix, so this typically points at a home-manager-
          managed agenix path or a manually-installed root-owned file under /etc.
          Must be readable by the nix-daemon (which runs as root on Darwin).
          The token must be scoped (atticadm) to push+pull on the target cache only.
        '';
      };

      cacheUrl = lib.mkOption {
        type = lib.types.str;
        default = cfg.consumer.url;
        defaultText = lib.literalExpression "config.services.atticd-cache.consumer.url";
        description = ''
          Push target URL. Defaults to the consumer URL so most hosts need no override.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.consumer.enable {
      determinateNix.customSettings = {
        extra-substituters = [cfg.consumer.url];
        extra-trusted-public-keys = [cfg.consumer.publicKey];
      };
    })

    (lib.mkIf cfg.publisher.enable (let
      hookScript = pkgs.writeShellScript "upload-to-attic" ''
        #!${pkgs.runtimeShell}
        set -eu

        # nix invokes the hook even when no outputs were produced.
        [ -n "''${OUT_PATHS:-}" ] || exit 0

        if [ ! -r ${lib.escapeShellArg cfg.publisher.tokenFile} ]; then
          echo "atticd-push: token file unreadable: ${cfg.publisher.tokenFile}" >&2
          exit 1
        fi

        ATTIC_TOKEN="$(cat ${lib.escapeShellArg cfg.publisher.tokenFile})"
        export ATTIC_TOKEN

        # Darwin has no systemd-run; detach via nohup to a log file.
        # The script exits immediately so `nix build` never waits.
        # $OUT_PATHS is intentionally word-split (space-separated path list from nix).
        ${pkgs.coreutils}/bin/nohup \
          ${pkgs.attic-client}/bin/attic push ${lib.escapeShellArg cfg.publisher.cacheUrl} $OUT_PATHS \
          >>/var/log/attic-push.log 2>&1 </dev/null &
      '';
    in {
      environment.systemPackages = [pkgs.attic-client];
      determinateNix.customSettings.post-build-hook = "${hookScript}";
    }))
  ];
}
