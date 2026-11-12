# The notification tick for the orrery desk popup path (see
# home-manager/orrery/desk.nix): one light tap, played for every coding-agent
# popup except a quiet one. Synthesised at build time by tick.py with Python's
# standard library, so there is no fetched asset and nothing to license. The
# numbers in tick.py ARE the design: it was auditioned against other candidates
# and chosen by ear, so don't "round" them.
{
  lib,
  runCommand,
  python3,
}:
runCommand "claude-notify-sounds" {
  nativeBuildInputs = [python3];
  meta = {
    description = "Synthesized notification tick for the orrery desk popup path";
    license = lib.licenses.cc0;
    platforms = lib.platforms.all;
  };
} ''
  mkdir -p "$out"
  python3 ${./tick.py} "$out/tick.wav"
''
