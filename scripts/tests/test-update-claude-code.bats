#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

UPDATE_CLAUDE_CODE_PATH="${BATS_TEST_DIRNAME}/../update-claude-code.sh"

setup() {
  FIXTURE="$(mktemp -d)"
  REPO="$FIXTURE/repo"
  FAKE_BIN="$FIXTURE/bin"
  mkdir -p "$REPO/scripts" "$REPO/pkgs/claude-code-cli" "$FAKE_BIN"

  cp "$UPDATE_CLAUDE_CODE_PATH" "$REPO/scripts/update-claude-code.sh"
  write_package_fixture
  cp "$REPO/pkgs/claude-code-cli/default.nix" "$FIXTURE/package.before"

  export CURL_CALLS="$FIXTURE/curl.calls"
  export NIX_CALLS="$FIXTURE/nix.calls"
  export MANIFEST="$FIXTURE/manifest.json"
  export EXPECTED_VERSION="9.8.7"
  export CURL_FAILURE=""
  export NIX_HASH_FAILURE=""
  export NIX_INVALID_SRI_HASH=""
  export NIX_INVALID_SRI_OUTPUT=""
  export REAL_JQ
  REAL_JQ="$(command -v jq)"
  : >"$CURL_CALLS"
  : >"$NIX_CALLS"

  write_valid_manifest
  write_command_shims
}

teardown() {
  rm -rf "$FIXTURE"
}

write_package_fixture() {
  cat >"$REPO/pkgs/claude-code-cli/default.nix" <<'EOF'
{
  fetchurl,
}: let
  version = "1.2.3";
  gcsBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}";

  sources = {
    "aarch64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-arm64/claude";
      hash = "sha256-BRx/KIcbFYEyrAOmFA8vKrQEaxjsxPepGirE1Ud0VR4=";
    };
    "x86_64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-x64/claude";
      hash = "sha256-gE6oHLHitfiDwkkPxmj9Gc4YXje5uZkfWDLTjcYuL/Q=";
    };
    "x86_64-linux" = fetchurl {
      url = "${gcsBase}/linux-x64/claude";
      hash = "sha256-ElNyg5vIJ8ok3XI4JieykfvKYVQI1zL+MpG8FnI85/M=";
    };
    "aarch64-linux" = fetchurl {
      url = "${gcsBase}/linux-arm64/claude";
      hash = "sha256-geXdSDd7/Ty3M4IOTiPyKUySXLoeUtvq2mn0aSnwxKY=";
    };
  };
in
  sources
EOF
  chmod 0644 "$REPO/pkgs/claude-code-cli/default.nix"
}

write_valid_manifest() {
  cat >"$MANIFEST" <<'EOF'
{
  "version": "9.8.7",
  "platforms": {
    "darwin-arm64": {"checksum": "1111111111111111111111111111111111111111111111111111111111111111"},
    "darwin-x64": {"checksum": "2222222222222222222222222222222222222222222222222222222222222222"},
    "linux-x64": {"checksum": "3333333333333333333333333333333333333333333333333333333333333333"},
    "linux-arm64": {"checksum": "4444444444444444444444444444444444444444444444444444444444444444"}
  }
}
EOF
}

write_command_shims() {
  cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for argument in "$@"; do
  case "$argument" in
    http://*|https://*) url="$argument" ;;
  esac
done
printf '%s\n' "$url" >>"$CURL_CALLS"

if [ -n "$CURL_FAILURE" ]; then
  echo "simulated manifest network failure" >&2
  exit 22
fi

expected_url="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${EXPECTED_VERSION}/manifest.json"
if [ "$url" != "$expected_url" ]; then
  echo "unexpected URL: $url" >&2
  exit 64
fi
cat "$MANIFEST"
EOF

  cat >"$FAKE_BIN/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NIX_CALLS"
if [ "${1:-}" = "store" ] && [ "${2:-}" = "prefetch-file" ]; then
  echo "binary prefetch forbidden" >&2
  exit 64
fi

hash=""
for argument in "$@"; do
  hash="$argument"
done
if [ -n "$NIX_HASH_FAILURE" ] && [ "$hash" = "$NIX_HASH_FAILURE" ]; then
  echo "simulated hash conversion failure" >&2
  exit 1
fi
if [ -n "$NIX_INVALID_SRI_HASH" ] && [ "$hash" = "$NIX_INVALID_SRI_HASH" ]; then
  printf '%s\n' "$NIX_INVALID_SRI_OUTPUT"
  exit 0
fi
case "$hash" in
  1111111111111111111111111111111111111111111111111111111111111111)
    echo 'sha256-ERERERERERERERERERERERERERERERERERERERERERE='
    ;;
  2222222222222222222222222222222222222222222222222222222222222222)
    echo 'sha256-IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI='
    ;;
  3333333333333333333333333333333333333333333333333333333333333333)
    echo 'sha256-MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM='
    ;;
  4444444444444444444444444444444444444444444444444444444444444444)
    echo 'sha256-REREREREREREREREREREREREREREREREREREREREREQ='
    ;;
  *)
    echo "unexpected nix invocation: $*" >&2
    exit 64
    ;;
