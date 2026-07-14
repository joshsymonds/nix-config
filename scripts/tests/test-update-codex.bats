#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

UPDATE_CODEX_PATH="${BATS_TEST_DIRNAME}/../update-codex.sh"
CODEX_PACKAGE_PATH="${BATS_TEST_DIRNAME}/../../pkgs/codex"

setup() {
  FIXTURE="$(mktemp -d)"
  REPO="$FIXTURE/repo"
  FAKE_BIN="$FIXTURE/bin"
  mkdir -p "$REPO/scripts" "$REPO/pkgs/codex" "$FAKE_BIN"

  if [ -f "$UPDATE_CODEX_PATH" ]; then
    cp "$UPDATE_CODEX_PATH" "$REPO/scripts/update-codex.sh"
  fi

  printf 'original sources\n' >"$REPO/pkgs/codex/sources.json"
  cp "$REPO/pkgs/codex/sources.json" "$FIXTURE/sources.before"

  export CURL_CALLS="$FIXTURE/curl.calls"
  export CURL_ARGS="$FIXTURE/curl.args"
  export NIX_CALLS="$FIXTURE/nix.calls"
  export API_RESPONSE="$FIXTURE/api.json"
  export CHECKSUM_MANIFEST="$FIXTURE/codex-package_SHA256SUMS"
  export CURL_FAILURE=""
  export NIX_HASH_FAILURE=""
  export NIX_INVALID_SRI_HASH=""
  export NIX_INVALID_SRI_OUTPUT=""
  export JQ_GENERATION_FAILURE=""
  export REAL_JQ
  REAL_JQ="$(command -v jq)"
  : >"$CURL_CALLS"
  : >"$CURL_ARGS"
  : >"$NIX_CALLS"

  cat >"$API_RESPONSE" <<'EOF'
{"tag_name":"rust-v1.2.3","prerelease":false,"draft":false}
EOF
  write_valid_manifest
  write_command_shims
}

teardown() {
  rm -rf "$FIXTURE"
}

write_valid_manifest() {
  cat >"$CHECKSUM_MANIFEST" <<'EOF'
1111111111111111111111111111111111111111111111111111111111111111  codex-package-x86_64-unknown-linux-musl.tar.gz
2222222222222222222222222222222222222222222222222222222222222222  codex-package-aarch64-unknown-linux-musl.tar.gz
3333333333333333333333333333333333333333333333333333333333333333  codex-package-x86_64-apple-darwin.tar.gz
4444444444444444444444444444444444444444444444444444444444444444  codex-package-aarch64-apple-darwin.tar.gz
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
printf '%s\n' "$*" >>"$CURL_ARGS"

if [ "$CURL_FAILURE" = "api" ] && [ "$url" = "https://api.github.com/repos/openai/codex/releases/latest" ]; then
  echo "simulated API failure" >&2
  exit 22
fi
if [ "$CURL_FAILURE" = "manifest" ] && [[ "$url" == */codex-package_SHA256SUMS ]]; then
  echo "simulated manifest failure" >&2
  exit 22
fi

case "$url" in
  https://api.github.com/repos/openai/codex/releases/latest)
    cat "$API_RESPONSE"
    ;;
  */codex-package_SHA256SUMS)
    cat "$CHECKSUM_MANIFEST"
    ;;
  *)
    echo "unexpected URL: $url" >&2
    exit 64
    ;;
esac
EOF

  cat >"$FAKE_BIN/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NIX_CALLS"
if [ -n "$NIX_HASH_FAILURE" ]; then
  echo "simulated hash conversion failure" >&2
  exit 1
fi

hash=""
for argument in "$@"; do
  hash="$argument"
done
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
    echo "unexpected hash: $hash" >&2
    exit 64
    ;;
esac
EOF

  cat >"$FAKE_BIN/jq" <<'EOF'
#!/usr/bin/env bash
if [ -n "$JQ_GENERATION_FAILURE" ]; then
  for argument in "$@"; do
    if [ "$argument" = "-n" ]; then
      echo "simulated JSON generation failure" >&2
      exit 1
    fi
  done
fi
exec "$REAL_JQ" "$@"
EOF

  chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/nix" "$FAKE_BIN/jq"
}

run_updater() {
  run env PATH="$FAKE_BIN:$PATH" \
    CURL_CALLS="$CURL_CALLS" \
    CURL_ARGS="$CURL_ARGS" \
    NIX_CALLS="$NIX_CALLS" \
    API_RESPONSE="$API_RESPONSE" \
    CHECKSUM_MANIFEST="$CHECKSUM_MANIFEST" \
    CURL_FAILURE="$CURL_FAILURE" \
    NIX_HASH_FAILURE="$NIX_HASH_FAILURE" \
    NIX_INVALID_SRI_HASH="$NIX_INVALID_SRI_HASH" \
    NIX_INVALID_SRI_OUTPUT="$NIX_INVALID_SRI_OUTPUT" \
    JQ_GENERATION_FAILURE="$JQ_GENERATION_FAILURE" \
    REAL_JQ="$REAL_JQ" \
    bash "$REPO/scripts/update-codex.sh" "$@"
}

