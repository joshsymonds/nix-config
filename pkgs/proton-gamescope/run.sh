#!@bash@/bin/bash
set -e

VERB="$1"
shift

PROTON="@proton@"
GAMESCOPE="@gamescope@"

# Expose NVAPI / DXGI NVIDIA adapter info to every Proton game. RE Engine
# titles (PRAGMATA, RE4R, MH Wilds, DD2) gray out RT/PT/DLSS-RR toggles
# when Proton hides the NVIDIA GPU from NVAPI probes. Default Proton
# hides the GPU to dodge driver-version checks that misbehave on old
# titles; proton-cachyos handles those checks fine.
#
# `${VAR:-default}` form: per-game launch options can still flip these
# off for the rare title that breaks with NVAPI exposed
# (`PROTON_ENABLE_NVAPI=0 %command%`).
export PROTON_ENABLE_NVAPI="${PROTON_ENABLE_NVAPI:-1}"
export PROTON_HIDE_NVIDIA_GPU="${PROTON_HIDE_NVIDIA_GPU:-0}"

# Work around gamescope's xwm dedup bug on NVIDIA proprietary. vkd3d-proton
# (and DXVK) use VK_KHR_present_wait / VK_KHR_present_id for presentation
# pacing; NVIDIA's driver implementation is broken (570/595 stable branches)
# — it never returns the present-feedback events gamescope's WSI layer
# expects, so gamescope-xwm sees every commit as identical and drops it via
# the `existing_commit->buf == buf && feedback == nullptr` dedup at
# steamcompmgr.cpp:7118. Result: permanent black frames in nested gamescope.
# Tracking: ValveSoftware/gamescope#1592, #1384, #2006; YaLTeR/niri#1798.
# Partial fix landed in NVIDIA Vulkan beta 570.123.06 but is not yet in stable.
#
# Two-layer fix:
#  1. GAMESCOPE_WSI_HIDE_PRESENT_WAIT_EXT — gamescope's WSI Vulkan layer
#     hides the extension from clients entirely. Catches DXVK + vkd3d both.
#  2. VKD3D_DISABLE_EXTENSIONS — vkd3d-proton-side belt-and-suspenders.
#     Append-friendly: if a game already needs other disables, ours prepend.
#
# Either alone is probably enough; both together costs nothing extra and
# survives the case where the gamescope WSI layer isn't injected for some
# reason. RT / DLSS / DLSS-RR / Reflex are unaffected — present_wait is
# purely a frame-pacing extension.
export GAMESCOPE_WSI_HIDE_PRESENT_WAIT_EXT="${GAMESCOPE_WSI_HIDE_PRESENT_WAIT_EXT:-1}"
export VKD3D_DISABLE_EXTENSIONS="VK_KHR_present_id,VK_KHR_present_wait,VK_KHR_present_id2,VK_KHR_present_wait2,VK_EXT_present_timing${VKD3D_DISABLE_EXTENSIONS:+,$VKD3D_DISABLE_EXTENSIONS}"

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
#     bare Proton CachyOS. For EAC titles (gamescope#1794),
#     Steam-overlay-dependent games, etc.
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
