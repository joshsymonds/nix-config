# shrike's declared Android app set. The nix-on-droid closure is the
# deterministic half of the phone; this file is the declared-but-imperative
# half. `update` on shrike reconciles against it: F-Droid apps are
# downloaded and handed to the system installer (one confirmation tap
# each — silent installs would need adb/Shizuku machinery we deliberately
# skipped), everything else is drift-reported with instructions.
#
# Categories:
#   local     — built in this repo (signed APK committed beside this file).
#               `update` installs it when missing or when the APK changed
#               since the last install it saw through.
#   fdroid    — installable by `update` via fdroidcl + termux-open.
#               id = Android package id as F-Droid names it.
#   obtainium — sourced from GitHub releases, tracked/updated by Obtainium
#               on-device. `update` only reports these missing.
#   play      — Play Store only; no programmatic path exists. `update`
#               reports these missing. This list IS the rebuild checklist.
{
  local = [
    # DMS's hexrain wallpaper as a live wallpaper (home + lock) — see
    # pkgs/hexrain-wallpaper and hosts/shrike/README.md.
    {
      id = "com.joshsymonds.hexrain";
      label = "Hexrain wallpaper";
      apk = ./hexrain-wallpaper.apk;
    }
  ];

  fdroid = [
    # The store app itself is the one F-Droid app `update` can't install
    # (nothing exists to install it with); it's listed so drift-reporting
    # covers a fresh phone. Bootstrap: browser → f-droid.org.
    {
      id = "org.fdroid.basic";
      label = "F-Droid Basic";
    }
    # SMS-bridge runtime (Termux:API only works inside Termux proper, not
    # nix-on-droid). Must come from F-Droid, never Play — and all Termux
    # pieces from the same source.
    {
      id = "com.termux";
      label = "Termux";
    }
    {
      id = "com.termux.api";
      label = "Termux:API";
    }
  ];

  obtainium = [
    {
      id = "dev.imranr.obtainium";
      label = "Obtainium";
      source = "https://github.com/ImranR98/Obtainium/releases";
    }
    # Patches the official Reddit app (ads hidden, links opened externally)
    # on-device from an APKMirror .apkm bundle. The patched Reddit it
    # installs is signed locally, so it's tracked by hand, not here.
    {
      id = "app.morphe.manager";
      label = "Morphe Manager";
      source = "https://github.com/MorpheApp/morphe-manager/releases";
    }
  ];

  play = [
    {
      id = "com.tailscale.ipn";
      label = "Tailscale";
    }
  ];
}