esac
EOF

  cat >"$FAKE_BIN/jq" <<'EOF'
#!/usr/bin/env bash
exec "$REAL_JQ" "$@"
EOF

  chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/nix" "$FAKE_BIN/jq"
}

run_updater() {
  run env PATH="$FAKE_BIN:$PATH" \
    CURL_CALLS="$CURL_CALLS" \
    NIX_CALLS="$NIX_CALLS" \
    MANIFEST="$MANIFEST" \
    EXPECTED_VERSION="$EXPECTED_VERSION" \
    CURL_FAILURE="$CURL_FAILURE" \
    NIX_HASH_FAILURE="$NIX_HASH_FAILURE" \
    NIX_INVALID_SRI_HASH="$NIX_INVALID_SRI_HASH" \
    NIX_INVALID_SRI_OUTPUT="$NIX_INVALID_SRI_OUTPUT" \
    REAL_JQ="$REAL_JQ" \
    bash "$REPO/scripts/update-claude-code.sh" "$@"
}

assert_package_unchanged() {
  cmp -s "$FIXTURE/package.before" "$REPO/pkgs/claude-code-cli/default.nix"
}

rewrite_manifest() {
  "$REAL_JQ" "$@" "$MANIFEST" >"$FIXTURE/manifest.tmp"
  mv "$FIXTURE/manifest.tmp" "$MANIFEST"
}

rewrite_package_with_sed() {
  sed "$@" "$REPO/pkgs/claude-code-cli/default.nix" >"$FIXTURE/package.tmp"
  mv "$FIXTURE/package.tmp" "$REPO/pkgs/claude-code-cli/default.nix"
  chmod 0644 "$REPO/pkgs/claude-code-cli/default.nix"
  cp "$REPO/pkgs/claude-code-cli/default.nix" "$FIXTURE/package.before"
}

make_package_current() {
  sed \
    -e 's/version = "1.2.3";/version = "9.8.7";/' \
    -e 's|sha256-BRx/KIcbFYEyrAOmFA8vKrQEaxjsxPepGirE1Ud0VR4=|sha256-ERERERERERERERERERERERERERERERERERERERERERE=|' \
    -e 's|sha256-gE6oHLHitfiDwkkPxmj9Gc4YXje5uZkfWDLTjcYuL/Q=|sha256-IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI=|' \
    -e 's|sha256-ElNyg5vIJ8ok3XI4JieykfvKYVQI1zL+MpG8FnI85/M=|sha256-MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM=|' \
    -e 's|sha256-geXdSDd7/Ty3M4IOTiPyKUySXLoeUtvq2mn0aSnwxKY=|sha256-REREREREREREREREREREREREREREREREREREREREREQ=|' \
    "$REPO/pkgs/claude-code-cli/default.nix" >"$FIXTURE/package.tmp"
  mv "$FIXTURE/package.tmp" "$REPO/pkgs/claude-code-cli/default.nix"
  chmod 0644 "$REPO/pkgs/claude-code-cli/default.nix"
  cp "$REPO/pkgs/claude-code-cli/default.nix" "$FIXTURE/package.before"
}

