{...}: {
  imports = [
    ../aarch64-darwin.nix
  ];

  programs.git.settings.user.signingkey = "0x8B0D6CFA07BB41A5";

  programs.claudeCode.hostContext = ''
    # Host: ninuan (macOS, Apple Silicon)

    You are on `ninuan`. This is a **macOS** host (Apple M5 MacBook Pro) —
    not Linux, not another machine in the fleet.

    ## Hardware
    - Apple M5 (ARM64 / aarch64-darwin)
    - MacBook Pro

    ## Role
    Portable / on-the-go work machine. Most heavy dev still happens remotely
    on vermissian, but this is what gets used away from the desk. Aerospace
    tiling WM (not niri/DMS — those are Linux-only). nix-darwin + home-manager;
    macOS tooling (Homebrew etc.) layered on top. Note: ninuan does not accept
    inbound SSH.
  '';
}