assert_sources_unchanged() {
  cmp -s "$FIXTURE/sources.before" "$REPO/pkgs/codex/sources.json"
}

@test "no argument resolves and pins the latest stable release" {
  run_updater

  [ "$status" -eq 0 ]
  [ "$(jq -r '.version' "$REPO/pkgs/codex/sources.json")" = "1.2.3" ]
  grep -qx 'https://api.github.com/repos/openai/codex/releases/latest' "$CURL_CALLS"
  [[ "$output" == *"resolving latest stable release"* ]]
}

@test "explicit version pins that release without resolving latest" {
  run_updater "9.8.7"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.version' "$REPO/pkgs/codex/sources.json")" = "9.8.7" ]
  ! grep -q '/releases/latest' "$CURL_CALLS"
  grep -qx 'https://github.com/openai/codex/releases/download/rust-v9.8.7/codex-package_SHA256SUMS' "$CURL_CALLS"
}

@test "rust-v prefix is normalized before pinning" {
  run_updater "rust-v9.8.7"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.version' "$REPO/pkgs/codex/sources.json")" = "9.8.7" ]
  grep -qx 'https://github.com/openai/codex/releases/download/rust-v9.8.7/codex-package_SHA256SUMS' "$CURL_CALLS"
}

@test "upstream alpha and beta versions are accepted" {
  for version in "1.2.3-alpha" "1.2.3-alpha.4" "1.2.3-beta" "1.2.3-beta.2"; do
    run_updater "$version"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.version' "$REPO/pkgs/codex/sources.json")" = "$version" ]
  done
}

@test "malformed version is rejected before network access" {
  run_updater "not-a-version"

  [ "$status" -ne 0 ]
  [ ! -s "$CURL_CALLS" ]
  [[ "$output" == *"invalid Codex version"* ]]
  assert_sources_unchanged
}

@test "latest release network failure preserves existing sources" {
  export CURL_FAILURE="api"
  run_updater

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to resolve latest Codex release"* ]]
  assert_sources_unchanged
}

@test "malformed latest release API data preserves existing sources" {
  printf '%s\n' '{"tag_name":42,"prerelease":false,"draft":false}' >"$API_RESPONSE"
  run_updater

  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed data"* ]]
  assert_sources_unchanged
}

@test "checksum manifest network failure preserves existing sources" {
  export CURL_FAILURE="manifest"
  run_updater "1.2.3"

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to download checksum manifest"* ]]
  assert_sources_unchanged
}

@test "missing package checksum is rejected atomically" {
  grep -v 'codex-package-aarch64-apple-darwin.tar.gz' "$CHECKSUM_MANIFEST" >"$FIXTURE/manifest.tmp"
  mv "$FIXTURE/manifest.tmp" "$CHECKSUM_MANIFEST"
  run_updater "1.2.3"

  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum missing"* ]]
  assert_sources_unchanged
}

@test "duplicate package checksum is rejected atomically" {
  printf '%s\n' '5555555555555555555555555555555555555555555555555555555555555555  codex-package-x86_64-unknown-linux-musl.tar.gz' >>"$CHECKSUM_MANIFEST"
  run_updater "1.2.3"

  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate checksum"* ]]
  assert_sources_unchanged
}

@test "invalid package checksum is rejected atomically" {
  grep -v 'codex-package-x86_64-apple-darwin.tar.gz' "$CHECKSUM_MANIFEST" >"$FIXTURE/manifest.tmp"
  printf '%s\n' 'not-a-sha256  codex-package-x86_64-apple-darwin.tar.gz' >>"$FIXTURE/manifest.tmp"
  mv "$FIXTURE/manifest.tmp" "$CHECKSUM_MANIFEST"
  run_updater "1.2.3"

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid checksum"* ]]
  assert_sources_unchanged
}

@test "hash conversion failure preserves existing sources" {
  export NIX_HASH_FAILURE=1
  run_updater "1.2.3"

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to convert checksum"* ]]
  assert_sources_unchanged
}

@test "invalid SRI conversion output preserves existing sources" {
  export NIX_INVALID_SRI_HASH="3333333333333333333333333333333333333333333333333333333333333333"
  export NIX_INVALID_SRI_OUTPUT="not-an-sri-hash"
  run_updater "1.2.3"

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to convert checksum"* ]]
  assert_sources_unchanged
}

