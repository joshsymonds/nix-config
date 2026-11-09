# Memory cap for the systemd scopes that terminals run their panes in.
#
# tmux starts every pane in its own tmux-spawn-<uuid>.scope and kitty starts
# every window in kitty-<pid>-<n>.scope, both under the user manager's
# app.slice. A coding agent and everything it spawns share one such scope.
# Nothing limited those scopes, so one runaway child could take the whole
# host: on 2026-11-09 a zsh glob over 5.3M directories grew to 100 GB on
# vermissian (52 GB resident, 47 GB swap) and stalled it for 12 minutes.
#
# systemd applies a `<prefix>-.scope.d` drop-in to every unit whose name
# starts with that prefix. That includes transient scopes, and scopes that
# are already running pick it up at the next daemon-reload.
#
# When a scope reaches the cap, the kernel kills the largest process inside
# it and the command that ran it exits 137. OOMPolicy=continue keeps the rest
# of the scope running; tmux's scopes default to `stop`, which would end the
# whole pane. MemorySwapMax keeps a runaway from grinding through swap before
# the kill.
{
  lib,
  pkgs,
  ...
}: let
  cap = ''
    [Scope]
    MemoryMax=50%
    MemorySwapMax=4G
    OOMPolicy=continue
  '';
  dropIn = prefix: {
    name = "systemd/user/${prefix}-.scope.d/memory-cap.conf";
    value.text = cap;
  };
in {
  xdg.configFile = lib.mkIf pkgs.stdenv.hostPlatform.isLinux (
    builtins.listToAttrs (map dropIn ["tmux-spawn" "kitty"])
  );
}
