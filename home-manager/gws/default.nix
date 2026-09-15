# gws — Google Workspace CLI (Sheets, Drive, Docs, ...). This is the
# agent-facing path to Google documents: Claude Code, Pi, and plain shell all
# call the same binary, and nothing is tied to an Anthropic account.
#
# No OAuth client of our own. Google only lets you create one in the Cloud
# Console (the IAP OAuth Admin API that could do it from the CLI was shut
# down 2026-03), and gcloud's built-in client already covers what we need:
# `gcloud auth login <acct> --enable-gdrive-access` adds the Drive scope,
# and the Sheets and Docs APIs accept the Drive scope for read and write.
# The wrapper mints a token from gcloud per call and hands it to gws via
# GOOGLE_WORKSPACE_CLI_TOKEN, so there is no config dir, keyring, or
# client_secret.json anywhere.
#
# One env var selects the Google account:
#
#   gws sheets spreadsheets get --params '{"spreadsheetId":"..."}'   # work
#   GWS_ACCOUNT=personal gws drive files list                        # personal
#
# Google-hosted APIs called with a user token need a quota project that has
# the API enabled; gws sends it as x-goog-user-project. Each account has a
# dedicated project for that, with the Workspace APIs already enabled:
#
#   work     jsymonds@joinklover.com  -> gws-cli-jsymonds
#   personal josh@joshsymonds.com     -> gws-cli-joshsymonds
#
# gcloud is resolved from PATH on purpose: its closure is large and only
# vermissian carries it (see flake.nix), so the wrapper is inert elsewhere.
{pkgs, ...}: let
  gws = pkgs.writeShellScriptBin "gws" ''
    account="''${GWS_ACCOUNT:-work}"
    case "$account" in
      work)     gacct=jsymonds@joinklover.com; quota=gws-cli-jsymonds ;;
      personal) gacct=josh@joshsymonds.com;    quota=gws-cli-joshsymonds ;;
      *) echo "gws: unknown GWS_ACCOUNT '$account' (work|personal)" >&2; exit 2 ;;
    esac
    if [ -z "''${GOOGLE_WORKSPACE_CLI_TOKEN:-}" ]; then
      GOOGLE_WORKSPACE_CLI_TOKEN="$(gcloud auth print-access-token --account="$gacct")" || {
        echo "gws: no gcloud token for $gacct; run: gcloud auth login $gacct --enable-gdrive-access" >&2
        exit 1
      }
      export GOOGLE_WORKSPACE_CLI_TOKEN
    fi
    export GOOGLE_WORKSPACE_PROJECT_ID="''${GOOGLE_WORKSPACE_PROJECT_ID:-$quota}"
    exec ${pkgs.gws}/bin/gws "$@"
  '';
in {
  home.packages = [gws];
}
