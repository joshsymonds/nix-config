{
  config,
  inputs,
  pkgs,
  ...
}: {
  imports = [
    ./common.nix
    inputs.niri-flake.homeModules.niri
    inputs.dms.homeModules.dank-material-shell
    inputs.dms.homeModules.niri
  ];

  home = {
    homeDirectory = "/home/joshsymonds";

    packages = with pkgs; [
      firefox
      file
      unzip
      gcc
    ];
  };

  # `update` alias mirrors the headless base's pattern
  programs.zsh.shellAliases.update = "nh os switch ${config.home.homeDirectory}/nix-config";

  systemd.user.startServices = "sd-switch";

  # DMS home-manager configuration. The DMS edge release made several of the
  # HM-side feature toggles built-in and no-op (they're now always available):
  # enableNightMode, enableSystemSound, enableClipboard, enableColorPicker,
  # enableBrightnessControl. enableSystemd was renamed to systemd.enable.
  # We only set the toggles that still have effect.
  programs.dank-material-shell = {
    enable = true;
    systemd.enable = true;
    enableAudioWavelength = true;
    enableCalendarEvents = true;
    enableClipboardPaste = true;
    enableDynamicTheming = true;
    enableSystemMonitoring = true;
    enableVPN = true;

    # niri ↔ DMS integration. DMS's `includes` mechanism (default-enabled)
    # merges DMS-generated config files (binds, colors, layout, outputs,
    # windowrules, etc.) into niri-flake's typed settings. `enableKeybinds`
    # is intentionally left at its default (false) — DMS warns against
    # using `enableKeybinds` and `includes.enable` together; `includes`
    # is the more declarative path.
    # `enableSpawn` autostarts the DMS user service (`dms run`) on niri startup.
    niri.enableSpawn = true;
  };
}
