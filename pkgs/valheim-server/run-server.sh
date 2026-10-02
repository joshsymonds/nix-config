#!/bin/sh
set -eu

server_root=@serverRoot@
runtime_root=@runtimeRoot@
export SteamAppId=892970
export LD_LIBRARY_PATH="$runtime_root/linux64:$runtime_root:$server_root${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$server_root"
# BepInEx's Doorstop loader is preloaded into the game only, inside the
# steam-run FHS, so the sandbox wrapper itself never loads it.
if [ -n "${VALHEIM_LD_PRELOAD:-}" ]; then
  exec @steamRun@ env LD_PRELOAD="$VALHEIM_LD_PRELOAD" "$server_root/valheim_server.x86_64" "$@"
fi
exec @steamRun@ "$server_root/valheim_server.x86_64" "$@"
