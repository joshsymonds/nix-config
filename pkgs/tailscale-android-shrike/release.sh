# tailscale-android-shrike — build Tailscale for Android 1.104.5 plus PR #901
# as a release APK and sign it with the keystore in agenix. Run as
# `nix run .#tailscale-android-shrike`; default.nix supplies the environment
# (ANDROID_HOME, ANDROID_SDK_ROOT, JAVA_HOME, TS_BUILD_TOOLS, TS_PATCH,
# TS_SIGNER_PIN, TS_KEYSTORE, TS_MULTITUN_TEST).
#
# Order: early exit when the recorded pins match and the APK exists; the three
# pin checks (source commit, Go toolchain archive, patched file); the R4
# multiTUN runner on the build checkout; make libtailscale; Gradle assembleRelease;
# signing and the signer, debuggable and version checks. Facts are written to
# ${XDG_STATE_HOME:-$HOME/.local/state}/tailscale-android-shrike/ only after
# every check passed.

source_tag=1.104.5-t788384763-gd8673104f
source_commit=d8673104f600c05b8c20b64d0e70951ed670236a
go_rev=7ef7b403648ac3a9481a6e88e8b894eff50b0167
go_sha256=d7add016a4fa533fbd44e5ec07375c8c50f2a0afcc2ea7cc6fee3421488bd40c
patched_blob=23f7b2badf3874bcdce9e936d2c94ab7b68f74c5
signer_alias=tailscale-android-shrike
store_password=tailscale-android-shrike

die() {
  echo "tailscale-android-shrike: $*" >&2
  exit 1
}

write_pins() {
  printf 'source-commit=%s\n' "$source_commit"
  printf 'go-toolchain=%s %s\n' "$go_rev" "$go_sha256"
  printf 'patched-blob=%s\n' "$patched_blob"
}

sha256_of() {
  sha256sum "$1" | cut -d' ' -f1
}

state="${XDG_STATE_HOME:-$HOME/.local/state}/tailscale-android-shrike"
apk="$state/tailscale-android-shrike.apk"

print_facts() {
  echo "tailscale-android-shrike: $apk"
  cat "$state/tailscale-android-shrike.apk.sha256" "$state/version" "$state/signer.sha256" "$state/pins"
}

if [ -f "$apk" ] && [ -f "$state/pins" ] && cmp -s "$state/pins" <(write_pins); then
  echo "tailscale-android-shrike: APK for the current pins exists; not rebuilding"
  print_facts
  exit 0
fi

cache="$HOME/.cache/tailscale-android-shrike"
mkdir -p "$cache"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GOTOOLCHAIN=local
export GRADLE_USER_HOME="$cache/gradle-home"
export ANDROID_USER_HOME="$cache/android-user-home"
export GOPATH="$cache/gopath"
export GOMODCACHE="$cache/gomodcache"
export GOCACHE="$cache/gocache"
export TS_MKVERSION_OSS_GIT_CACHE="$cache/tailscale-oss"

build="$(mktemp -d "$cache/build.XXXXXX")"
keys=""
cleanup() {
  rm -rf "$build"
  if [ -n "$keys" ]; then
    rm -rf "$keys"
  fi
}
trap cleanup EXIT

# Pin 1: the release tag must resolve to the pinned commit.
src="$build/tailscale-android"
mkdir "$src"
git -C "$src" init --quiet
git -C "$src" fetch --quiet https://github.com/tailscale/tailscale-android "refs/tags/$source_tag:refs/tags/$source_tag" ||
  die "cannot fetch tag $source_tag from tailscale-android"
fetched="$(git -C "$src" rev-parse --verify --quiet "refs/tags/$source_tag^{commit}")" || true
if [ "$fetched" != "$source_commit" ]; then
  die "pin source-commit: tag $source_tag resolves to ${fetched:-nothing}, pinned $source_commit"
fi
git -C "$src" -c advice.detachedHead=false checkout --quiet --detach "$source_commit"

# Pin 2: the checkout's Go toolchain revision and the archive it names.
if [ "$(cat "$src/go.toolchain.rev")" != "$go_rev" ]; then
  die "pin go-toolchain: checkout names $(cat "$src/go.toolchain.rev"), pinned $go_rev"
fi
archive="$cache/go-$go_rev-linux-amd64.tar.gz"
go_url="https://github.com/tailscale/go/releases/download/build-$go_rev/linux-amd64.tar.gz"
if [ ! -f "$archive" ] || [ "$(sha256_of "$archive")" != "$go_sha256" ]; then
  rm -f "$archive"
  curl --fail --location --silent --show-error -o "$archive.part" "$go_url"
  got="$(sha256_of "$archive.part")"
  if [ "$got" != "$go_sha256" ]; then
    rm -f "$archive.part"
    die "pin go-toolchain: $go_url has sha256 $got, pinned $go_sha256"
  fi
  mv "$archive.part" "$archive"
