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

  chromeHexrain = import ../../modules/desktop/chrome-hexrain {inherit lib;};

  # stdin → Android clipboard via OSC 52, which the Termux-family
  # terminal implements (no Termux:API needed). Inside tmux the escape
  # rides a passthrough DCS. `cat file | clip`.
  clip = pkgs.writeShellScriptBin "clip" ''
    data=$(${pkgs.coreutils}/bin/base64 -w0)
    if [ -n "''${TMUX:-}" ]; then
      printf '\033Ptmux;\033\033]52;c;%s\007\033\\' "$data"
    else
      printf '\033]52;c;%s\007' "$data"
    fi
  '';
in {
  imports = [
    ../atuin
    ../devspaces-client
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
      # gnugrep/gnused: the sandbox base PATH lacks even grep and sed
      # (non-interactive ssh one-liners break without them).
      gnugrep
      gnused
      ripgrep
      tmuxDevspaceHelper
      vivid
      wget
      # zsh's shared init sources `zoxide init` output, whose chpwd hook
      # calls the bare binary — without it every cd errors.
      zoxide
      clip
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

  # No GPG key on the phone; the ssh identity (registered with GitHub)
  # handles auth, but signing would fail.
  programs.git.settings = {
    commit.gpgsign = lib.mkForce false;
    tag.gpgsign = lib.mkForce false;
  };

  # ControlMaster multiplexing dies under proot ("Failed to connect to
  # new control master"); plain connections work.
  programs.ssh.settings."*".ControlMaster = lib.mkForce "no";

  # chrome_hexrain (gnomon's shader wallpaper), assembled for the Shader
  # Editor app from the same body + uniform values halmasuit renders —
  # regenerates on every `update`. Getting it INTO Shader Editor is the
  # one manual hop (its shader storage is app-internal): open this file,
  # copy, paste into a new shader there. See hosts/shrike/README.md.
  home.file."wallpaper/chrome-hexrain-shadereditor.glsl".source =
    chromeHexrain.androidSource pkgs;

  # Inbound ssh: same fleet keys as every NixOS host authorizes
  # (hosts/common.nix imports the same list). nix-on-droid has no NixOS
  # user machinery, so the file is written directly.
  home.file.".ssh/authorized_keys".text =
    lib.concatMapStrings (key: key + "\n") (import ../../lib/ssh-keys.nix);

  # Inbound ssh is DEBUG-ONLY, started by hand (`sshd-start`) when wanted.
  # No auto-arm: a daemon spawned from a session chains that session's
  # proot supervisor open forever (ptrace — see the pixel11 saga), which
  # is what made Ctrl-D "brick" sessions. The phone's job is outbound:
  # `earth` and friends into vermissian.
  #
  # Same reasoning for atuin: no resident daemon on the phone. Classic
  # sqlite mode syncs per-command and leaves sessions free to die.
  programs.atuin.daemon.enable = lib.mkForce false;

  # No systemd on Android. The tmux and atuin modules declare user units
  # that could never run here; the zsh module's no-systemd fallback starts
  # the atuin daemon, and tmux sessions are created on attach (`-A`).
  systemd.user.services = lib.mkForce {};
  systemd.user.timers = lib.mkForce {};

  # https://github.com/nix-community/home-manager/issues/7935
  manual.manpages.enable = false;
}
