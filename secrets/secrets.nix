# Define which encrypted files belong to which recipients.
# Update this attrset when creating new secrets with `agenix -e`.
let
  keys = import ./keys.nix;
in {
  # Shared secrets
  #
  # coder-db-password / coder-env (below) and coder-ghcr-cache-auth (host-
  # specific section) are consumed by the out-of-band Coder Docker stack on
  # vermissian — that stack is run directly with `docker compose`, not
  # declared via `age.secrets` in this repo. Don't delete these as orphans;
  # `grep`-for-consumers will correctly find nothing in *.nix.
  "secrets/shared/coder-db-password.age".publicKeys = keys.vermissian;
  "secrets/shared/coder-env.age".publicKeys = keys.vermissian;
  "secrets/shared/atticd-push-token.age".publicKeys = keys.publisherHosts;

  # User secrets (home-manager agenix, all machines)
  "secrets/user/ntfy-url.age".publicKeys = keys.joshsymonds;
  "secrets/user/ntfy-token.age".publicKeys = keys.joshsymonds;
  "secrets/user/morgen-api-key.age".publicKeys = keys.joshsymonds;
  "secrets/user/morgen-mirror-trigger-url.age".publicKeys = keys.joshsymonds;
  "secrets/user/claude-bedrock-models.age".publicKeys = keys.joshsymonds;

  # Host-specific secrets
  "secrets/hosts/ultraviolet/cloudflare-api-token.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/cloudflared-token.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/redlib-collections.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/shimmer-access-client-id.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/shimmer-access-client-secret.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/shimmer-jwt-secret.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/shimmer-env.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/mentat-env.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/invidious-companion-key.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/x11vnc-password.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/mullvad-privatekey.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/mullvad-addresses.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/nextdns-linkip-url.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/pob-server-api-key.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/sound-stage-env.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/inbox-zero-env.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/inbox-zero-db-password.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/atticd-env.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/savecraft-egress-token.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/savecraft-canary-probe-auth.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/savecraft-canary-openrouter-key.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/savecraft-canary-fixture.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/savecraft-canary-access-client-id.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/savecraft-canary-access-client-secret.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/gnomon/mullvad-privatekey.age".publicKeys = keys.gnomon;
  "secrets/hosts/gnomon/mullvad-addresses.age".publicKeys = keys.gnomon;
  "secrets/hosts/vermissian/cloudflared-token.age".publicKeys = keys.vermissian;
  # Out-of-band Coder Docker stack (see the coder-db-password/coder-env
  # comment above) — no in-repo age.secrets declaration, not an orphan.
  "secrets/hosts/vermissian/coder-ghcr-cache-auth.age".publicKeys = keys.vermissian;
}
