{
  lib,
  python3Packages,
}:
# Tiny stdlib-only poller that fetches the next week of events from
# Morgen's REST API and writes them as ICS files into a vdir directory
# that khal (and the DMS calendar bar widget by extension) reads. See
# pkgs/morgen-fetch/morgen_fetch.py for the rationale and protocol notes.
#
# Built as a real Python application (not a writeShellScriptBin) so the
# pure functions in morgen_fetch.py — escape_text, to_utc_stamp,
# render_event — can be unit-tested via pytestCheckHook at build time.
# Tests live in pkgs/morgen-fetch/tests/.
python3Packages.buildPythonApplication {
  pname = "morgen-fetch";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [python3Packages.setuptools];

  nativeCheckInputs = [
    python3Packages.pytestCheckHook
  ];

  pythonImportsCheck = ["morgen_fetch"];

  meta = with lib; {
    description = "Poll Morgen's REST API and write events to a khal vdir";
    homepage = "https://github.com/joshsymonds/nix-config";
    mainProgram = "morgen-fetch";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
