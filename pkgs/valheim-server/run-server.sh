#!/bin/sh
set -eu

server_root=@serverRoot@
runtime_root=@runtimeRoot@
export SteamAppId=892970
export LD_LIBRARY_PATH="$runtime_root/linux64:$runtime_root:$server_root${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$server_root"
exec @steamRun@ "$server_root/valheim_server.x86_64" "$@"
