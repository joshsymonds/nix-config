{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  tmuxDevspaceHelper =
    pkgs.writeShellScriptBin "tmux-devspace" (builtins.readFile ./tmux/scripts/tmux-devspace.sh);
in {
  imports = [
    ./atuin
    ./claude-code
    ./codex
    ./mcp
    ./helix
    ./kitty
    ./tmux
    ./git
    ./gpg
    ./k9s
    ./ssh-agent
    ./zsh
    ./starship
    ./statusline-aliases
  ];

  config = {
    home = {
      enableNixpkgsReleaseCheck = false;
      username = "joshsymonds";

      sessionVariables = {
        COLORTERM = lib.mkDefault "truecolor";
        NH_FLAKE = "${config.home.homeDirectory}/nix-config";
      };

      packages = with pkgs; (
        [
          autossh
          bat
          claudeCodeCli
          codexCli
          coder
          coreutils-full
          curl
          devenv
          docker
          eza
          fzf
          gh
          git
          gptfdisk
          inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.agenix
          inputs.cc-tools.packages.${pkgs.stdenv.hostPlatform.system}.default
          inputs.googleworkspace-cli.packages.${pkgs.stdenv.hostPlatform.system}.default
          istioctl
          jq
          just
          k9s
          killall
          kitty.terminfo
          tmux
          tmux.terminfo
          kubectl
          kubernetes-helm
          kustomize
          manix
          moar
          ncdu
          nh
          nix-output-monitor
          nvd
          parallel
        ]
        ++ lib.optionals (!stdenv.isDarwin) [parted visidata]
        ++ [
          yazi
          ripgrep
          shellcheck
          shellspec
          socat
          talosctl
          typst
          vivid # For LS_COLORS generation
          wget
          wireguard-tools
          xdg-utils
          yq
          tmuxDevspaceHelper
        ]
      );
    };

    programs = {
      rbenv = {
        enable = true;
        enableBashIntegration = true;
        # Disabled: zsh uses lazy-load stubs that defer rbenv init until first
        # ruby/rbenv/gem/bundle command. See home-manager/zsh/default.nix.
        enableZshIntegration = false;
        plugins = [
          {
            name = "ruby-build";
            src = pkgs.fetchFromGitHub {
              owner = "rbenv";
              repo = "ruby-build";
              rev = "v20251008";
              hash = "sha256-FZRp7O4YjDV+EOvwuaqWaQ6LfzL9vENBaIPot5G89Z0=";
            };
          }
        ];
      };

      direnv = {
        enable = true;
        nix-direnv.enable = true;
        # Disabled: hook script is pre-rendered at build time and sourced from
        # home-manager/zsh/default.nix. See preRender helper there.
        enableZshIntegration = false;
      };

      htop = {
        enable = true;
        package = pkgs.htop;
        settings.show_program_path = true;
      };
    };

    # Agenix identity for home-manager secret decryption
    age.identityPaths = ["${config.home.homeDirectory}/.config/agenix/keys.txt"];

    # Auto-derive agenix age key from SSH key so `agenix -e` works on all machines
    home.activation.deriveAgenixKey = lib.hm.dag.entryAfter ["writeBoundary"] ''
      key_dir="$HOME/.config/agenix"
      key_file="$key_dir/keys.txt"

      # Find the first usable ed25519 SSH key
      ssh_key=""
      for candidate in "$HOME/.ssh/github" "$HOME/.ssh/id_ed25519"; do
        if [ -f "$candidate" ]; then
          ssh_key="$candidate"
          break
        fi
      done

      if [ -z "$ssh_key" ]; then
        run echo "agenix: no ed25519 SSH key found, skipping age key derivation"
      else
        run mkdir -p "$key_dir"
        run ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i "$ssh_key" -o "$key_file"
        run chmod 600 "$key_file"
      fi
    '';

    # Disable HM manpages to avoid Determinate Nix options.json context warning
    # https://github.com/nix-community/home-manager/issues/7935
    manual.manpages.enable = false;

    xdg.enable = true;

    home.stateVersion = "25.05";
  };
}
