# Behavioural check for orrery's metrics listeners on vermissian. The check reads
# the orreryd-start script that orreryd's ExecStart names, and orrery serve's
# ExecStart as text. Each must pass --metrics-listen with a loopback address.
# Nothing here runs orreryd, orrery serve or systemd.
{
  pkgs,
  vermissian,
}: let
  services = vermissian.home-manager.users.joshsymonds.systemd.user.services;
in
  pkgs.runCommand "orrery-alerts-check" {
    nativeBuildInputs = with pkgs; [bash coreutils gnugrep];
    # ExecStart is a list of words. orreryd's words are its start script path,
    # which keeps its context so the script is built into the sandbox. Serve's
    # words are only read as text, so its closure stays out of the build.
    orreryExecStart = builtins.concatStringsSep " " services.orreryd.Service.ExecStart;
    serveExecStart = builtins.unsafeDiscardStringContext (builtins.concatStringsSep " " services.orrery-serve.Service.ExecStart);
  } ''
    set -euo pipefail

    CASE=setup
    fail() {
      echo "orrery-alerts check [$CASE]: $1" >&2
      exit 1
    }

    # has_listen <addr> <file>: <file> carries --metrics-listen <addr> as one
    # whole argument. The dots in addr match only dots, not any character.
    has_listen() {
      local re=''${1//./[.]}
      grep -Eq -- "(^|[[:space:]])--metrics-listen ''${re}([[:space:]]|$)" "$2"
    }

    CASE=matcher
    printf '%s\n' 'exec orreryd --sessions --metrics-listen 127.0.0.1:9464' > ok.txt
    printf '%s\n' 'exec orreryd --sessions' > missing.txt
    printf '%s\n' 'exec orreryd --metrics-listen 0.0.0.0:9464' > wildcard.txt
    printf '%s\n' 'exec orreryd --metrics-listen 127.0.0.1:9465' > port.txt
    printf '%s\n' 'exec orreryd --metrics-listen 127x0x0x1:9464' > unescaped.txt
    has_listen 127.0.0.1:9464 ok.txt || fail "a loopback flag with the expected address did not match"
    ! has_listen 127.0.0.1:9464 missing.txt || fail "a file without the flag matched"
    ! has_listen 127.0.0.1:9464 wildcard.txt || fail "a wildcard host matched"
    ! has_listen 127.0.0.1:9464 port.txt || fail "a different port matched"
    ! has_listen 127.0.0.1:9464 unescaped.txt || fail "an unescaped dot matched a non-dot"

    # orreryd's ExecStart is the store path of the orreryd-start script, which
    # holds the orreryd command line.
    CASE=orreryd
    has_listen 127.0.0.1:9464 "$orreryExecStart" || fail "orreryd-start lacks --metrics-listen 127.0.0.1:9464"

    CASE=orrery-serve
    printf '%s\n' "$serveExecStart" > serve-exec-start.txt
    has_listen 127.0.0.1:9465 serve-exec-start.txt || fail "orrery serve lacks --metrics-listen 127.0.0.1:9465"

    touch $out
  ''
