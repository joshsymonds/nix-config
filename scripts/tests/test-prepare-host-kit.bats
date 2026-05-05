#!/usr/bin/env bats
#
# Hermetic test harness for scripts/prepare-host-kit.sh.
#
# Each test runs in a fresh fixture under $BATS_TMPDIR. The fixture mirrors
# the real flake's secrets layout (compat shim at repo root, real definitions
# under secrets/). Real age keypairs are generated for fixture identities;
# real plaintext is encrypted into mock .age files. Tests assert that the
# script's re-key path preserves plaintext content end-to-end — the test
# that would have caught the EDITOR=true wipe bug from Task #14.
#
# Run via:  ./scripts/tests/run.sh
# Or:       nix-shell -p bats age openssh ssh-to-age --run \
#             "bats scripts/tests/test-prepare-host-kit.bats"

SCRIPT_PATH="${BATS_TEST_DIRNAME}/../prepare-host-kit.sh"

# Generate a fresh age private key in $1, echo the corresponding public key.
generate_age_keypair() {
  age-keygen -o "$1" 2>/dev/null
  age-keygen -y "$1"
}

# Encrypt stdin to file $1 with the listed public-key recipients.
encrypt_to() {
  local outfile="$1"; shift
  local args=()
  for r in "$@"; do args+=(--recipient "$r"); done
  age "${args[@]}" -o "$outfile"
}

setup() {
  FIXTURE="$(mktemp -d)"
  export HOME="$FIXTURE/home"
  export REPO_ROOT="$FIXTURE/repo"
  export STASH_BASE="$HOME/.local/share/host-kits"

  mkdir -p "$HOME/.config/agenix"
  mkdir -p "$REPO_ROOT/secrets/hosts/host-a"
  mkdir -p "$REPO_ROOT/secrets/user"

  # Real age keypairs for the fixture's existing identities. The user's
  # identity goes at the standard agenix path so the script picks it up
  # via -i ~/.config/agenix/keys.txt with HOME redirected.
  USER_PUB="$(generate_age_keypair "$HOME/.config/agenix/keys.txt")"
  HOST_A_HOST_PUB="$(generate_age_keypair "$FIXTURE/host-a-host.key")"
  NINUAN_HOST_PUB="$(generate_age_keypair "$FIXTURE/ninuan-host.key")"
  NINUAN_USER_PUB="$(generate_age_keypair "$FIXTURE/ninuan-user.key")"

  # Mock plaintext we'll verify is unchanged after re-key.
  HOST_A_PLAINTEXT="host-a-secret-content-${BATS_TEST_NUMBER}-${RANDOM}"
  USER_PLAINTEXT="user-secret-content-${BATS_TEST_NUMBER}-${RANDOM}"

  # Fixture keys.nix mirrors the real schema closely enough for the
  # script's sed anchors (which look for `ninuan = "..."` and
  # `"joshsymonds@ninuan" = "..."` lines).
  cat >"$REPO_ROOT/secrets/keys.nix" <<EOF
let
  hosts = {
    host-a = "$HOST_A_HOST_PUB";
    ninuan = "$NINUAN_HOST_PUB";
  };
  users = {
    "joshsymonds@host-a" = "$USER_PUB";
    "joshsymonds@ninuan" = "$NINUAN_USER_PUB";
  };
  allUserKeys = builtins.attrValues users;
in {
  host-a = [hosts.host-a] ++ allUserKeys;
  joshsymonds = allUserKeys;
}
EOF

  # Fixture secrets/secrets.nix maps mock files to recipient lists.
  cat >"$REPO_ROOT/secrets/secrets.nix" <<'EOF'
let
  keys = import ./keys.nix;
in {
  "secrets/hosts/host-a/secret.age".publicKeys = keys.host-a;
  "secrets/user/usersecret.age".publicKeys = keys.joshsymonds;
}
EOF

  # Compat shim at repo root (mirrors the real repo's pattern).
  cat >"$REPO_ROOT/secrets.nix" <<'EOF'
import ./secrets/secrets.nix
EOF

  # Encrypt mock plaintext into mock .age files with the SAME recipients
  # as keys.nix declares — i.e., what a real `agenix -e` would produce
  # for the original schema (host key + all 2 user keys = 3 recipients).
  echo "$HOST_A_PLAINTEXT" | encrypt_to \
    "$REPO_ROOT/secrets/hosts/host-a/secret.age" \
    "$HOST_A_HOST_PUB" "$USER_PUB" "$NINUAN_USER_PUB"
  echo "$USER_PLAINTEXT" | encrypt_to \
    "$REPO_ROOT/secrets/user/usersecret.age" \
    "$USER_PUB" "$NINUAN_USER_PUB"

  # Initialize git and commit the fixture so the script's clean-tree
  # check passes. Use -c overrides to avoid touching ~/.gitconfig.
  cd "$REPO_ROOT"
  git init -q -b main
  git -c user.email=t@t -c user.name=t add -A
  git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "fixture initial state"
}

teardown() {
  rm -rf "$FIXTURE"
}

# ─── Test cases ───────────────────────────────────────────────────────

@test "happy path: keys subcommand exits 0 and prints user pubkey" {
  run "$SCRIPT_PATH" keys host-b
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh-ed25519 "*"josh+host-b@joshsymonds.com"* ]]
}

@test "stash directory has the 5 expected files with correct permissions" {
  "$SCRIPT_PATH" keys host-b
  for f in ssh_host_ed25519_key ssh_host_ed25519_key.pub host-b.agekey id_ed25519 id_ed25519.pub; do
    [ -f "$STASH_BASE/host-b/$f" ] || { echo "missing: $f"; return 1; }
  done
  [ "$(stat -c %a "$STASH_BASE/host-b")" = "700" ]
  [ "$(stat -c %a "$STASH_BASE/host-b/host-b.agekey")" = "600" ]
}

