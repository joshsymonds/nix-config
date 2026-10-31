{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule {
  pname = "starlark-lsp";
  version = "0.0.0-20240730211532";

  src = fetchFromGitHub {
    owner = "tilt-dev";
    repo = "starlark-lsp";
    rev = "5689e7e8a3aa8ab55eca07d215054a0f25dbc17c";
    hash = "sha256-zsrUuU5aBjDaXONwETwxHPeiAOvM89xqj8whlqd6t9U=";
  };

  vendorHash = "sha256-PqMed2czM5BxnQs9O641W9MlrVZe0Uv+bII1KK4h974=";

  # Build the specific binary we want
  subPackages = ["cmd/starlark-lsp"];

  ldflags = ["-s" "-w"];

  meta = with lib; {
    description = "Starlark Language Server Protocol implementation";
    homepage = "https://github.com/tilt-dev/starlark-lsp";
    license = licenses.asl20;
    maintainers = [];
  };
}
