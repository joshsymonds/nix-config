_: {
  programs.lazygit = {
    enable = true;

    # Minimal catppuccin-mocha accent so it doesn't clash visually with the
    # rest of the terminal stack (kitty/starship/DMS all run mocha).
    settings = {
      gui.theme = {
        activeBorderColor = ["#89b4fa" "bold"];
        inactiveBorderColor = ["#6c7086"];
        optionsTextColor = ["#89b4fa"];
        selectedLineBgColor = ["#313244"];
        cherryPickedCommitFgColor = ["#89b4fa"];
      };
    };
  };
}
