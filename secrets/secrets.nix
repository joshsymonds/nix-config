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
  "secrets/shared/patchbay-openrouter-key.age".publicKeys = keys.patchbayHosts;
  "secrets/shared/patchbay-caller-key.age".publicKeys = keys.patchbayHosts;

  # User secrets (home-manager agenix, all machines)
  "secrets/user/ntfy-url.age".publicKeys = keys.joshsymonds;
  "secrets/user/ntfy-token.age".publicKeys = keys.joshsymonds;
  "secrets/user/morgen-api-key.age".publicKeys = keys.joshsymonds;
  "secrets/user/morgen-mirror-trigger-url.age".publicKeys = keys.joshsymonds;
  # Personal omakase gateway key (llm.kloverinfrastructure.com), read by Pi
  # through the models.json shell-command resolver (home-manager/pi).
  "secrets/user/omakase-key.age".publicKeys = keys.joshsymonds;
  "secrets/user/tavily-key.age".publicKeys = keys.joshsymonds;
  # Caller model id -> Attain application-inference-profile ARN, for
  # patchbay's attain-bedrock Seat (home-manager/patchbay). The ARNs embed
  # the Attain AWS account id, which is why the map is not in the clear.
  "secrets/user/patchbay-bedrock-model-map.age".publicKeys = keys.joshsymonds;
  # PKCS#12 keystore (store/key password "hexrain-wallpaper"; age is what
  # protects it) signing shrike's hexrain wallpaper APK. Read only by
  # `nix run .#hexrain-wallpaper-release`; never enters the Nix store. Its
  # certificate is pinned in pkgs/hexrain-wallpaper/signer.sha256 — a new
  # key can't update the installed app in place.
  "secrets/user/hexrain-wallpaper-keystore.age".publicKeys = keys.joshsymonds;
  # UniFi gateway (172.31.0.1) local View Only admin, env-style
  # UNIFI_HOST/UNIFI_USERNAME/UNIFI_PASSWORD (+ optional UNIFI_API_KEY), for
  # read-only network observation from the CLI.
  "secrets/user/unifi.age".publicKeys = keys.joshsymonds;
  # Tailscale OAuth client "ec2-fleet-launcher" (scope auth_keys, tag:ec2
  # only), env-style TS_API_CLIENT_ID/TS_API_CLIENT_SECRET. The ec2 fleet
  # launcher mints one single-use ephemeral tag:ec2 key per launch with it.
  "secrets/user/tailscale-fleet-oauth.age".publicKeys = keys.joshsymonds;
  # IAM user ec2-fleet-launcher (created by OpenTofu in infra/aws), env-style
  # AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, read by the `ec2` launcher.
  "secrets/user/ec2-fleet-aws.age".publicKeys = keys.joshsymonds;
  # OpenTofu state/plan encryption passphrase for infra/aws.
  "secrets/user/ec2-fleet-tofu-passphrase.age".publicKeys = keys.joshsymonds;

  # Host-specific secrets
  "secrets/hosts/ultraviolet/cloudflare-api-token.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/cloudflared-token.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/redlib-collections.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/shimmer-access-client-id.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/shimmer-access-client-secret.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/shimmer-jwt-secret.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/shimmer-env.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/mentat-env.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/livekit-keys.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/mentat-voice-env.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/mentat-voice-private.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/mentat-access-client-id.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/mentat-access-client-secret.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/mentat-jwt-secret.age".publicKeys = keys.ultraviolet;
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
  "secrets/hosts/ultraviolet/valheim-password.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/ultraviolet/playroom-path.age".publicKeys = keys.ultraviolet;
  "secrets/hosts/gnomon/mullvad-privatekey.age".publicKeys = keys.gnomon;
  "secrets/hosts/gnomon/mullvad-addresses.age".publicKeys = keys.gnomon;
  "secrets/hosts/gnomon/joshsymonds-password-hash.age".publicKeys = keys.gnomon;
  "secrets/hosts/vermissian/mullvad-privatekey.age".publicKeys = keys.vermissian;
  "secrets/hosts/vermissian/mullvad-addresses.age".publicKeys = keys.vermissian;
  "secrets/hosts/vermissian/cloudflared-token.age".publicKeys = keys.vermissian;
  # Out-of-band Coder Docker stack (see the coder-db-password/coder-env
  # comment above) — no in-repo age.secrets declaration, not an orphan.
  "secrets/hosts/vermissian/coder-ghcr-cache-auth.age".publicKeys = keys.vermissian;
}
