{
  lib,
  pkgs,
  ...
}: {
  # Vesktop = Discord client (Electron + Vencord patches). Two settings
  # files we touch, neither owned end-to-end:
  #
  # 1. ~/.config/vesktop/settings/settings.json    — Vencord settings.
  #    The big one. Per-plugin enabled state lives here, and Vencord
  #    rewrites it on every UI toggle. We do NOT manage the whole file —
  #    just merge in `transparent: true` so the BrowserWindow opens with
  #    the Electron `transparent` flag set (line 342 of Vesktop's
  #    src/main/mainWindow.ts). Without this, even if niri is willing to
  #    blur, there's nothing to blur through — Vesktop's window is opaque.
  #
  # 2. ~/.config/vesktop/settings.json              — Vesktop's own settings.
  #    Smaller. We merge in `splashBackground: "#00000000"` so the
  #    pre-renderer splash flash isn't an opaque rectangle at startup
  #    (otherwise: ~200ms of solid #313338 on every launch before the
  #    renderer takes over). `splashTheming: true` is the default but we
  #    set it explicitly because mainWindow.ts only reads splashBackground
  #    when splashTheming !== false.
  #
  # Why an activation and not xdg.configFile: Vesktop writes back to both
  # files at runtime. A read-only HM symlink would either be overwritten
  # by Electron's writeFileSync (silently breaking declarative-ness) or
  # cause runtime errors. The activation script merges keys with jq and
  # leaves the rest of each file alone — mutable on disk, but our two
  # keys are reasserted on every `update`.
  home.packages = [pkgs.vesktop];

  home.activation.vesktopTransparency = lib.hm.dag.entryAfter ["writeBoundary"] ''
    JQ=${pkgs.jq}/bin/jq
    VENCORD_FILE="$HOME/.config/vesktop/settings/settings.json"
    VESKTOP_FILE="$HOME/.config/vesktop/settings.json"

    setJsonKey() {
      # $1=file  $2=key  $3=JSON-encoded value (true / "#00000000" / 42)
      local file="$1" key="$2" value="$3"
      mkdir -p "$(dirname "$file")"
      [ -f "$file" ] || echo '{}' > "$file"
      # Skip the rewrite when the value already matches — keeps mtime
      # stable so we don't trigger Electron's chokidar-style listeners.
      local current
      current=$($JQ -c --arg k "$key" '.[$k]' "$file" 2>/dev/null) || current=null
      if [ "$current" != "$value" ]; then
        local tmp
        tmp=$(mktemp)
        $JQ --argjson v "$value" --arg k "$key" '.[$k] = $v' "$file" > "$tmp" \
          && mv "$tmp" "$file"
      fi
    }

    setJsonKey "$VENCORD_FILE" transparent true
    setJsonKey "$VESKTOP_FILE" splashBackground '"#00000000"'
    setJsonKey "$VESKTOP_FILE" splashTheming true
  '';
}
