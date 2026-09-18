{pkgs, ...}: {
  imports = [
    ../headless-x86_64-linux.nix
    ../claude-code/transcripts.nix
    ../go
    ../patchbay
    ../patchbay/singularity.nix
  ];

  # Per-host Anthropic API gateway. Mounts /mnt/claude, so it also ships its
  # request ledger to the NAS bucket.
  services.patchbay = {
    enable = true;
    ledgerShipper.enable = true;
    # Holds Codex OAuth creds in ~/.cli-proxy-api, so it runs the CLIProxyAPI
    # upstream and publishes the chatgpt/* routes.
    codexUpstream.enable = true;
  };

  home.packages = with pkgs; [
    jq
    httpie
    websocat
    mkcert
    awscli2
    kind
    kubectl
    ctlptl
    tilt
    postgresql
    mongosh
    tcpdump
    lsof
    inetutils
    kubernetes-helm
    ginkgo
    prisma
    prisma-engines
    rustup
    glab
    slack-cli
    newrelic-cli
  ];

  programs.go.enable = true;

  programs.git.settings.user.signingkey = "0x7DD8F05131AEEC3A";

  # Codex usage allowance exhausted 2026-09-11: subagents ride the anthropic
  # Seat and gambit runs on Claude rungs (Opus workers, Fable escalation and
  # review, Sonnet scouts) until it refills.
  services.patchbay.codexUpstream.exhausted = true;

  # ~/Work/attain sessions bill the employer's Bedrock account through the
  # attain-bedrock Seat (signed from the `attain` AWS profile). Flip to
  # false to put attain back on the personal Anthropic subscription.
  services.patchbay.attainBedrock.enable = true;

  programs.claudeCode.hostContext = ''
    # Host: vermissian (Linux NixOS, x86_64)

    You are on `vermissian`. This is a **Linux NixOS** host — not macOS, not
    another machine in the fleet.

    ## Hardware
    - AMD Ryzen 9 9955HX — 16 cores / 32 threads (Zen 5)
    - 64 GB RAM
    - AMD integrated graphics (Granite Ridge); no discrete GPU
    - 4 TB NVMe root: LUKS (TPM2 auto-unlock) + btrfs impermanence, lanzaboote Secure Boot; headless

    ## Role
    Primary headless dev box. Josh remotes in via SSH/mosh and does most dev
    work here, often via Claude Code. Highest core count + RAM in the fleet,
    so it's the default place for parallel compiles, large nix builds, and
    long-running tasks.

    ## Google Workspace (Sheets, Drive, Docs)
    `gws` is on PATH and is the way to read and write Josh's Google
    documents; use it directly from the shell rather than looking for an
    MCP. It defaults to the work account (jsymonds@joinklover.com); set
    `GWS_ACCOUNT=personal` for josh@joshsymonds.com. Examples:
    `gws sheets spreadsheets values get --params '{"spreadsheetId":"...","range":"Sheet1!A1:D50"}'`,
    `gws drive files list --params '{"q":"name contains \"budget\""}'`,
    `gws schema sheets.spreadsheets.values.update` for any method's shape.
    Auth is borrowed from gcloud (Drive scope), so a failure naming
    `--enable-gdrive-access` means that account needs a gcloud re-login.
    Wrapper and account mapping: home-manager/gws/default.nix.
  '';
}
