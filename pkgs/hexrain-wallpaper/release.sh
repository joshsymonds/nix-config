# hexrain-wallpaper-release — sign the hexrain wallpaper APK for shrike.
# Run from a nix-config checkout (`nix run .#hexrain-wallpaper-release`):
# builds the unsigned APK; if it differs from hosts/shrike/hexrain-
# wallpaper.apk, bumps pkgs/hexrain-wallpaper/version (Android only updates
# to a higher versionCode), rebuilds, and signs with the keystore decrypted
# from secrets/user/hexrain-wallpaper-keystore.age into a temp dir that is
# removed on exit. Then commit the APK and the version file; shrike's
# `update` installs it.
repo="$(git rev-parse --show-toplevel)"
cd "$repo"
apk=hosts/shrike/hexrain-wallpaper.apk
version_file=pkgs/hexrain-wallpaper/version
identity="${HEXRAIN_SIGNING_IDENTITY:-$HOME/.config/agenix/keys.txt}"

build() {
  nix build --no-link --print-out-paths .#hexrain-wallpaper-unsigned
}

unsigned="$(build)"
if [ -f "$apk" ]; then
  if same-content "$unsigned" "$apk"; then
    echo "hexrain-wallpaper: $apk is current (version $(cat "$version_file"))"
    exit 0
  fi
  echo $(($(cat "$version_file") + 1)) > "$version_file"
  unsigned="$(build)"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
age --decrypt -i "$identity" -o "$tmp/keystore.p12" secrets/user/hexrain-wallpaper-keystore.age
apksigner sign --ks "$tmp/keystore.p12" --ks-pass pass:hexrain-wallpaper --ks-key-alias hexrain \
  --out "$tmp/signed.apk" "$unsigned"
signer="$(apksigner verify --print-certs "$tmp/signed.apk" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')"
if [ "$signer" != "$(cat pkgs/hexrain-wallpaper/signer.sha256)" ]; then
  echo "hexrain-wallpaper: signed with $signer, not the pinned signer" >&2
  exit 1
fi
cp "$tmp/signed.apk" "$apk"
chmod 644 "$apk"
git add "$apk" "$version_file"
echo "hexrain-wallpaper: signed version $(cat "$version_file") -> $apk (staged; commit it)"
