# Custom packages, that can be defined similarly to ones from nixpkgs
# You can build them using 'nix build .#example' or (legacy) 'nix-build -A example'
{
  pkgs ? (import ../nixpkgs.nix) {},
  # Flake inputs, threaded through by flake.nix's `packages` output. Optional
  # (defaults to {}) so the legacy `nix-build -A example` path above still
  # evaluates without a flake context — it just won't get redlib-veraticus,
  # which needs inputs.{crane,redlib-fork,rust-overlay}.
  inputs ? {},
  ...
}: let
  # redlib-veraticus needs flake inputs that aren't there when this file is
  # evaluated without `inputs` (see above) — gate on their presence instead
  # of requiring them.
  redlibPackages =
    pkgs.lib.optionalAttrs
    (inputs ? crane && inputs ? redlib-fork && inputs ? rust-overlay)
    {
      redlib-veraticus = pkgs.callPackage ./redlib-veraticus {
        inherit (inputs) crane;
        redlibSrc = inputs.redlib-fork.sourceInfo.outPath;
        redlibRev = inputs.redlib-fork.sourceInfo.rev;
        rustOverlay = inputs.rust-overlay;
      };
    };

  darwinOnly =
    if pkgs.stdenv.hostPlatform.isDarwin
    then {
      aerospace = pkgs.callPackage ./aerospace {};
    }
    else {};

  # Linux-only: Claude Desktop is built from Anthropic's .deb (buildFHSEnv +
  # dpkg), neither of which evaluates on darwin. Gated so `nix flake check`
  # on ninuan (aarch64-darwin) doesn't force it.
  linuxOnly =
    if pkgs.stdenv.hostPlatform.isLinux
    then let
      claude-desktop-unwrapped = pkgs.callPackage ./claude-desktop {};
    in {
      inherit claude-desktop-unwrapped;
      claude-desktop = pkgs.callPackage ./claude-desktop/fhs.nix {inherit claude-desktop-unwrapped;};
    }
    else {};
in
  import ./simple.nix {inherit pkgs;}
  // darwinOnly
  // linuxOnly
  // redlibPackages