@test "valid manifest updates the version and four hashes without downloading binaries" {
  run_updater "9.8.7"

  [ "$status" -eq 0 ]
  grep -q 'version = "9.8.7";' "$REPO/pkgs/claude-code-cli/default.nix"
  grep -q 'hash = "sha256-ERERERERERERERERERERERERERERERERERERERERERE=";' "$REPO/pkgs/claude-code-cli/default.nix"
  grep -q 'hash = "sha256-IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI=";' "$REPO/pkgs/claude-code-cli/default.nix"
  grep -q 'hash = "sha256-MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM=";' "$REPO/pkgs/claude-code-cli/default.nix"
  grep -q 'hash = "sha256-REREREREREREREREREREREREREREREREREREREREREQ=";' "$REPO/pkgs/claude-code-cli/default.nix"
  [ "$(wc -l <"$CURL_CALLS" | tr -d ' ')" -eq 1 ]
  grep -qx 'https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/9.8.7/manifest.json' "$CURL_CALLS"
  ! grep -q '/claude$' "$CURL_CALLS"
  [ "$(wc -l <"$NIX_CALLS" | tr -d ' ')" -eq 4 ]
  [ "$(grep -c '^hash convert --hash-algo sha256 --from base16 --to sri ' "$NIX_CALLS")" -eq 4 ]
  ! grep -q 'store prefetch-file' "$NIX_CALLS"
}

@test "wrong argument counts fail before invoking network or nix" {
  run_updater

  [ "$status" -ne 0 ]
  [[ "$output" == *"usage:"* ]]
  [ ! -s "$CURL_CALLS" ]
  [ ! -s "$NIX_CALLS" ]
  assert_package_unchanged

  run_updater "1.2.3" "4.5.6"

  [ "$status" -ne 0 ]
  [[ "$output" == *"usage:"* ]]
  [ ! -s "$CURL_CALLS" ]
  [ ! -s "$NIX_CALLS" ]
  assert_package_unchanged
}

@test "malformed versions fail before invoking network or nix" {
  for version in "1.2" "v1.2.3" "1.2.3-" "1.2.3 bad" $'1.2.3\nbad'; do
    : >"$CURL_CALLS"
    : >"$NIX_CALLS"
    run_updater "$version"

    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid Claude Code version"* ]]
    [ ! -s "$CURL_CALLS" ]
    [ ! -s "$NIX_CALLS" ]
    assert_package_unchanged
  done
}

@test "manifest network failure preserves the package" {
  export CURL_FAILURE="1"
  run_updater "9.8.7"

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to download Claude Code manifest"* ]]
  assert_package_unchanged
}

@test "malformed manifest JSON preserves the package" {
  printf '%s\n' '{not JSON' >"$MANIFEST"
  run_updater "9.8.7"

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid Claude Code manifest"* ]]
  assert_package_unchanged
}

@test "mismatched manifest version preserves the package" {
  rewrite_manifest --arg version "9.8.6" '.version = $version'
  run_updater "9.8.7"

  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest version does not match requested version"* ]]
  assert_package_unchanged
}

@test "manifest version with a trailing newline is rejected atomically" {
  rewrite_manifest --arg version $'9.8.7\n' '.version = $version'
  run_updater "9.8.7"

  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest version does not match requested version"* ]]
  [ ! -s "$NIX_CALLS" ]
  assert_package_unchanged
}

@test "missing platform checksum preserves the package" {
  rewrite_manifest 'del(.platforms["linux-arm64"].checksum)'
  run_updater "9.8.7"

  [ "$status" -ne 0 ]
  [[ "$output" == *"missing or invalid checksum for linux-arm64"* ]]
  assert_package_unchanged
}

@test "invalid platform checksum is rejected before conversion and preserves the package" {
  for checksum in "not-base16" $'1111111111111111111111111111111111111111111111111111111111111111\njunk'; do
    rewrite_manifest --arg checksum "$checksum" '.platforms["darwin-arm64"].checksum = $checksum'
    : >"$NIX_CALLS"
    run_updater "9.8.7"

    [ "$status" -ne 0 ]
    [[ "$output" == *"missing or invalid checksum for darwin-arm64"* ]]
    [ ! -s "$NIX_CALLS" ]
    assert_package_unchanged
  done
}

