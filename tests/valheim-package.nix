{
  coreutils,
  launcherTemplate,
  package,
  runCommand,
  source,
}:
runCommand "valheim-server-package-test" {
  nativeBuildInputs = [coreutils];
} ''
    set -eux

    test -x ${package}/bin/valheim-server
    test -f ${source}/server/valheim_server.x86_64
    test -x ${package}/libexec/valheim/valheim_server.x86_64
    test -f ${package}/libexec/valheim/valheim_server_Data/boot.config
    test -f ${source}/runtime/linux64/steamclient.so
    test '${package.src}' = '${source}'
    if grep -Eiq 'steamcmd|depotdownloader|download|update' ${package}/bin/valheim-server; then
      echo 'forbidden runtime updater content found' >&2
      exit 1
    fi
    if grep -q -- '-crossplay' ${package}/bin/valheim-server; then
      echo 'forbidden crossplay content found' >&2
      exit 1
    fi
    grep -Fq 'valheim_server.x86_64' ${package}/bin/valheim-server
    grep -Fq '"$@"' ${package}/bin/valheim-server

    fixture="$TMPDIR/fixture"
    mkdir -p "$fixture/server" "$fixture/runtime/linux64" "$fixture/bin"
    cat > "$fixture/bin/steam-run" <<'SH'
  #!/bin/sh
  if [ -n "''${VALHEIM_TEST_RUNNER_ARGS:-}" ]; then
    printf '%s\n' "$@" > "$VALHEIM_TEST_RUNNER_ARGS"
    exit 0
  fi
  exec "$@"
  SH
    cat > "$fixture/server/valheim_server.x86_64" <<'SH'
  #!/bin/sh
  printf '%s\n' "$@" > "$VALHEIM_TEST_ARGS"
  SH
    chmod +x "$fixture/bin/steam-run" "$fixture/server/valheim_server.x86_64"
    substitute ${launcherTemplate} "$fixture/valheim-server" \
      --replace-fail '@serverRoot@' "$fixture/server" \
      --replace-fail '@runtimeRoot@' "$fixture/runtime" \
      --replace-fail '@steamRun@' "$fixture/bin/steam-run"
    chmod +x "$fixture/valheim-server"
    export VALHEIM_TEST_ARGS="$fixture/actual-args"
    "$fixture/valheim-server" -name 'synthetic server' -port 2456
    printf '%s\n' -name 'synthetic server' -port 2456 > "$fixture/expected-args"
    cmp "$fixture/expected-args" "$fixture/actual-args"

    # Without VALHEIM_LD_PRELOAD the game is launched directly, nothing preloaded.
    export VALHEIM_TEST_RUNNER_ARGS="$fixture/runner-args"
    "$fixture/valheim-server" -port 2456
    printf '%s\n' "$fixture/server/valheim_server.x86_64" -port 2456 > "$fixture/expected-runner"
    cmp "$fixture/expected-runner" "$fixture/runner-args"

    # With it, the preload is set inside steam-run, for the game only.
    VALHEIM_LD_PRELOAD=/doorstop/libdoorstop_x64.so "$fixture/valheim-server" -port 2456
    printf '%s\n' env LD_PRELOAD=/doorstop/libdoorstop_x64.so \
      "$fixture/server/valheim_server.x86_64" -port 2456 > "$fixture/expected-runner"
    cmp "$fixture/expected-runner" "$fixture/runner-args"

    touch "$out"
''
