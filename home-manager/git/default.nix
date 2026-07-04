_: {
  # programs.git.delta was renamed to the top-level programs.delta.
  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      navigate = true;
      line-numbers = true;
      # Bundled theme name (delta --list-syntax-themes), matches the
      # catppuccin-mocha look used elsewhere in the terminal stack.
      syntax-theme = "Catppuccin Mocha";
    };
  };

  programs.git = {
    enable = true;
    lfs.enable = true;

    settings = {
      user = {
        name = "Josh Symonds";
        email = "josh@joshsymonds.com";
      };
      commit.gpgsign = true;
      tag.gpgsign = true;

      alias = {
        co = "checkout";
        st = "status";
        a = "add --all";
        pl = "pull -u";
        pu = "push --all origin";
      };

      core = {
        editor = "hx";
        whitespace = "fix,-indent-with-non-tab,trailing-space,cr-at-eol";
      };
      url."ssh://git@github.com/".insteadOf = "https://github.com/";
      url."ssh://git@gitlab.com/".insteadOf = "https://gitlab.com/";
      pull = {rebase = true;};
      web = {browser = "firefox";};
      rerere = {
        enabled = 1;
        autoupdate = 1;
      };
      push = {default = "simple";};
    };
  };
}
