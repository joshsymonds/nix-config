# Behavioural check for programs.claudeCode.trustRoots. The entry is vermissian's
# rendered claudeTrustRoots activation, run under bash against scratch HOME trees
# under the build directory. Nothing here reads or writes a real ~/.claude.json.
{
  pkgs,
  vermissian,
}: let
  entry = pkgs.writeText "claude-trust-roots-entry.sh" vermissian.home-manager.users.joshsymonds.home.activation.claudeTrustRoots.data;
in
  pkgs.runCommand "claude-trust-roots-check" {
    nativeBuildInputs = with pkgs; [bash coreutils diffutils findutils jq];
  } ''
    set -euo pipefail

    CASE=setup
    fail() {
      echo "claude-trust-roots check [$CASE]: $1" >&2
      exit 1
    }

    # make_home <home>: Work has git roots at levels 1 and 2 (a file .git for the
    # worktree at b) and one at level 3; Personal has one at level 1 and one at
    # level 2; Work/plain and Personal/p2 are plain folders. The home folder is a
    # git root too. .claude.json is 0600 with unrelated keys, an existing record
    # for Work/a with no trust key, and a false record for the plain Work/plain.
    make_home() {
      local home=$1
      mkdir -p "$home/Work/a/b/c" "$home/Work/plain" "$home/Personal/p1/q" "$home/Personal/p2" "$home/Other" "$home/.git"
      mkdir "$home/Work/a/.git" "$home/Work/a/b/c/.git" "$home/Personal/p1/.git" "$home/Personal/p1/q/.git"
      printf 'gitdir: /elsewhere\n' > "$home/Work/a/b/.git"
      jq -n --arg h "$home" '{
        numStartups: 7,
        mcpServers: {shimmer: {type: "http", url: "https://example.invalid/mcp"}},
        projects: {
          ($h + "/Work/a"): {allowedTools: ["Bash"], lastCost: 1.5},
          ($h + "/Work/plain"): {hasTrustDialogAccepted: false}
        }
      }' > "$home/.claude.json"
      chmod 600 "$home/.claude.json"
    }

    # run_entry <home>: the rendered entry, under the shell options Home Manager's
    # activation script sets, must exit 0. Its stderr is kept in stderr.txt.
    run_entry() {
      if ! HOME=$1 bash -eu -o pipefail ${entry} 2>"$PWD/stderr.txt"; then
        cat "$PWD/stderr.txt" >&2
        fail "the entry exited nonzero"
      fi
    }

    CASE=first-run
    home=$PWD/one/home
    make_home "$home"
    before=$PWD/one/before.json
    after=$home/.claude.json
    cp "$after" "$before"
    run_entry "$home"

    # Exactly the listed folders and the git roots at levels 1 to depth gain the
    # key: Work (depth 2) and Work/a, Work/a/b; Personal (depth 1) and Personal/p1.
    # Home, Work/plain, Personal/p2, Other and the level-3 and level-2-under-Personal
    # roots gain nothing. Unrelated keys and the existing record's fields are kept.
    expected=$PWD/one/expected.json
    jq -S --arg h "$home" '
      .projects[$h + "/Personal"] = {hasTrustDialogAccepted: true}
      | .projects[$h + "/Personal/p1"] = {hasTrustDialogAccepted: true}
      | .projects[$h + "/Work"] = {hasTrustDialogAccepted: true}
      | .projects[$h + "/Work/a"].hasTrustDialogAccepted = true
      | .projects[$h + "/Work/a/b"] = {hasTrustDialogAccepted: true}
    ' "$before" > "$expected"
    jq -S . "$after" | cmp -s - "$expected" || {
      diff "$expected" <(jq -S . "$after") >&2 || true
      fail "first run did not produce the expected ~/.claude.json"
    }
    [ "$(stat -c %a "$after")" = 600 ] || fail "mode is $(stat -c %a "$after"), want 600"

    CASE=second-run
    cp "$after" "$PWD/one/after1.json"
    inode=$(stat -c %i "$after")
    run_entry "$home"
    [ "$(stat -c %i "$after")" = "$inode" ] || fail "second run replaced ~/.claude.json"
    cmp -s "$after" "$PWD/one/after1.json" || fail "second run changed ~/.claude.json"
    [ "$(stat -c %a "$after")" = 600 ] || fail "second run changed the mode"

    CASE=invalid-json
    home=$PWD/two/home
    mkdir -p "$home/Work/a/.git"
    printf '{"projects": ' > "$home/.claude.json"
    chmod 600 "$home/.claude.json"
    before=$PWD/two/before.json
    cp "$home/.claude.json" "$before"
    run_entry "$home"
    grep -q claudeTrustRoots "$PWD/stderr.txt" || fail "no claudeTrustRoots warning on stderr"
    cmp -s "$home/.claude.json" "$before" || fail "invalid ~/.claude.json was changed"
    if find "$home" -name '.claude.json.*' | grep -q .; then
      fail "a temp file was left behind"
    fi

    # Valid JSON the merge cannot apply to: the rewrite fails, and the file must
    # survive it unchanged rather than be replaced by the empty temp file.
    CASE=failed-rewrite
    home=$PWD/four/home
    mkdir -p "$home/Work/a/.git"
    printf '{"projects": []}\n' > "$home/.claude.json"
    chmod 600 "$home/.claude.json"
    before=$PWD/four/before.json
    cp "$home/.claude.json" "$before"
    run_entry "$home"
    grep -q claudeTrustRoots "$PWD/stderr.txt" || fail "no claudeTrustRoots warning on stderr"
    cmp -s "$home/.claude.json" "$before" || fail "a failed rewrite changed ~/.claude.json"
    [ "$(stat -c %a "$home/.claude.json")" = 600 ] || fail "a failed rewrite changed the mode"
    if find "$home" -name '.claude.json.*' | grep -q .; then
      fail "a temp file was left behind"
    fi

    CASE=absent-file
    home=$PWD/three/home
    mkdir -p "$home/Work/a/.git"
    run_entry "$home"
    [ ! -e "$home/.claude.json" ] || fail "an absent ~/.claude.json was created"

    touch $out
  ''
