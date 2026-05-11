{...}: {
  xdg.configFile."statusline-aliases/aliases.toml".text = ''
    # Shared alias + env-classification table for the statusline.
    # Read by both `cc-tools resolve` (used by starship custom modules)
    # and by the cc-tools statusline directly.

    # --- Hosts ---------------------------------------------------------
    [hosts.ultraviolet]
    label = "uv"

    [hosts.bluedesert]
    label = "bd"

    [hosts.echelon]
    label = "ec"

    [hosts.ninuan]
    label = "nn"

    # --- k8s contexts (populate as encountered) ------------------------
    # [k8s."connectgateway_klover-loan-application_global_core-production-us-east1"]
    # label = "klover prod"
    # env = "prod"

    # --- AWS profiles --------------------------------------------------
    # [aws."acme-prod-administrator"]
    # label = "acme prod"
    # env = "prod"

    # --- gcloud projects -----------------------------------------------
    # [gcloud."klover-loan-application"]
    # label = "klover"
    # env = "prod"

    # --- env classifier fallback (substring match, case-insensitive) ---
    [env_patterns]
    prod = ["prod", "production"]
    staging = ["stag", "staging"]
    dev = ["dev", "sandbox", "sbx", "test"]
  '';
}
