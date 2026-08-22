# shrike (Pixel 11, Nix-on-Droid) — the fleet terminal environment, phone
# sized. Composed from individual modules rather than common.nix: that
# layer is the server/desktop kit (docker, k8s, codex, agenix key
# derivation) and none of it belongs in an app sandbox. Helix is enabled
# lean (no LSP suite — ../helix drags terraform + typescript + gopls,
# which is dev-machine weight, not quick-config-edit weight).
#
# CONSTRAINT: the phone has no GitHub credentials, so nothing imported
# here (or in hosts/shrike) may dereference a private flake input
# (shimmer, scriptorium, savecraft*, patchbay) — flake fetches are lazy,
# and shrike's graph currently forces only nixpkgs, nix-on-droid, and
# home-manager. Breaking this fails the phone's `update` with a fetch
# error.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  # `t` in the zsh module shells out to tmux-devspace; on other hosts
  # common.nix provides it. Same definition here.
  tmuxDevspaceHelper =
    pkgs.writeShellScriptBin "tmux-devspace" (builtins.readFile ../tmux/scripts/tmux-devspace.sh);
in {
  imports = [
    ../atuin
    ../git
    ../lazygit
    ../ssh-config
    ../starship
    ../tmux
    ../zsh
  ];

  home = {
    stateVersion = "25.05";

    # No coreutils-full here: nix-on-droid's base environment already ships
    # coreutils, and its merged path buildEnv rejects the bin/ collision.
    packages = with pkgs; [
      bat
      curl
      eza
      fd
      fzf
      htop
      jq
      moor
      ncdu
      openssh
      ripgrep
      tmuxDevspaceHelper
      vivid
      wget
      # Starship's right-side chips (host alias, clouds block with the
      # closing curve) shell out to cc-tools; without it the powerline
      # renders unfinished. Public repo, aarch64-linux is built.
      inputs.cc-tools.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];

    sessionVariables = {
      EDITOR = "hx";
      COLORTERM = "truecolor";
      # Android's kernel hostname is "localhost" and nix-on-droid can't
      # set it. Everything that derives identity from the hostname —
      # starship's host chip ($HOSTNAME) and the zsh module's DEV_CONTEXT
      # fallback — gets told directly instead.
      HOSTNAME = "shrike";
      DEV_CONTEXT = "shrike";
    };
  };

  programs.helix.enable = true;

  # The phone is credential-less by design (public repo, pull-only): the
  # git module's global https→ssh insteadOf rewrite would force every
  # GitHub pull through an ssh key that deliberately doesn't exist, and
  # gpg signing has no key here either.
  programs.git.settings = {
    url = lib.mkForce {};
    commit.gpgsign = lib.mkForce false;
    tag.gpgsign = lib.mkForce false;
  };

  # Inbound ssh: same fleet keys as every NixOS host authorizes
  # (hosts/common.nix imports the same list). nix-on-droid has no NixOS
  # user machinery, so the file is written directly.
  home.file.".ssh/authorized_keys".text =
    lib.concatMapStrings (key: key + "\n") (import ../../lib/ssh-keys.nix);

  # Arm sshd on the first shell after the app starts — there's no systemd
  # and no boot hook on Android, so "open the app once" is the ritual that
  # brings shrike reachable after a reboot. Idempotent and quiet.
  programs.zsh.initContent = lib.mkAfter ''
    command -v sshd-start >/dev/null 2>&1 && sshd-start --quiet || true
  '';

  # No systemd on Android. The tmux and atuin modules declare user units
  # that could never run here; the zsh module's no-systemd fallback starts
  # the atuin daemon, and tmux sessions are created on attach (`-A`).
  systemd.user.services = lib.mkForce {};
  systemd.user.timers = lib.mkForce {};

  # https://github.com/nix-community/home-manager/issues/7935
  manual.manpages.enable = false;
}
