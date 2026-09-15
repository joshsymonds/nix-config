# gws — Google Workspace CLI (Sheets, Drive, Docs, Gmail, ...). This is the
# agent-facing path to Google documents: Claude Code, Pi, and plain shell all
# call the same binary, and nothing is tied to an Anthropic account.
#
# Upstream gws (0.22.x) holds exactly one login per config directory and has
# no account switching, so the wrapper below keeps one directory per Google
# account and selects it with a single env var:
#
#   gws sheets spreadsheets get --params '{"spreadsheetId":"..."}'   # work
#   GWS_ACCOUNT=personal gws drive files list                        # personal
#
# Each directory holds its own OAuth client (client_secret.json, created in
# that account's GCP project) plus the encrypted refresh token. The keyring
# backend is forced to `file` because the headless hosts have no secret
# service; the AES key then lives in <dir>/.encryption_key.
#
# Accounts:
#   work     jsymonds@joinklover.com  (OAuth client in GCP project gws-cli-jsymonds)
#   personal josh@joshsymonds.com     (OAuth client in GCP project gws-cli-joshsymonds)
{
  config,
  pkgs,
  ...
}: let
  gws = pkgs.writeShellScriptBin "gws" ''
    account="''${GWS_ACCOUNT:-work}"
    export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="''${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-${config.xdg.configHome}/gws/$account}"
    export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND="''${GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND:-file}"
    exec ${pkgs.gws}/bin/gws "$@"
  '';
in {
  home.packages = [gws];
}
