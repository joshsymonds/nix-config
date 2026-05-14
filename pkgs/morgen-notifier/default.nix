{
  lib,
  libnotify,
  makeWrapper,
  python3Packages,
}:
# Companion to morgen-fetch: reads the upcoming-events.json that
# morgen-fetch writes and fires notify-send at T-10 and T-2 for each
# meeting, deduplicating via ~/.cache/morgen-notifier/fired.json so each
# event triggers each threshold exactly once. See morgen_notifier.py for
# the rationale (and the explanation for why URLs go in the notification
# body instead of as a notify-send --action).
#
# Pure functions get unit-tested at build time via pytestCheckHook;
# threshold detection, dedup, and state pruning are all covered. The
# I/O layer (file reads, notify-send subprocess) is intentionally not
# mocked — failures there are visible immediately in journalctl when
# the systemd unit runs.
python3Packages.buildPythonApplication {
  pname = "morgen-notifier";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [python3Packages.setuptools];

  # `notify-send` (from libnotify) is the only external command this
  # tool shells out to. Inject libnotify on the wrapper's PATH so the
  # systemd unit doesn't depend on it being globally installed — the
  # package is self-sufficient regardless of where it ends up running.
  nativeBuildInputs = [makeWrapper];

  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [libnotify])
  ];

  nativeCheckInputs = [
    python3Packages.pytestCheckHook
  ];

  pythonImportsCheck = ["morgen_notifier"];

  meta = with lib; {
    description = "Fire notify-send at T-10 and T-2 for upcoming Morgen meetings";
    homepage = "https://github.com/joshsymonds/nix-config";
    mainProgram = "morgen-notifier";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
