# YubiKey U2F/FIDO authentication for local services.
#
# Wires `pam_u2f` into the four PAM stacks that gate everyday auth on a
# graphical NixOS desktop:
#
#   • sudo            — touch key to elevate in a terminal
#   • polkit-1        — GUI privilege prompts (NetworkManager, mounts,
#                       and 1Password's "Unlock using Linux desktop login")
#   • greetd          — DankGreeter boot login
#   • dankshell-u2f   — DMS (DankMaterialShell) screen lock
#
# DMS reads `/etc/pam.d/dankshell-u2f` by literal path and probes the
# stack for `pam_u2f.so` before offering U2F as an unlock factor. We
# satisfy that probe by enabling u2fAuth on a same-named PAM service —
# NixOS generates the file at the right path automatically.
#
# Intentionally NOT touched: sshd, su, login (tty). Recovery via tty
# (Ctrl+Alt+F2) and SSH continues to use password auth so a misconfigured
# or missing key never bricks the box.
#
# Control mode is `sufficient`: a successful U2F touch authenticates on
# its own and the password module is skipped. If the key is absent (or
# the auth file empty), PAM falls through to the normal password module.
# That preserves a safety net without weakening normal use — an attacker
# without a key still has to face your password.
#
# To upgrade to true 2FA (key + password every time) flip individual
# services to `required` by hand after enrollment is solid.
#
# Enrollment (one-time per user, after rebuild):
#
#   mkdir -p ~/.config/Yubico
#   # Primary key plugged in:
#   pamu2fcfg > ~/.config/Yubico/u2f_keys
#   # Swap to backup key, then:
#   pamu2fcfg -n >> ~/.config/Yubico/u2f_keys
#
# The file is per-user; keep it readable only by you (`chmod 600`).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.yubikey-auth;
in {
  options.services.yubikey-auth = {
    enable = lib.mkEnableOption "YubiKey U2F PAM auth for sudo/polkit/greetd/DMS lock";
  };

  config = lib.mkIf cfg.enable {
    security.pam.u2f = {
      enable = true;
      control = "sufficient";
      settings = {
        # Prompt "Please touch the device" on TTY (sudo). GUI stacks
        # (polkit, DMS) render their own UI and ignore the cue.
        cue = true;
        # Don't block waiting for a key to be inserted — if it's missing
        # at auth time, fall through to password immediately.
        interactive = false;
      };
    };

    security.pam.services = {
      sudo.u2f.enable = true;
      polkit-1.u2f.enable = true;
      greetd.u2f.enable = true;
      dankshell-u2f.u2f.enable = true;
    };

    # CCID smartcard daemon. The YubiKey enumerates as OTP+FIDO+CCID;
    # some 1Password and SSH-via-PIV flows want CCID present. Harmless
    # if unused.
    services.pcscd.enable = true;

    # Userspace tooling: pamu2fcfg for enrollment, ykman for key admin
    # (PIN, firmware, slot config).
    environment.systemPackages = with pkgs; [
      pam_u2f
      yubikey-manager
    ];

    # udev rules so the unprivileged user can talk to the YubiKey
    # (required for pamu2fcfg and ykman without sudo).
    services.udev.packages = [pkgs.yubikey-personalization];
  };
}
