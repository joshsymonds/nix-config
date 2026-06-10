# Headless-server-only hardening. Imported by ultraviolet, bluedesert,
# echelon, vermissian. Adds modules that are safe to blacklist on a
# server with no peripheral plug-ins, but would break gnomon if we ever
# wanted Bluetooth peripherals back.
#
# Pairs with modules/linux-base/hardening.nix (universal). Server hosts
# import both; gnomon imports only the universal one.
{...}: {
  # Bluetooth — none of the headless servers enable hardware.bluetooth,
  # never have a paired device, never use BT-anything. Blacklisting
  # btusb prevents the USB transport from auto-binding if someone
  # plugs in a BT dongle (defense-in-depth against malicious dongles
  # and against future config drift accidentally enabling BT).
  boot.blacklistedKernelModules = [
    "bluetooth"
    "btusb"

    # Wi-Fi — every server runs wired (igc/i40e/r8169); onboard Wi-Fi
    # cards were auto-binding anyway (observed: mt7921e + mac80211 live
    # on vermissian, cfg80211 on ultraviolet). mac80211 has remote
    # frame-parsing CVE history (CVE-2022-41674, CVE-2022-42719/20/21
    # beacon-parsing series). Blacklist the stack plus every driver
    # family present in fleet hardware, current and plausible.
    "cfg80211"
    "mac80211"
    "mt7921e" # vermissian onboard (MediaTek MT7921)
    "iwlwifi" # Intel boxes (ultraviolet/bluedesert/echelon)
    "rtw89_pci" # Realtek family, defensive
    "rtw89_8922ae"
  ];
}
