---
name: debugging-linux-games
description: Use when a Steam, Proton, Wine, Lutris, or Heroic game misbehaves on Linux — crashes at launch, black screen, missing DLSS / Ray Tracing / Path Tracing / DLSS-RR / Frame Generation, anti-cheat failures, shader stutter, controller or HDR or Wayland-fullscreen problems, intro-video failures ("Failed to create SourceReader", MF_E_UNEXPECTED), NVAPI "Unknown function ID" log spam, gamescope dedup black-screens, vkd3d swapchain crashes. Especially before patching or forking DXVK, vkd3d-proton, dxvk-nvapi, gamescope, Wine, or Proton; before reading RE Engine, Unreal, Unity, Source 2, id Tech, or Decima logs; or when a game is mentioned with NVIDIA Blackwell, NixOS, niri, gamescope, proton-cachyos, GE-Proton, or proton-tkg. Triggers on phrases like "won't launch", "RT/PT grayed out", "Proton fix for", "/WineDetectionEnabled", "ProtonDB", "VKD3D_CONFIG", "PROTON_USE_WAYLAND", or any moment the impulse is "let me read the Proton/Wine/vkd3d source" before checking community fixes.
---

# Debugging Linux Games (Research-First)

## Overview

Steam-on-Linux problems almost always have a documented community fix. The
documented fix is usually a game launch option, an env var, a config tweak,
or a known proton-ge / proton-cachyos release with a workaround baked in —
NOT a patch to dxvk-nvapi or vkd3d-proton. Diving into shim code without
checking first is how 10 hours get spent producing patches that the actual
fix renders unnecessary.

**Core principle:** Community research first. Code second. Always.

**Iron Law:** NO patches, forks, overlays, postFixup drops, or any code
changes to the Wine/Proton/DXVK/vkd3d/gamescope stack until the six-source
research checklist below has been completed within a 30-minute time-box.
If a launch option, env var, config flag, or proton-ge build already
solves the problem, that's the answer — even if reading the source feels
more satisfying. No exceptions.

**Announce at start:** "I'm using debugging-linux-games to research before
touching code."

## Rigidity Level

LOW FREEDOM — The research phase is mandatory. The 30-minute time-box is
mandatory. The "no shims until research is done" gate is mandatory.

## The Six-Source Checklist

Time-box: 30 minutes. Stop earlier if a documented fix matches the symptom.

| # | Source | What you're looking for |
|---|--------|-------------------------|
| 1 | **ProtonDB** (`protondb.com/app/<id>`) | Working launch options, known issues, Proton version that works |
| 2 | **Steam Community discussions** for the app, Linux/Wine/Proton tags | Fix threads from devs or users — this is where `/WineDetectionEnabled:False` for PRAGMATA was found |
| 3 | **Game-specific subreddits + r/linux_gaming** | Recent threads naming the title |
| 4 | **GitHub issues** across `ValveSoftware/Proton`, `HansKristian-Work/vkd3d-proton`, `doitsujin/dxvk`, `jp7677/dxvk-nvapi`, `ValveSoftware/gamescope` | Engine-specific bugs and merged workarounds; check both open AND closed |
| 5 | **GE-Proton + proton-cachyos release notes** | Per-release "added fix for X" entries with env vars |
| 6 | **PCGamingWiki Linux section** for the title | Engine-level fixes, "Wayland-broken" / "needs DXVK_CONFIG" notes |

For RE Engine / Capcom titles specifically: check whether
`/WineDetectionEnabled:False` is documented as a launch option — Capcom's
RE Engine games (MH Wilds, PRAGMATA, RE4R, DD2) gate RT/PT/DLSS-RR behind
an internal Wine detection check.

## The Process

### Phase 1: Identify Game + Engine + Stack

Before searching, gather:
- **Game title + Steam app ID** (the app ID makes ProtonDB / Steam community search precise)
- **Engine** (RE Engine, Unreal 4/5, Unity, Source 2, etc.) — engines tend to share fixes
- **Stack** (proton version, GPU vendor + arch, compositor, gamescope yes/no, kernel)
- **Exact symptom** (full error text or screenshot, not paraphrased)
- **What the user already tried**

For NixOS + proton-cachyos + Blackwell + niri specifically: most "X is
broken in gamescope" reports translate to "start with proton-cachyos's
compatibility-first X11/Xwayland default and skip gamescope." When research
identifies native Wine Wayland as the title-specific fix, opt that title in
with `PROTON_USE_WAYLAND=1 %command%`.

### Phase 2: Six-Source Research (30 min, time-boxed)

Dispatch parallel research:

```
Agent (general-purpose, parallel × 2)
  description: "ProtonDB + Steam community search for <title>"
  prompt: |
    Find the working Linux/Proton configuration for <title> (Steam app
    ID <id>). Check:
    - protondb.com/app/<id> — top reports, recommended proton version,
      launch options listed
    - steamcommunity.com/app/<id>/discussions — filter for Linux/Wine/Proton
    - r/linux_gaming and the game's subreddit
    Report: (a) launch options that consistently work, (b) known issues
    list with workarounds, (c) any "do not use gamescope" or "use proton-ge
    X.Y" notes. Under 300 words.

Agent (general-purpose, parallel × 2)
  description: "GitHub issues + PCGamingWiki for <title>/<engine>"
  prompt: |
    Search:
    - github.com/ValveSoftware/Proton issues (open + closed) for "<title>"
      and "<engine>"
    - HansKristian-Work/vkd3d-proton, doitsujin/dxvk, jp7677/dxvk-nvapi
      issues for the same
    - ValveSoftware/gamescope for engine-specific compat issues
    - GE-Proton release notes for added fixes naming the game
    - PCGamingWiki <title> page, Linux section
    Report: (a) issue numbers + status, (b) any env var or
    VKD3D_CONFIG/DXVK_HUD workaround, (c) which proton version landed
    a fix. Under 300 words.
```

