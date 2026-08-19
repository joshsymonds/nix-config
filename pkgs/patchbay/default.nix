{
  lib,
  buildGoModule,
  src,
}:
buildGoModule {
  pname = "patchbay";
  version = "0.0.0-dev";

  inherit src;

  # Stdlib-only (go.mod has no require block), so there are no vendored deps.
  vendorHash = null;

  subPackages = [
    "cmd/patchbay"
  ];

  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "Per-host Anthropic Messages API gateway routing Claude Code to per-project models";
    homepage = "https://github.com/joshsymonds/patchbay";
    # No LICENSE file in the repo: all rights reserved (private).
    license = lib.licenses.unfree;
    mainProgram = "patchbay";
  };
}
