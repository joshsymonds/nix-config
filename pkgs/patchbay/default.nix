{
  lib,
  buildGoModule,
  src,
}:
buildGoModule {
  pname = "patchbay";
  version = "0.0.0-dev";

  inherit src;

  # Covers every vendored Go dependency used by the pinned Patchbay source.
  vendorHash = "sha256-i1vtcGhyt0W1a18wvtelEZuvduDm3PzR8NjUZwsv5eE=";

  subPackages = [
    "cmd/patchbay"
  ];

  ldflags = [
    "-s"
    "-w"
  ];

  # Patchbay's full gate is `just check`. Its path-security tests intentionally
  # reject Nix's foreign-owned sandbox root, so this derivation builds only the
  # deployment artifact, matching Patchbay's canonical flake package.
  doCheck = false;

  env.CGO_ENABLED = 0;

  meta = {
    description = "Per-host Anthropic Messages API gateway routing Claude Code to per-project models";
    homepage = "https://github.com/joshsymonds/patchbay";
    # No LICENSE file in the repo: all rights reserved (private).
    license = lib.licenses.unfree;
    mainProgram = "patchbay";
  };
}
