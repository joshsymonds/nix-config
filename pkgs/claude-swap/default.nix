{
  lib,
  stdenv,
  python3Packages,
  fetchFromGitHub,
  procps,
}:
python3Packages.buildPythonApplication rec {
  pname = "claude-swap";
  version = "0.27.2";

  src = fetchFromGitHub {
    owner = "realiti4";
    repo = "claude-swap";
    rev = "v${version}";
    hash = "sha256-bOoK2yqk4Uk8xnm21EaJEWBLx9kf5HoeFVe5rbj4WZ4=";
  };

  pyproject = true;

  build-system = [python3Packages.hatchling];

  # keyring is declared upstream with a sys_platform == 'win32' marker only.
  dependencies = with python3Packages; [
    textual
    truststore
  ];

  # process_detection shells out to `ps -o lstart=` to match the procStart
  # stamp claude writes into its session record. macOS always has /bin/ps;
  # on Linux it has to come from procps, at runtime and in the check sandbox.
  makeWrapperArgs = lib.optionals stdenv.hostPlatform.isLinux [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [procps])
  ];

  # Upstream's pytest addopts default to `-n auto --dist loadgroup`.
  nativeCheckInputs =
    (with python3Packages; [
      pytestCheckHook
      pytest-asyncio
      pytest-xdist
    ])
    ++ lib.optionals stdenv.hostPlatform.isLinux [procps];

  # tests/conftest.py installs an audit hook that refuses writes under the
  # "real" account store, resolved with $HOME cleared (falls back to the
  # passwd home, which for nixbld is $NIX_BUILD_TOP). That root's basename
  # then becomes a substring hint that matches every path in the sandbox and
  # pytest's basetemp is a direct child of it. The hook excludes Path.home()
  # itself, so pointing $HOME at the same directory unblocks the run.
  preCheck = "export HOME=$NIX_BUILD_TOP";

  meta = with lib; {
    description = "Multi-account switcher for Claude Code with usage dashboard and rate-limit rotation";
    homepage = "https://github.com/realiti4/claude-swap";
    license = licenses.mit;
    mainProgram = "cswap";
  };
}
