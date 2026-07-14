{
  lib,
  stdenv,
  fetchurl,
  patchelf,
  glibc,
  perl,
}: let
  version = "2.1.208";
  gcsBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}";

  sources = {
    "aarch64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-arm64/claude";
      hash = "sha256-BRx/KIcbFYEyrAOmFA8vKrQEaxjsxPepGirE1Ud0VR4=";
    };
    "x86_64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-x64/claude";
      hash = "sha256-gE6oHLHitfiDwkkPxmj9Gc4YXje5uZkfWDLTjcYuL/Q=";
    };
    "x86_64-linux" = fetchurl {
      url = "${gcsBase}/linux-x64/claude";
      hash = "sha256-ElNyg5vIJ8ok3XI4JieykfvKYVQI1zL+MpG8FnI85/M=";
    };
    "aarch64-linux" = fetchurl {
      url = "${gcsBase}/linux-arm64/claude";
      hash = "sha256-geXdSDd7/Ty3M4IOTiPyKUySXLoeUtvq2mn0aSnwxKY=";
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
