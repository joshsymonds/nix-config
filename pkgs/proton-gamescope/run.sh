#!@bash@/bin/bash
set -e

VERB="$1"
shift

PROTON="@proton@"
GAMESCOPE="@gamescope@"

# ── proton defaults ──────────────────────────────────────────────────────
#
# Native Wayland + NVAPI exposure is the right default on niri + NVIDIA
# Blackwell. Wayland mode (PROTON_USE_WAYLAND=1) makes proton swap Wine's
# winex11.drv for winewayland.drv, which talks Wayland straight to niri
# (or whatever host compositor) — no Xwayland in the path, no 1×1 X11
# placeholder window, no DXGI-exclusive-fullscreen-vs-X11-window-size
# fight, no nested-compositor handshake races. Empirically this is the
# only path that reliably renders in PRAGMATA / RE Engine 4 titles on
# our stack.
#
# NVAPI exposure is needed for DLSS / DLSS-RR / RT/PT menu items in RE
# Engine titles (PRAGMATA, RE4R, MH Wilds, DD2). Default proton hides
# the NVIDIA GPU from NVAPI probes to dodge driver-version checks that
# misbehave on old titles; proton-cachyos handles those checks fine.
# Some RE Engine titles further gate RT/PT/DLSS-RR behind a game-side
# Wine detection check — pass `/WineDetectionEnabled:False` in the
# game's Steam launch options to disable it (PRAGMATA confirmed).
#
# `${VAR:-default}` form: per-game launch options can flip any of these
# off when needed (e.g. `PROTON_USE_WAYLAND=0 %command%` for a title
# whose winewayland.drv path breaks).
export PROTON_USE_WAYLAND="${PROTON_USE_WAYLAND:-1}"
export PROTON_ENABLE_NVAPI="${PROTON_ENABLE_NVAPI:-1}"
export PROTON_HIDE_NVIDIA_GPU="${PROTON_HIDE_NVIDIA_GPU:-0}"

# ── gamescope (opt-in) ───────────────────────────────────────────────────
#
# Gamescope is opt-in via `PROTON_GAMESCOPE_ENABLE=1 %command%` in the
# game's Steam launch options. Most games on niri + NVIDIA + native
# wayland mode (above) don't need gamescope's nested compositor at all
# — niri handles xdg_toplevel.set_fullscreen cleanly, NVIDIA's wayland
# WSI is direct to the host, and there's no host-fullscreen fight
# motivating gamescope wrapping. Reach for it when:
#
#   - You need FSR/NIS upscaling (`-w/-h` smaller than `-W/-H`).
#   - You need HDR pipeline gamescope provides (color space conversion).
#   - You're running a game whose Wine wayland driver doesn't work and
#     X11 mode needs gamescope's win_is_useless / paint_window_commit
#     patches we ship to handle the 1×1 placeholder pattern.
#   - Frame-rate-limiting / pacing via gamescope's --rt + mangoapp HUD.
#
# Per-game env vars (set as `VAR=1 %command%` in Steam launch options):
#   PROTON_GAMESCOPE_ENABLE=1      — wrap proton in gamescope.
#   PROTON_GAMESCOPE_FORCE_GRAB=1  — force pointer lock via
#     wp-pointer-constraints regardless of the game's own request. For
#     FPS games where game-side lock handling is buggy on niri and the
#     cursor escapes to another monitor mid-mouselook (niri#2672).
#     Default off — most games work better letting niri honor the
#     game's own lock requests, and forcing lock on mouse-driven games
#     (ARPGs, strategy, RPGs) traps the cursor unnecessarily.
if [[ "$VERB" == "waitforexitandrun" ]] && [[ "${PROTON_GAMESCOPE_ENABLE:-0}" == "1" ]]; then
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

  GAMESCOPE_ARGS=(-W 2560 -H 1440 -f)

  if [[ "${PROTON_GAMESCOPE_FORCE_GRAB:-0}" == "1" ]]; then
    GAMESCOPE_ARGS+=(--force-grab-cursor)
  fi

  # Shim between gamescope and proton: alias GAMESCOPE_WAYLAND_DISPLAY back
  # to WAYLAND_DISPLAY before exec'ing proton.
  #
  # Gamescope intentionally strips WAYLAND_DISPLAY from its children's env
  # and exposes its own nested socket as GAMESCOPE_WAYLAND_DISPLAY. The
  # rename prevents accidental fall-through where a child process inside
  # the nested compositor connects to the HOST compositor (niri's
  # wayland-1 in our case) instead of gamescope-0, which would bypass the
  # gamescope WSI layer and break frame pacing / present feedback.
  #
  # But proton's wayland-mode activation in the proton script
  # (`if "wayland" in self.compat_config and "WAYLAND_DISPLAY" in self.env`)
  # requires the standard WAYLAND_DISPLAY to be set. With PROTON_USE_-
  # WAYLAND=1 launched under gamescope, the compat config flag IS set but
  # WAYLAND_DISPLAY is not, so the dlloverride that swaps winex11.drv for
  # winewayland.drv silently no-ops and Wine stays on Xwayland. Caveat:
  # winewayland.drv requires wl_subcompositor, which gamescope doesn't
  # expose, so even with this shim the game falls back to the X11 path
  # under gamescope. Kept here for forward-compat (when gamescope grows
  # subcompositor support).
  exec "$GAMESCOPE" "${GAMESCOPE_ARGS[@]}" -- bash -c \
    'export WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-$WAYLAND_DISPLAY}"; exec "$@"' \
    proton-gamescope-shim "$PROTON" "$VERB" "$@"
else
  exec "$PROTON" "$VERB" "$@"
fi
