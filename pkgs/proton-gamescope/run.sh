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
# Don't add `--backend sdl`: the niri wiki recommends it, but inside
# the sniper on NVIDIA it breaks the host surface registration entirely
# (gamescope's window never appears in niri).
#
# Per-game env vars (set as `VAR=1 %command%` in Steam launch options):
#   PROTON_GAMESCOPE_DISABLE=1     — bypass gamescope entirely, run
#     bare GE-Proton. For EAC titles (gamescope#1794), Steam-overlay-
#     dependent games, etc.
#   PROTON_GAMESCOPE_FORCE_GRAB=1  — force pointer lock via
#     wp-pointer-constraints regardless of the game's own request. For
#     FPS games where game-side lock handling is buggy on niri and
#     the cursor escapes to another monitor mid-mouselook (niri#2672).
#     Default off — most games work better letting niri honor the
#     game's own lock requests, and forcing lock on mouse-driven games
#     (ARPGs, strategy, RPGs) traps the cursor unnecessarily.
if [[ "$VERB" == "waitforexitandrun" ]] && [[ "${PROTON_GAMESCOPE_DISABLE:-0}" != "1" ]]; then
  GAMESCOPE_ARGS=(-W 2560 -H 1440 -f)

  if [[ "${PROTON_GAMESCOPE_FORCE_GRAB:-0}" == "1" ]]; then
    GAMESCOPE_ARGS+=(--force-grab-cursor)
  fi

  exec "$GAMESCOPE" "${GAMESCOPE_ARGS[@]}" -- "$PROTON" "$VERB" "$@"
else
  exec "$PROTON" "$VERB" "$@"
fi
