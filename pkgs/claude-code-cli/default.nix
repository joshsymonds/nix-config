{
  lib,
  stdenv,
  fetchurl,
  patchelf,
  glibc,
  perl,
  darwin,
}: let
  version = "2.1.314";
  gcsBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}";

  sources = {
    "aarch64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-arm64/claude";
      hash = "sha256-Idbnuabwe0z8t98Tdgs7cqol4IThOlNUQTOCmHuoMu0=";
    };
    "x86_64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-x64/claude";
      hash = "sha256-QEd5owijWOzsiyXIvM8M55qUzyYdEst0BlUY0YnBdPg=";
    };
    "x86_64-linux" = fetchurl {
      url = "${gcsBase}/linux-x64/claude";
      hash = "sha256-RIcEK0xPXYjUVo9orpiq4LH/rliGTPV/uGhkG8X4RZQ=";
    };
    "aarch64-linux" = fetchurl {
      url = "${gcsBase}/linux-arm64/claude";
      hash = "sha256-pmwKj10Mh6Q5lT15eYUZK7y677zi4Ney6qjfMO8PPvI=";
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
      ''
      + lib.optionalString stdenv.hostPlatform.isLinux ''
        patchelf --set-interpreter "$(cat ${stdenv.cc}/nix-support/dynamic-linker)" "$out/bin/claude"
      ''
      + ''
        # Keep the runnable, unpatched binary: drop-bytecode.pl below diffs the
        # patched modules against it, and the sanity gate falls back to it.
        cp "$out/bin/claude" "$TMPDIR/claude.stock"

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

        # Zero out tengu_heron_brook: a server-served string that the
        # system-prompt builder appends as its "heron_brook" section. It is read
        # from bootstrap client_data first (cached in ~/.claude.json, so
        # CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC only freezes it), then from
        # the GrowthBook flag of the same name. Renaming the key, same length,
        # makes both lookups miss, so the section falls back to its built-in
        # behaviour. \b keeps the tengu_heron_brook_applied telemetry event intact.
        heronCount=$(grep -aPc 'tengu_heron_brook\b' "$out/bin/claude" || true)
        if [ "$heronCount" -eq 0 ]; then
          echo "warning: tengu_heron_brook key not found; upstream may have renamed it" >&2
        fi
        perl -pi -e 's/tengu_heron_brook\b/tengu_heron_brooz/g' "$out/bin/claude"

        # Teach Claude Code the true per-model context window for non-Claude
        # ("foreign") models via three length-preserving substitutions in the
        # embedded JS. The script verifies every anchor BEFORE editing and, on
        # any drift (a version bump renamed the minified symbols), applies none
        # and ships the binary unpatched with a loud warning — the build does
        # not fail, and stock still honours CLAUDE_CODE_MAX_CONTEXT_TOKENS.
        perl ${./patch-context-window.pl} "$out/bin/claude"

        # Report which agent's transcript view is focused in the
        # subagentStatusLine payload (per-task `focused` boolean), so Steward
        # can swap the main statusline's model chip to the viewed agent's
        # model. Same warn-and-ship-stock drift model; a stock binary just
        # never sets `focused` and Steward falls back to the aggregate view.
        perl ${./patch-agent-focus.pl} "$out/bin/claude"

        # Let bypassPermissions mode skip the dangerous-removal prompts
        # ("rm -rf $VAR/..."), which stock marks bypass-immune with no off
        # switch. Same warn-and-ship-stock drift model.
        perl ${./patch-dangerous-rm.pl} "$out/bin/claude"

        # The patches above edit embedded JS source, but Bun runs a module's
        # precompiled bytecode whenever it has some, so the edits only take
        # effect once the patched modules lose their bytecode and compile from
        # source. Every patch since at least 2.1.257 was inert without this.
        perl ${./drop-bytecode.pl} "$TMPDIR/claude.stock" "$out/bin/claude"
      ''
      + lib.optionalString stdenv.hostPlatform.isDarwin ''

        # Any byte edit invalidates the embedded code signature, and macOS
        # SIGKILLs a Mach-O with an invalid signature at exec. Re-sign ad hoc
        # here, before the sanity gate, so the gate exercises the binary that
        # actually ships.
        source ${darwin.signingUtils}
        sign "$out/bin/claude"
      ''
      + ''

        # Runnable sanity gate: the patched binary must still start. On failure,
        # restore the unpatched binary (do not fail the build).
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