fi
toolchain="$build/go-toolchain"
mkdir "$toolchain"
tar -xzf "$archive" -C "$toolchain" --strip-components=1
export TOOLCHAINDIR="$toolchain"
export PATH="$toolchain/bin:$PATH"

# Pin 3: the stored patch, committed on the pinned commit with a fixed
# committer so the version's -g hash is the same on every run.
GIT_COMMITTER_NAME=tailscale-android-shrike GIT_COMMITTER_EMAIL=build@localhost \
  GIT_COMMITTER_DATE='1970-01-01T00:00:00+0000' \
  git -C "$src" -c commit.gpgSign=false am --quiet "$TS_PATCH"
if [ "$(git -C "$src" rev-parse "HEAD:libtailscale/multitun.go")" != "$patched_blob" ]; then
  die "pin patched-blob: libtailscale/multitun.go at HEAD is not $patched_blob"
fi
if [ "$(git -C "$src" diff --name-only "$source_commit" HEAD)" != "libtailscale/multitun.go" ]; then
  die "the patch commit must change only libtailscale/multitun.go"
fi
if [ -n "$(git -C "$src" status --porcelain)" ]; then
  die "the patched checkout is not clean"
fi

# R4: the multiTUN regression runner against the unpatched and patched file.
CGO_ENABLED=1 "$TS_MULTITUN_TEST" "$src" "$source_commit"

# tailscale.version is generated from the clean checkout, the way make's
# tailscale.version rule does it, so the version carries no -dirty.
(cd "$src" && go run tailscale.com/cmd/mkversion > tailscale.version)
# tool/go and build-tags.sh start with #!/bin/bash, which NixOS does not
# provide. Point just those two shebangs at this bash; the version is already
# written, so the build's tree state does not reach it.
bash_path="$(command -v bash)"
sed -i "1s|^#!/bin/bash\$|#!${bash_path}|" "$src/tool/go" "$src/build-tags.sh"

# Run from the build tree: the Makefile takes GOBIN from $PWD, and make -C
# leaves the inherited PWD in place.
(cd "$src" && make libtailscale)

(
  cd "$src/android"
  ./gradlew --no-daemon \
    -Pandroid.aapt2FromMavenOverride="$TS_BUILD_TOOLS/aapt2" \
    -Pkotlin.compiler.execution.strategy=in-process \
    assembleRelease
)
unsigned="$src/android/build/outputs/apk/release/android-release-unsigned.apk"
[ -f "$unsigned" ] || die "Gradle did not produce $unsigned"

version="$(sed -n 's/^VERSION_LONG="\([^"]*\)"$/\1/p' "$src/tailscale.version")"
[ -n "$version" ] || die "tailscale.version has no VERSION_LONG"
case $version in
*t788384763*) ;;
*) die "version $version does not carry t788384763" ;;
esac
if [ "$version" = "$source_tag" ]; then
  die "version $version is Play's version"
fi

# Signing: the keystore lives only in a private temp dir for this run.
identity="${TAILSCALE_ANDROID_SIGNING_IDENTITY:-$HOME/.config/agenix/keys.txt}"
keys="$(mktemp -d -p "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}")"
age --decrypt -i "$identity" -o "$keys/keystore.p12" "$TS_KEYSTORE"
"$TS_BUILD_TOOLS/apksigner" sign --ks "$keys/keystore.p12" --ks-key-alias "$signer_alias" \
  --ks-pass "pass:$store_password" --out "$keys/signed.apk" "$unsigned"

verified="$("$TS_BUILD_TOOLS/apksigner" verify --print-certs "$keys/signed.apk")"
signer="$(printf '%s\n' "$verified" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')"
signer_pin="$(cat "$TS_SIGNER_PIN")"
if [ "$signer" != "$signer_pin" ]; then
  die "signed with $signer, not the pinned signer $signer_pin"
fi

badging="$("$TS_BUILD_TOOLS/aapt2" dump badging "$keys/signed.apk")"
case $badging in
*application-debuggable*) die "the signed APK is debuggable" ;;
esac
case $badging in
*"versionName='$version'"*) ;;
*) die "the signed APK does not carry versionName $version" ;;
esac

mkdir -p "$state"
install -m 644 "$keys/signed.apk" "$apk"
(cd "$state" && sha256sum tailscale-android-shrike.apk > tailscale-android-shrike.apk.sha256)
printf '%s\n' "$version" > "$state/version"
printf '%s\n' "$signer" > "$state/signer.sha256"
write_pins > "$state/pins"
print_facts
