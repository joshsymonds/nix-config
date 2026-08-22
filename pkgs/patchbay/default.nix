{
  lib,
  buildGoModule,
  src,
}:
buildGoModule {
  pname = "patchbay";
  version = "0.0.0-dev";

  inherit src;

  # The usage SQLite database uses modernc.org/sqlite and its transitive Go modules.
  vendorHash = "sha256-BAvfNq8jRMtxnNRnCfD4m3N9Yqc7o9dM/v6eVfK0Iag=";

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
