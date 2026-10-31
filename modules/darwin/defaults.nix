{...}: {
  # Settings not yet in nix-darwin's system.defaults
  system.activationScripts.extraDefaults.text = ''
    defaults write NSGlobalDomain AppleReduceDesktopTinting -bool true
  '';

  system.defaults = {
    NSGlobalDomain = {
      AppleFontSmoothing = 1;
      AppleInterfaceStyle = "Dark";
      ApplePressAndHoldEnabled = false;
      AppleShowAllExtensions = true;
      AppleShowScrollBars = "Automatic";
      InitialKeyRepeat = 10;
      KeyRepeat = 1;
      NSAutomaticCapitalizationEnabled = false;
      NSAutomaticDashSubstitutionEnabled = false;
      NSAutomaticPeriodSubstitutionEnabled = false;
      NSAutomaticQuoteSubstitutionEnabled = false;
      NSAutomaticSpellingCorrectionEnabled = false;
      NSWindowResizeTime = 0.001;
      NSWindowShouldDragOnGesture = true;
      _HIHideMenuBar = false;
    };

    trackpad = {
      Clicking = true;
    };

    screencapture = {
      disable-shadow = true;
      location = "~/Desktop";
      type = "png";
    };

    dock = {
      autohide = true;
      autohide-delay = 0.0;
      autohide-time-modifier = 0.0;
      expose-animation-duration = 0.1;
      expose-group-apps = false;
      largesize = 128;
      launchanim = false;
      mineffect = "scale";
      minimize-to-application = true;
      mru-spaces = false;
      orientation = "bottom";
      persistent-apps = [
        "/Applications/1Password.app"
        "/Applications/Spark Desktop.app"
        "/Applications/Firefox.app"
        "/Applications/Nix Apps/kitty.app"
        "/Applications/Spotify.app"
        "/Applications/Obsidian.app"
        "/Applications/Signal.app"
        "/System/Applications/Messages.app"
        "/Applications/Claude.app"
      ];
      show-process-indicators = true;
      show-recents = false;
      tilesize = 36;
      wvous-bl-corner = 1;
      wvous-br-corner = 1;
      wvous-tl-corner = 1;
      wvous-tr-corner = 1;
    };

    finder = {
      CreateDesktop = false;
      FXDefaultSearchScope = "SCcf";
      FXEnableExtensionChangeWarning = false;
      FXPreferredViewStyle = "Nlsv";
      NewWindowTarget = "Desktop";
      ShowPathbar = true;
      ShowStatusBar = true;
      _FXShowPosixPathInTitle = true;
    };

    spaces = {
      spans-displays = true;
    };

    WindowManager = {
      StandardHideWidgets = true;
      StageManagerHideWidgets = true;
      EnableStandardClickToShowDesktop = false;
    };
  };
}
