#!@bash@/bin/bash
set -e

VERB="$1"
shift

PROTON="@proton@"
GAMESCOPE="@gamescope@"

# Steam wraps every compat tool launch in the Steam Linux Runtime
# sniper container, regardless of what our toolmanifest declares. That
# means gamescope runs inside pressure-vessel — same architecture as
# putting `gamescope ... -- %command%` in a per-game launch option,
# which is the proven-working baseline.
#
# Flag notes:
#   -W/-H        — output (host surface) resolution; matches monitor
#   -f           — fullscreen the host surface
#   --force-grab-cursor — pointer lock via wp-pointer-constraints, so the
#                  cursor stays inside the game on multi-monitor (niri#2672).
#                  Independent of backend; works with the auto-selected
#                  Wayland backend.
#
# Don't add `--backend sdl`: the niri wiki recommends it, but inside
# the sniper on NVIDIA it breaks the host surface registration entirely
# (gamescope's window never appears in niri).
if [[ "$VERB" == "waitforexitandrun" ]] && [[ "${PROTON_GAMESCOPE_DISABLE:-0}" != "1" ]]; then
  exec "$GAMESCOPE" \
    -W 2560 -H 1440 \
    -f \
    --force-grab-cursor \
    -- "$PROTON" "$VERB" "$@"
else
  exec "$PROTON" "$VERB" "$@"
fi
