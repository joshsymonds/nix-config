# Behavioural check for `tmux-status --json`. The script is built the way
# home-manager/tmux/default.nix builds it, except that a recording `sleep` sits
# first on PATH: it appends to $SLEEP_LOG and then runs coreutils' sleep. That
# is the only difference. Every run points TMUX_STATUS_DIR at a scratch
# directory, so the status bar's live state is never touched.
{pkgs}: let
  sleepRecorder = pkgs.writeShellScriptBin "sleep" ''
    echo called >> "$SLEEP_LOG"
    exec ${pkgs.coreutils}/bin/sleep "$@"
  '';
  tmuxStatus = pkgs.writeShellApplication {
    name = "tmux-status";
    runtimeInputs = [sleepRecorder] ++ (with pkgs; [coreutils gawk systemd util-linux]);
    text = builtins.readFile ../home-manager/tmux/scripts/tmux-status.sh;
  };
in
  pkgs.runCommand "tmux-status-check" {
    nativeBuildInputs = with pkgs; [coreutils diffutils jq];
  } ''
    set -euo pipefail

    CASE=setup
    fail() {
      echo "tmux-status check [$CASE]: $1" >&2
      exit 1
    }

    bin=${tmuxStatus}/bin/tmux-status
    export TMUX_STATUS_PSI=$PWD/no-psi
    export SLEEP_LOG=$PWD/sleep.log

    # The four files the status bar owns: its cache and its three baselines.
    bar_files="tmux-status.cache tmux-status.cpu.state tmux-status.net.state tmux-status.disk.state"

    check_json_shape() {
      jq -e '
        def keys_ok: (keys - ["label", "value", "level", "percent"]) == [];
        length == 5
        and ([.[].label] == ["net", "cpu", "ram", "disk io", "disk"])
        and all(.[]; keys_ok and has("value") and has("level")
          and (.level == "ok" or .level == "warn" or .level == "crit"))
        and all(.[] | select(has("percent")); (.percent | type) == "number")
        and ([.[] | select(has("percent")) | .label] == ["cpu", "ram", "disk"])
      ' "$1" > /dev/null || fail "$2"
    }

    CASE=bar-then-json
    export TMUX_STATUS_DIR=$PWD/case1
    "$bin" > bar1.txt || fail "bar run 1 failed"
    [[ -s $TMUX_STATUS_DIR/tmux-status.cache ]] || fail "bar run 1 wrote no cache"
    mkdir before
    for f in $bar_files; do cp "$TMUX_STATUS_DIR/$f" "before/$f"; done
    "$bin" --json > json1.txt || fail "--json run failed"
    for f in $bar_files; do
      cmp -s "before/$f" "$TMUX_STATUS_DIR/$f" || fail "--json changed the bar's $f"
    done
    check_json_shape json1.txt "--json output has the wrong shape"

    CASE=bar-window
    # Run 2 reuses the baselines run 1 left (timestamp t1, checked above) when
    # they are under 15 s old. Reuse does not sleep; only the rebaseline path
    # sleeps. The empty-directory run is the control: it must sleep, which shows
    # the recorder is live. Only then does run 2 count as having reused run 1.
    TMUX_STATUS_DIR=$PWD/case2 "$bin" > /dev/null || fail "bar run on an empty directory failed"
    [[ -s $SLEEP_LOG ]] || fail "the sleep recorder logged nothing on an empty directory"
    read -r t1 _ < before/tmux-status.cpu.state
    touch -d @0 "$TMUX_STATUS_DIR/tmux-status.cache"
    : > "$SLEEP_LOG"
    "$bin" > bar2.txt || fail "bar run 2 failed"
    read -r t2 _ < "$TMUX_STATUS_DIR/tmux-status.cpu.state"
    (( t2 > t1 )) || fail "bar run 2 wrote no new baseline ($t1 -> $t2)"
    [[ ! -s $SLEEP_LOG ]] || fail "bar run 2 rebaselined instead of reusing run 1's window"

    CASE=json-empty-dir
    export TMUX_STATUS_DIR=$PWD/case3
    "$bin" --json > json3.txt || fail "--json on an empty directory failed"
    for f in $bar_files; do
      [[ ! -e $TMUX_STATUS_DIR/$f ]] || fail "--json created the bar's $f"
    done
    check_json_shape json3.txt "--json output has the wrong shape (empty directory)"

    CASE=json-state-repair
    export TMUX_STATUS_DIR=$PWD/case4
    mkdir "$TMUX_STATUS_DIR"
    printf 'garbage\n' > "$TMUX_STATUS_DIR/tmux-status.json.cpu.state"
    printf '0 1 2\n' > "$TMUX_STATUS_DIR/tmux-status.json.net.state"
    start=$(date +%s%N)
    "$bin" --json > json4.txt || fail "--json with malformed and stale state failed"
    check_json_shape json4.txt "--json output has the wrong shape (repaired state)"
    for f in cpu net disk; do
      read -r ts _ < "$TMUX_STATUS_DIR/tmux-status.json.$f.state" || true
      [[ $ts =~ ^[0-9]+$ ]] && (( ts >= start )) || fail "--json $f state was not rebaselined"
    done

    touch $out
  ''