While agents run, optionally inspect the local proton log
(`PROTON_LOG=1` writes to `~/steam-<id>.log`) for OBVIOUS errors. **Don't
form a theory yet** — the research output reframes log lines.

### Phase 3: Apply the Documented Fix

If research found a fix:

1. Apply it (launch option in Steam, env var in launch options, etc.)
2. Test it
3. If it works: DONE. Stop. Do not also "fix" the underlying shim.
4. If the fix is wired through nix-config (e.g., add it to
   `pkgs/proton-gamescope/run.sh` as a default), make the minimal change
   and commit with a comment citing the source thread / issue.

### Phase 4: Only If Research Is Empty — Then Diagnose

Only after all six sources have been checked AND no documented fix
exists, escalate to code-level diagnosis:

1. Reproduce with `PROTON_LOG=1`
2. Bisect the stack: try `PROTON_USE_WAYLAND=0/1`, `gamescope on/off`,
   different proton builds (proton-cachyos vs GE-Proton vs experimental)
3. Form a hypothesis WITH EVIDENCE from logs
4. Verify the hypothesis in the source before patching

If you reach this phase, hand off to `gambit:debugging` for the
systematic root-cause process.

## Critical Rules

### Rules That Have No Exceptions

1. **No shim patches before research** — Research takes 30 minutes; patches take days.
2. **The user wanting "the technical answer" is not permission to skip research** — Confident technical briefs about NVAPI IDs / vkd3d swapchain races / NGX queries are exactly the trap this skill exists to prevent.
3. **If the fix is `/some-cli-flag` or `PROTON_FOO=1`, that's the fix** — Don't also patch the underlying behavior. Game ships with a launch option for a reason.
4. **A "confident technical brief" is evidence of a trap, not evidence of correctness** — When training data confidently names internal function IDs, structure fields, or closed-source behavior, treat that as a flag to check community sources HARDER, not as a green light to start patching.
5. **30-minute research time-box is a floor, not a ceiling** — If 30 minutes turns up nothing, that's signal this might genuinely be a new bug; document and proceed to Phase 4. But don't shortcut research because "I bet it's the swapchain."

### Common Excuses

All mean: **STOP. Do the research first.**

| Excuse | Reality |
|--------|---------|
| "I can see from the log it's a vkd3d swapchain race" | Logs after research land differently than logs before research |
| "ProtonDB users don't have this specific Blackwell setup" | Issues from any GPU often share a fix; check anyway |
| "The fix is obvious — let me just patch the shim" | "Obvious" is exactly the bias this skill exists to counter |
| "We already have a fork — just bump it" | If the fork was unnecessary in the first place, bumping it perpetuates the mistake |
| "Community research is slow for niche games" | 30 minutes upper bound. If it's truly niche, you'll know fast |
| "The user is technical and wants the deep answer" | The deep answer is often "the game ships with a CLI flag for this" |

## Reference: PRAGMATA Anti-Pattern

This skill exists because PRAGMATA (Steam app 3357650) was debugged for
~10 hours and produced 4 fork patches:

- `dxvk-nvapi-josh`: 5 Blackwell/Streamline NVAPI ID stubs + CUDA SM fix
- `vkd3d-proton-josh`: 0×0 ResizeBuffers refusal + maxImageExtent bail-out
- `gamescope-patches/win-is-useless-respect-content-override`
- `gamescope-patches/scale-by-buffer-when-x11-geom-smaller`

Every patch addressed a real bug — but none of them gated the user's goal
(RT/PT/DLSS-RR enablement). The actual fix was:

- `PROTON_USE_WAYLAND=1` (skip the X11 path that motivated the gamescope patches)
- `PROTON_DLSS_UPGRADE=1` + don't hide NVIDIA GPU
- `/WineDetectionEnabled:False` as a game launch option

All three were findable in 15 minutes via this skill's checklist. None
were inventable from first principles.

The forks were removed in `nix-config` commit 6251c4c. The branches are
preserved on GitHub for historical reference. Do not repeat this pattern.

## Verification Checklist

Before reporting a "fix" or making any code change to the Wine/Proton stack:

- [ ] Game title + Steam app ID identified
- [ ] Engine identified
- [ ] All six sources checked (or time-box elapsed)
- [ ] Documented fix from community: APPLIED + VERIFIED, or NONE FOUND
- [ ] If applying a documented fix: minimal change, commit references the source
- [ ] If no documented fix: handed off to `gambit:debugging` with research notes attached

**Can't check all boxes?** Return to Phase 2.

## Integration

**This skill calls:**
- Two parallel `general-purpose` research agents (Phase 2)
- `gambit:debugging` (Phase 4, only if research is empty)

**Called by:**
- User reports a Steam game on Linux broken
- Before any commit that touches a Wine/Proton stack package
- Before opening a fork of any Wine/Proton/DXVK/vkd3d/gamescope project