@test "platform checksum with a trailing newline is rejected atomically" {
  checksum=$'1111111111111111111111111111111111111111111111111111111111111111\n'
  rewrite_manifest --arg checksum "$checksum" '.platforms["darwin-arm64"].checksum = $checksum'
  run_updater "9.8.7"

  [ "$status" -ne 0 ]
  [[ "$output" == *"missing or invalid checksum for darwin-arm64"* ]]
  [ ! -s "$NIX_CALLS" ]
  assert_package_unchanged
}

@test "hash conversion failure preserves the package" {
  export NIX_HASH_FAILURE="2222222222222222222222222222222222222222222222222222222222222222"
  run_updater "9.8.7"

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to convert checksum for darwin-x64"* ]]
  assert_package_unchanged
}

@test "invalid SRI conversion output preserves the package" {
  export NIX_INVALID_SRI_HASH="3333333333333333333333333333333333333333333333333333333333333333"
  for invalid_sri in "not-an-sri-hash" $'sha256-MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM=\njunk'; do
    export NIX_INVALID_SRI_OUTPUT="$invalid_sri"
    run_updater "9.8.7"

    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid converted checksum for linux-x64"* ]]
    assert_package_unchanged
  done
}

@test "missing version anchor preserves the package" {
  rewrite_package_with_sed 's/^  version = /  releaseVersion = /'
  run_updater "9.8.7"

  [ "$status" -ne 0 ]
  [[ "$output" == *"expected exactly one version assignment"* ]]
  assert_package_unchanged
}

@test "duplicate version anchors preserve the package" {
  rewrite_package_with_sed '/^  version = /p'
  run_updater "9.8.7"

  [ "$status" -ne 0 ]
  [[ "$output" == *"expected exactly one version assignment"* ]]
  assert_package_unchanged
}

@test "missing platform anchor preserves the package" {
  rewrite_package_with_sed 's/^    "aarch64-linux" = fetchurl {/    "arm64-linux" = fetchurl {/'
  run_updater "9.8.7"

  [ "$status" -ne 0 ]
  [[ "$output" == *"expected exactly one source block for aarch64-linux"* ]]
  assert_package_unchanged
}

@test "duplicate platform anchors preserve the package" {
  rewrite_package_with_sed '/^    "aarch64-darwin" = fetchurl {/p'
  run_updater "9.8.7"

  [ "$status" -ne 0 ]
  [[ "$output" == *"expected exactly one source block for aarch64-darwin"* ]]
  assert_package_unchanged
}

@test "missing platform hash anchor preserves the package" {
  rewrite_package_with_sed 's/^      hash = "sha256-gE6oHL/      sha256 = "sha256-gE6oHL/'
  run_updater "9.8.7"

  [ "$status" -ne 0 ]
  [[ "$output" == *"expected exactly one hash assignment for x86_64-darwin"* ]]
  assert_package_unchanged
}

@test "duplicate platform hash anchors preserve the package" {
  rewrite_package_with_sed '/^      hash = "sha256-ElNyg5/p'
  run_updater "9.8.7"

  [ "$status" -ne 0 ]
  [[ "$output" == *"expected exactly one hash assignment for x86_64-linux"* ]]
  assert_package_unchanged
}

@test "a non-whitespace installer version suffix is accepted" {
  export EXPECTED_VERSION="9.8.7-beta+build.5"
  rewrite_manifest --arg version "$EXPECTED_VERSION" '.version = $version'
  run_updater "$EXPECTED_VERSION"

  [ "$status" -eq 0 ]
  grep -q 'version = "9.8.7-beta+build.5";' "$REPO/pkgs/claude-code-cli/default.nix"
  grep -qx 'https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/9.8.7-beta+build.5/manifest.json' "$CURL_CALLS"
}

@test "generated package file has mode 0644" {
  chmod 0600 "$REPO/pkgs/claude-code-cli/default.nix"
  run_updater "9.8.7"

  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$REPO/pkgs/claude-code-cli/default.nix")" = "644" ]
}

@test "same version and hashes are a successful no-op preserving the inode" {
  make_package_current
  inode_before="$(ls -di "$REPO/pkgs/claude-code-cli/default.nix" | awk '{print $1}')"
  run_updater "9.8.7"
  inode_after="$(ls -di "$REPO/pkgs/claude-code-cli/default.nix" | awk '{print $1}')"

  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
  assert_package_unchanged
  [ "$inode_after" = "$inode_before" ]
}