@test "secrets/keys.nix gains host-b in all three locations" {
  "$SCRIPT_PATH" keys host-b
  grep -qE '^    host-b = "age1[a-z0-9]+";' "$REPO_ROOT/secrets/keys.nix"
  grep -qE '^    "joshsymonds@host-b" = "age1[a-z0-9]+";' "$REPO_ROOT/secrets/keys.nix"
  grep -qE '^  host-b = \[hosts\.host-b\] \+\+ allUserKeys;' "$REPO_ROOT/secrets/keys.nix"
}

@test "DATA INTEGRITY: every .age file decrypts to its ORIGINAL plaintext after re-key" {
  "$SCRIPT_PATH" keys host-b

  decrypted_host_a="$(age --decrypt -i "$HOME/.config/agenix/keys.txt" "$REPO_ROOT/secrets/hosts/host-a/secret.age")"
  decrypted_user="$(age --decrypt -i "$HOME/.config/agenix/keys.txt" "$REPO_ROOT/secrets/user/usersecret.age")"

  [ "$decrypted_host_a" = "$HOST_A_PLAINTEXT" ] || {
    echo "host-a plaintext changed: expected '$HOST_A_PLAINTEXT', got '$decrypted_host_a'"
    return 1
  }
  [ "$decrypted_user" = "$USER_PLAINTEXT" ] || {
    echo "user plaintext changed: expected '$USER_PLAINTEXT', got '$decrypted_user'"
    return 1
  }
}

@test "recipient count grows by exactly one for each .age file" {
  before_hosta=$(grep -aE '^-> X25519' "$REPO_ROOT/secrets/hosts/host-a/secret.age" | wc -l)
  before_user=$(grep -aE '^-> X25519' "$REPO_ROOT/secrets/user/usersecret.age" | wc -l)

  "$SCRIPT_PATH" keys host-b

  after_hosta=$(grep -aE '^-> X25519' "$REPO_ROOT/secrets/hosts/host-a/secret.age" | wc -l)
  after_user=$(grep -aE '^-> X25519' "$REPO_ROOT/secrets/user/usersecret.age" | wc -l)

  [ "$((after_hosta - before_hosta))" -eq 1 ] || {
    echo "host-a: $before_hosta -> $after_hosta (expected +1)"
    return 1
  }
  [ "$((after_user - before_user))" -eq 1 ] || {
    echo "user: $before_user -> $after_user (expected +1)"
    return 1
  }
}

@test "idempotency: re-running with same hostname fails" {
  "$SCRIPT_PATH" keys host-b
  run "$SCRIPT_PATH" keys host-b
  [ "$status" -ne 0 ]
}

@test "dirty tree: refuses to run, makes no modifications" {
  echo "dirt" >>"$REPO_ROOT/secrets/keys.nix"
  before_keys="$(cat "$REPO_ROOT/secrets/keys.nix")"

  run "$SCRIPT_PATH" keys host-b
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted changes"* ]]

  [ ! -e "$STASH_BASE/host-b" ]
  [ "$(cat "$REPO_ROOT/secrets/keys.nix")" = "$before_keys" ]
}

@test "missing identity file: refuses to run with clear diagnostic" {
  rm "$HOME/.config/agenix/keys.txt"

  run "$SCRIPT_PATH" keys host-b
  [ "$status" -ne 0 ]
  [[ "$output" == *"agenix"* ]]
  [ ! -e "$STASH_BASE/host-b" ]
}

@test "missing required command: refuses to run with non-zero exit" {
  # Drop everything from PATH; the script's dep checks should catch a
  # missing tool. (clean-tree check uses git, which is also gone — same
  # outcome: refuse to run.)
  PATH="$HOME/no-such-dir" run "$SCRIPT_PATH" keys host-b
  [ "$status" -ne 0 ]
  [ ! -e "$STASH_BASE/host-b" ]
}

@test "broken sed anchor in keys.nix is detected before .age modifications" {
  # Remove the ninuan = "..." line that the script's first sed anchor
  # depends on. Commit so the clean-tree check passes.
  sed -i '/ninuan =/d' "$REPO_ROOT/secrets/keys.nix"
  cd "$REPO_ROOT"
  git -c user.email=t@t -c user.name=t add -A
  git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "break anchor"

  before_age_mtime="$(stat -c %Y "$REPO_ROOT/secrets/hosts/host-a/secret.age")"

  run "$SCRIPT_PATH" keys host-b
  [ "$status" -ne 0 ]
  [[ "$output" == *"anchor pattern not found"* ]]

  # .age files must not have been modified
  after_age_mtime="$(stat -c %Y "$REPO_ROOT/secrets/hosts/host-a/secret.age")"
  [ "$before_age_mtime" = "$after_age_mtime" ]
}

@test "hostname with hyphens (foo-bar-baz) is handled correctly" {
  "$SCRIPT_PATH" keys foo-bar-baz

  [ -d "$STASH_BASE/foo-bar-baz" ]
  grep -q 'foo-bar-baz = "age1' "$REPO_ROOT/secrets/keys.nix"
  grep -q '"joshsymonds@foo-bar-baz"' "$REPO_ROOT/secrets/keys.nix"
  grep -q 'foo-bar-baz = \[hosts.foo-bar-baz\]' "$REPO_ROOT/secrets/keys.nix"
}

@test "data integrity also holds for hyphenated hostnames" {
  "$SCRIPT_PATH" keys foo-bar-baz

  decrypted="$(age --decrypt -i "$HOME/.config/agenix/keys.txt" "$REPO_ROOT/secrets/user/usersecret.age")"
  [ "$decrypted" = "$USER_PLAINTEXT" ]
}
