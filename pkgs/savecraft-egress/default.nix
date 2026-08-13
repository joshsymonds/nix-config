{
  lib,
  buildGoModule,
  src,
}:
buildGoModule {
  pname = "savecraft-egress";
  version = "0-unstable-2026-08-13";

  inherit src;

  vendorHash = null;

  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "Restricted rescue egress proxy for OpenRouter requests";
    homepage = "https://github.com/joshsymonds/savecraft-egress";
    license = lib.licenses.mit;
    mainProgram = "savecraft-egress";
  };
}
