{
  lib,
  stdenv,
  fetchurl,
  patchelf,
  glibc,
  perl,
}: let
  version = "2.1.257";
  gcsBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}";

  sources = {
    "aarch64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-arm64/claude";
      hash = "sha256-ZFkNfZ2cGJ0z+z36WMVAjq8qEP5Va9hBVdle+qtGtg4=";
    };
    "x86_64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-x64/claude";
      hash = "sha256-j5DAALHiZdzZKxLG2dE7tdNUxJXmuhXFbrFxACkj2As=";
    };
    "x86_64-linux" = fetchurl {
      url = "${gcsBase}/linux-x64/claude";
      hash = "sha256-mmS9qdhyKh+gW++aWWHQfgMxuZWX7ani9qcy86D/fwU=";
    };
    "aarch64-linux" = fetchurl {
      url = "${gcsBase}/linux-arm64/claude";
      hash = "sha256-IvfUjxcZOVLDwtC4vy8x2yzQj9X7CaN0+jIUlrcR0Bc=";
    };
  };
in
  stdenv.mkDerivation {
    pname = "claude-code-cli";
    inherit version;

    src = sources.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}");

    nativeBuildInputs = [perl] ++ lib.optionals stdenv.hostPlatform.isLinux [patchelf];

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    dontPatchELF = true;

    installPhase =
      ''
        runHook preInstall
        mkdir -p "$out/bin"
        cp "$src" "$out/bin/claude"
        chmod +wx "$out/bin/claude"
        # Neuter the tengu_fleet_past_sessions feature gate so the agents view
        # stops listing every past transcript as an "earlier" row (server-side
        # rollout, no user-facing off switch). The replacement MUST be the same
        # length: the string lives inside the bun-compiled binary and offsets
        # can't move. A renamed gate misses the flag payload and falls back to
        # its default (off); CLAUDE_CODE_FLEET_PAST_SESSIONS=true still force-
        # enables the feature if ever wanted. If a version bump makes the gate
        # count go to 0, upstream renamed it and the patch needs updating.
        gateCount=$(grep -ac 'tengu_fleet_past_sessions' "$out/bin/claude" || true)
        if [ "$gateCount" -eq 0 ]; then
          echo "warning: tengu_fleet_past_sessions gate not found; upstream may have renamed it" >&2
        fi
        perl -pi -e 's/tengu_fleet_past_sessions/tengu_fleet_past_sessionz/g' "$out/bin/claude"
      ''
      + lib.optionalString stdenv.hostPlatform.isLinux ''
        patchelf --set-interpreter "$(cat ${stdenv.cc}/nix-support/dynamic-linker)" "$out/bin/claude"
      ''
      + ''
        # Teach Claude Code the true per-model context window for non-Claude
        # ("foreign") models via three length-preserving substitutions in the
        # embedded JS (same bun-no-integrity-check property the fleet patch above
        # relies on). The script verifies every anchor BEFORE editing and, on any
        # drift (a version bump renamed the minified symbols), applies none and
        # ships the stock binary with a loud warning — the build does not fail,
        # and stock still honours CLAUDE_CODE_MAX_CONTEXT_TOKENS natively.
        #
        # Back up the proven stock binary first (already fleet-patched and, on
        # Linux, patchelf'd, so it is runnable) so the sanity gate below can fall
        # back to it if the patched binary won't start.
        cp "$out/bin/claude" "$TMPDIR/claude.stock"
        perl ${./patch-context-window.pl} "$out/bin/claude"

        # Report which agent's transcript view is focused in the
        # subagentStatusLine payload (per-task `focused` boolean), so Steward
        # can swap the main statusline's model chip to the viewed agent's
        # model. Same warn-and-ship-stock drift model; a stock binary just
        # never sets `focused` and Steward falls back to the aggregate view.
        perl ${./patch-agent-focus.pl} "$out/bin/claude"

        # Runnable sanity gate: the patched binary must still start. On failure,
        # restore the stock backup (do not fail the build).
        export HOME="$TMPDIR"
        if ! timeout 120 "$out/bin/claude" --version >/dev/null 2>&1; then
          echo "warning: [cc-window] patched claude --version failed sanity; restoring stock binary" >&2
          cp "$TMPDIR/claude.stock" "$out/bin/claude"
        fi
        rm -f "$TMPDIR/claude.stock"

        runHook postInstall
      '';

    meta = {
      description = "Anthropic Claude Code CLI - native binary";
      homepage = "https://github.com/anthropics/claude-code";
      license = lib.licenses.unfree;
      maintainers = with lib.maintainers; [];
      platforms = ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"];
      mainProgram = "claude";
    };
  }