@test "hash conversion explicitly declares base16 input for every platform" {
  run_updater "1.2.3"

  [ "$status" -eq 0 ]
  [ "$(wc -l <"$NIX_CALLS" | tr -d ' ')" -eq 4 ]
  grep -qx 'hash convert --hash-algo sha256 --from base16 --to sri 1111111111111111111111111111111111111111111111111111111111111111' "$NIX_CALLS"
  grep -qx 'hash convert --hash-algo sha256 --from base16 --to sri 2222222222222222222222222222222222222222222222222222222222222222' "$NIX_CALLS"
  grep -qx 'hash convert --hash-algo sha256 --from base16 --to sri 3333333333333333333333333333333333333333333333333333333333333333' "$NIX_CALLS"
  grep -qx 'hash convert --hash-algo sha256 --from base16 --to sri 4444444444444444444444444444444444444444444444444444444444444444' "$NIX_CALLS"
}

@test "release metadata downloads use bounded connection and overall timeouts" {
  run_updater

  [ "$status" -eq 0 ]
  grep -qx -- '-fsSL --connect-timeout 10 --max-time 60 https://api.github.com/repos/openai/codex/releases/latest' "$CURL_ARGS"
  grep -qx -- '-fsSL --connect-timeout 10 --max-time 60 https://github.com/openai/codex/releases/download/rust-v1.2.3/codex-package_SHA256SUMS' "$CURL_ARGS"
}

@test "install check rejects a longer version sharing the pinned prefix" {
  pinned_version="$("$REAL_JQ" -r .version "$CODEX_PACKAGE_PATH/sources.json")"
  install_check_phase="$(nix-instantiate --eval --strict --json -E "let pkgs = import <nixpkgs> {}; drv = pkgs.callPackage $CODEX_PACKAGE_PATH {}; in drv.installCheckPhase" | "$REAL_JQ" -r .)"
  fake_out="$FIXTURE/codex-out"
  mkdir -p "$fake_out/bin" "$fake_out/codex-path" "$fake_out/codex-resources"
  touch "$fake_out/bin/codex-code-mode-host" "$fake_out/codex-path/rg" "$fake_out/codex-resources/bwrap" "$fake_out/codex-package.json"
  cat >"$fake_out/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex-cli %s0\n' "$PINNED_VERSION"
EOF
  chmod +x "$fake_out/bin/codex" "$fake_out/bin/codex-code-mode-host" "$fake_out/codex-path/rg" "$fake_out/codex-resources/bwrap"

  run env out="$fake_out" PINNED_VERSION="$pinned_version" INSTALL_CHECK_PHASE="$install_check_phase" bash -c 'runHook() { :; }; eval "$INSTALL_CHECK_PHASE"'

  [ "$status" -ne 0 ]
  [[ "$output" == *"codex --version did not report $pinned_version"* ]]
}

@test "generated JSON contains all four system targets and SRI hashes" {
  run_updater "1.2.3"

  [ "$status" -eq 0 ]
  jq -e '
    . == {
      version: "1.2.3",
      sources: {
        "x86_64-linux": {
          target: "x86_64-unknown-linux-musl",
          hash: "sha256-ERERERERERERERERERERERERERERERERERERERERERE="
        },
        "aarch64-linux": {
          target: "aarch64-unknown-linux-musl",
          hash: "sha256-IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI="
        },
        "x86_64-darwin": {
          target: "x86_64-apple-darwin",
          hash: "sha256-MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM="
        },
        "aarch64-darwin": {
          target: "aarch64-apple-darwin",
          hash: "sha256-REREREREREREREREREREREREREREREREREREREREREQ="
        }
      }
    }
  ' "$REPO/pkgs/codex/sources.json"
}

@test "generated sources remain readable as a repository file" {
  run_updater "1.2.3"

  [ "$status" -eq 0 ]
  [ "$(ls -l "$REPO/pkgs/codex/sources.json" | awk '{ print $1 }')" = "-rw-r--r--" ]
}

@test "JSON generation failure preserves existing sources" {
  export JQ_GENERATION_FAILURE=1
  run_updater "1.2.3"

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to generate sources.json"* ]]
  assert_sources_unchanged
}

@test "unchanged generated content leaves sources file untouched" {
  run_updater "1.2.3"
  [ "$status" -eq 0 ]
  inode_before="$(ls -id "$REPO/pkgs/codex/sources.json" | awk '{ print $1 }')"

  run_updater "1.2.3"

  [ "$status" -eq 0 ]
  inode_after="$(ls -id "$REPO/pkgs/codex/sources.json" | awk '{ print $1 }')"
  [ "$inode_after" = "$inode_before" ]
  [[ "$output" == *"already up to date"* ]]
}
