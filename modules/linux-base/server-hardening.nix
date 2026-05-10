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
  ];
}
