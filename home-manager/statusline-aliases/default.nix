{...}: {
  xdg.configFile."statusline-aliases/aliases.toml".text = ''
    # Shared alias + env-classification table for the statusline.
    # Read by both `steward resolve` (used by starship custom modules)
    # and by the Steward statusline directly.

    # --- Hosts ---------------------------------------------------------
    [hosts.ultraviolet]
    label = "uv"

    [hosts.bluedesert]
    label = "bd"

    [hosts.echelon]
    label = "ec"

    [hosts.ninuan]
    label = "nn"

    [hosts.vermissian]
    label = "vm"

    # --- k8s contexts --------------------------------------------------
    # klover-central is the platform/tooling account (atlantis lives
    # there). Not in the prod/staging/dev triad — leave env unset so
    # the chip renders in the neutral `unknown` color and the label
    # carries the identity.
    [k8s."connectgateway_klover-central_global_klover-central-us-east1"]
    label = "central"

    [k8s."connectgateway_klover-loan-application_global_core-production-us-east1"]
    label = "loan prod"
    env = "prod"

    # --- AWS profiles --------------------------------------------------
    # [aws."acme-prod-administrator"]
    # label = "acme prod"
    # env = "prod"

    # --- gcloud projects -----------------------------------------------
    [gcloud."klover-central"]
    label = "central"

    [gcloud."klover-loan-application"]
    label = "loan"
    env = "prod"

    # --- env classifier fallback (substring match, case-insensitive) ---
    [env_patterns]
    prod = ["prod", "production"]
    staging = ["stag", "staging"]
    dev = ["dev", "sandbox", "sbx", "test"]
  '';
}
