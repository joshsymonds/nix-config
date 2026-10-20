{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "deadcode";
  version = "0.52.0";

  src = fetchFromGitHub {
    owner = "golang";
    repo = "tools";
    rev = "v${version}";
    hash = "sha256-invRApL81q9uIUCbBUhWGyS+14OKK6HZYdONzhHGKP4=";
  };

  subPackages = ["cmd/deadcode"];

  vendorHash = "sha256-+1/eKOwN4yUvLCgGRJbW6MTleIEodfcIoEHCBRHd2MQ=";

  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "Reports unused declarations in Go packages";
    homepage = "https://pkg.go.dev/golang.org/x/tools/cmd/deadcode";
    license = lib.licenses.bsd3;
    maintainers = with lib.maintainers; [];
    mainProgram = "deadcode";
  };
}
