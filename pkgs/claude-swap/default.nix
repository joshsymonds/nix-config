{
  lib,
  python3Packages,
  fetchFromGitHub,
}:
python3Packages.buildPythonApplication rec {
  pname = "claude-swap";
  version = "0.18.1";

  src = fetchFromGitHub {
    owner = "realiti4";
    repo = "claude-swap";
    rev = "v${version}";
    hash = "sha256-47iEyj4DEU0WkBJsFb6kgatKeSjkkEF7Qha8OsNbS0s=";
  };

  pyproject = true;

  build-system = [python3Packages.hatchling];

  dependencies = with python3Packages; [
    keyring
    textual
    truststore
  ];

  # Upstream pins textual>=8.2.8; nixpkgs ships 8.2.7 (one patch behind).
  pythonRelaxDeps = ["textual"];

  nativeCheckInputs = with python3Packages; [
    pytestCheckHook
    pytest-asyncio
  ];

  meta = with lib; {
    description = "Multi-account switcher for Claude Code with usage dashboard and rate-limit rotation";
    homepage = "https://github.com/realiti4/claude-swap";
    license = licenses.mit;
    mainProgram = "cswap";
  };
}
