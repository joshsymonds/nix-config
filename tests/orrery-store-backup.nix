# Behavioural check for the orrery-litestream unit. The unit and its config come
# from the Home Manager module on vermissian. The config is run against scratch
# trees under the build directory only: nothing here reads or writes the real
# store, /mnt/claude or systemd.
{pkgs}: let
  module = import ../home-manager/orrery/backup.nix {
    inherit pkgs;
    hostname = "vermissian";
  };
  service = module.systemd.user.services.orrery-litestream.Service;
in
  pkgs.runCommand "orrery-store-backup-check" {
    nativeBuildInputs = with pkgs; [coreutils gnugrep sqlite yq-go];
  } ''
    set -euo pipefail

    CASE=setup
    fail() {
      echo "orrery-store-backup check [$CASE]: $1" >&2
      exit 1
    }

    # Writing the unit's commands out pulls their store paths into this build.
    printf '%s\n' "${service.ExecStart}" > exec-start.txt
    printf '%s\n' "${service.ExecStartPre}" > exec-start-pre.txt
    set -- $(cat exec-start.txt)
    [ "$#" -eq 4 ] && [ "$2" = replicate ] && [ "$3" = -config ] \
      || fail "ExecStart is not 'litestream replicate -config CFG'"
    bin=$1
    cfg=$4

    CASE=config
    [ -f "$cfg" ] || fail "the config ExecStart names does not exist"
    yq -e '.snapshot.retention == "336h"' "$cfg" >/dev/null || fail "snapshot.retention is not 336h"
    yq -e '.dbs | length == 1' "$cfg" >/dev/null || fail "config does not hold exactly one db"
    yq -e '.dbs[0].path == "$HOME/.local/state/orrery/orrery.db"' "$cfg" >/dev/null \
      || fail "db path is not the orrery store"
    yq -e '.dbs[0].truncate-page-n == -1' "$cfg" >/dev/null \
      || fail "truncate-page-n is not -1, so TRUNCATE checkpoints are not disabled"
    yq -e '.dbs[0].replica.type == "file"' "$cfg" >/dev/null || fail "replica is not a file replica"
    yq -e '.dbs[0].replica.path == "/mnt/claude/vermissian/orrery-litestream"' "$cfg" >/dev/null \
      || fail "replica path is not /mnt/claude/vermissian/orrery-litestream"
    if grep -Eq 'busy|journal' "$cfg"; then
      fail "config sets a busy-timeout or journal option"
    fi

    CASE=nas-guard
    # The build sandbox never mounts /mnt/claude, so the guard must refuse to start.
    if "$(cat exec-start-pre.txt)" 2>stderr.txt; then
      fail "ExecStartPre let the unit start without /mnt/claude mounted"
    fi
    grep -q 'not mounted' stderr.txt || fail "ExecStartPre did not report that /mnt/claude is not mounted"

    CASE=restart
    # A failed ExecStartPre is restarted under Restart=always, so the unit resumes
    # when the NAS returns. The start-rate limit must not stop those restarts.
    [ "${toString (service.Restart or "missing")}" = always ] || fail "Restart is not always"
    [ "${toString (module.systemd.user.services.orrery-litestream.Unit.StartLimitIntervalSec or "missing")}" = 0 ] \
      || fail "start-rate limiting is not disabled, so restarts can stop after a NAS outage"

    CASE=replicate-restore
    scratch=$PWD/scratch
    export HOME=$scratch/home
    export STORE=$scratch/store/orrery.db
    export REPLICA=$scratch/replica
    mkdir -p "$HOME" "$scratch/store"
    yq '.dbs[0].path = env(STORE) | .dbs[0].replica.path = env(REPLICA)' "$cfg" > scratch.yml

    sqlite3 "$STORE" 'PRAGMA journal_mode=WAL; CREATE TABLE events (id INTEGER PRIMARY KEY, stage INTEGER NOT NULL);'

    # stage N: three rows, then one replication pass that writes one LTX file.
    stage() {
      sqlite3 "$STORE" "INSERT INTO events (stage) VALUES ($1), ($1), ($1);"
      if ! "$bin" replicate -once -config scratch.yml >replicate.log 2>&1; then
        cat replicate.log >&2
        fail "replicate -once failed after stage $1"
      fi
    }

    # created_last: the created time of the newest level-0 LTX file.
    created_last() {
      "$bin" ltx -config scratch.yml -level 0 "$STORE" | tail -n1 | awk '{print $5}'
    }

    # one_second_after TIME: RFC 3339 for one second after TIME.
    one_second_after() {
      epoch=$(date -u -d "$1" +%s)
      date -u -d "@$((epoch + 1))" +%Y-%m-%dT%H:%M:%SZ
    }

    # ids: the ids in a database, comma separated.
    ids() {
      sqlite3 -noheader "$1" 'SELECT id FROM events ORDER BY id;' | paste -sd, -
    }

    # check_db FILE WANT: FILE passes integrity_check and holds exactly the ids WANT.
    check_db() {
      [ "$(sqlite3 "$1" 'PRAGMA integrity_check;')" = ok ] || fail "$1 fails integrity_check"
      [ "$(ids "$1")" = "$2" ] || fail "$1 holds [$(ids "$1")], want [$2]"
    }

    stage 1
    c1=$(created_last)
    sleep 2
    stage 2
    c2=$(created_last)
    sleep 2
    stage 3

    "$bin" restore -config scratch.yml -o "$PWD/at-stage-1.db" -timestamp "$(one_second_after "$c1")" "$STORE" \
      >restore.log 2>&1 || { cat restore.log >&2; fail "restore to stage 1 failed"; }
    check_db "$PWD/at-stage-1.db" 1,2,3

    "$bin" restore -config scratch.yml -o "$PWD/at-stage-2.db" -timestamp "$(one_second_after "$c2")" "$STORE" \
      >restore.log 2>&1 || { cat restore.log >&2; fail "restore to stage 2 failed"; }
    check_db "$PWD/at-stage-2.db" 1,2,3,4,5,6

    "$bin" restore -config scratch.yml -o "$PWD/latest.db" "$STORE" \
      >restore.log 2>&1 || { cat restore.log >&2; fail "latest restore failed"; }
    check_db "$PWD/latest.db" 1,2,3,4,5,6,7,8,9

    touch $out
  ''
