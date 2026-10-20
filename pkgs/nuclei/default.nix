{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "nuclei";
  version = "3.11.1";

  src = fetchFromGitHub {
    owner = "projectdiscovery";
    repo = pname;
    rev = "v${version}";
    hash = "sha256-iXeMYiri3gwfjXnWgSgGOtcXFqZynSzGXnVIM6hOH5Y=";
  };

  vendorHash = "sha256-pqjbEuQXGv0KuQwAFrjLg0WfolfiJ4qCzhPLJT53Us0=";

  subPackages = [
    "cmd/nuclei"
  ];

  # cmd/nuclei's tests write the templates config under $HOME/.config/nuclei.
  preCheck = "export HOME=$TMPDIR";

  ldflags = [
    "-s"
    "-w"
    "-X github.com/projectdiscovery/nuclei/v3/pkg/types.VERSION=${version}"
  ];

  meta = with lib; {
    description = "Fast and customizable vulnerability scanner based on simple YAML based DSL";
    homepage = "https://nuclei.projectdiscovery.io/";
    license = licenses.mit;
    maintainers = with maintainers; [];
    mainProgram = "nuclei";
  };
}
