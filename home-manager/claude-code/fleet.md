# The Fleet

For orientation when the user references another machine. The user is on the
host described in `host.md`. **Do not volunteer that work should move
elsewhere unprompted** — if Josh is doing something on this box, assume
there's a reason. Only suggest a different host when explicitly asked, or
when the current host genuinely cannot do the task (e.g. CUDA work off-gnomon).

All hosts are reachable from each other by hostname (LAN DNS or tailscale
MagicDNS). Use hostnames, not IPs. Ninuan is a laptop and does not accept SSH.
EC2 fleet boxes join the tailnet too, but they are not home hosts; see
Cloud workers (ec2) below.

- **vermissian** — headless NixOS dev box. Ryzen 9 9955HX (16c/32t), 64 GB RAM,
  AMD iGPU. Highest-throughput compile target.
- **gnomon** — NixOS desktop. Ryzen 7 9800X3D (8c, SMT off), 64 GB RAM,
  **RTX 5070 Ti 16 GB**. Only host with discrete GPU / CUDA.
- **ultraviolet** — headless NixOS home server. i3-12300HL, 64 GB RAM. Runs
  Home Assistant, the *arr media stack + SABnzbd, Jellyfin, atticd nix cache,
  cloudflared tunnels, Shimmer and other self-hosted apps. Tailscale exit node.
- **ninuan** — macOS, Apple M5 MacBook Pro. Portable work. No inbound SSH.
- **bluedesert** — small NixOS box, Pentium N4200 + 4 GB. Z-Wave / Home
  Assistant proxy. Resource-constrained; no Claude Code installed there.
- **echelon** — small NixOS box on a separate LAN, reachable via tailscale.
  Same hardware class as bluedesert.

## Useful infra
- **NAS**: Synology DS218+ at `172.31.0.100` (`blackbox`). NFS shares: video,
  music, books, backup, creative. Per-share IP allowlists; vermissian has wide
  access. all_squash → uid 1024, gid 100.
- **Home LAN**: 172.31.0.0/24 (vermissian, gnomon, ultraviolet, bluedesert, NAS).
- **Tailnet**: every host above is on tailscale; ultraviolet and echelon offer
  exit-node service.

## Cloud workers (ec2)

Ephemeral NixOS boxes in us-west-2 for work that outgrows the home hosts. The
`ec2` command runs on vermissian and gnomon, the only hosts with its AWS
credentials.

- `ec2 up <class>` starts a box of a class. `ec2 up --type <t> --disk <gb>
  [--spot]` starts an ad-hoc box. `ec2 help` lists the classes.
- `ec2 ls` lists pending and running boxes. `ec2 down <name>` terminates one.
- Names are `<class>-xxx`, or `ec2-xxx` for ad-hoc boxes. Connect with
  `ssh joshsymonds@<name>`.
- A box powers off and terminates after `idleMinutes` with no ssh session, load
  of 1.0 or more, or busyCommand exiting 0. It also terminates at `maxHours`.
  Defaults are 60 minutes idle and 24 hours max.
- The warden terminates the newest boxes while fleet boxes total more than 128
  vCPU, and any box up past its `fleet-max-hours` tag (default 24).
- Budget is $200/month. At 100%, RunInstances and snapshot creation are denied.
- Boxes carry tag:ec2 and cannot reach ultraviolet, the NAS, or the home LAN.
  They hold no agenix secrets and no IAM role. Keep it that way.
- Classes are defined in `hosts/ec2/classes.nix`, with modules in
  `hosts/ec2/classes/`.
