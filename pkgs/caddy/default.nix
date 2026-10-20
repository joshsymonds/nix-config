{caddy}:
# Upstream Caddy plus the Cloudflare DNS provider (ACME DNS-01 for the
# ultraviolet vhosts). This used to build joshsymonds/caddy, a v2.7.5 fork
# carrying exactly two changes: the caddy-dns/cloudflare import and a
# `{file.*}` global placeholder. The placeholder landed upstream in v2.8.0
# (replacer.go's fileReplacementProvider), so only the plugin remains, and
# nixpkgs' xcaddy-based withPlugins builds it against nixpkgs' caddy.
caddy.withPlugins {
  plugins = ["github.com/caddy-dns/cloudflare@v0.2.4"];
  hash = "sha256-5a5cpFl90pEWt0lUC4ZJQ7g+1//ZvsRhee64Dt9vh5o=";
}
