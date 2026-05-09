#!@bash@/bin/bash
set -e

VERB="$1"
shift

PROTON="@proton@"
GAMESCOPE="@gamescope@"

# Only intercept the launch verb. Steam invokes the compat tool many
# times for install / wineprefix-create / iscriptevaluator / etc — wrapping
# those in gamescope hangs Steam during prefix setup. PROTON_GAMESCOPE_DISABLE=1
# in a game's launch options is the per-game escape hatch.
if [[ "$VERB" == "waitforexitandrun" ]] && [[ "${PROTON_GAMESCOPE_DISABLE:-0}" != "1" ]]; then
  exec "$GAMESCOPE" \
    -f \
    -w 2560 -h 1440 \
    -W 2560 -H 1440 \
    --force-grab-cursor \
    --backend sdl \
    -- "$PROTON" "$VERB" "$@"
else
  exec "$PROTON" "$VERB" "$@"
fi
