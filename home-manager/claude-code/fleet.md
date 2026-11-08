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

Ephemeral NixOS boxes run in us-west-2 or eu-west-1 for work that outgrows
the home hosts. The `ec2` command runs on vermissian and gnomon, the only
hosts with its AWS credentials.

- `ec2 up <class> [--spot-only]` starts a box of a class. `ec2 up <class> --type
  <t>` puts it on type t with the class's name, tags, disk and toplevel; the
  class's module must suit t. `ec2 up --type <t> --disk <gb> [--spot |
  --spot-only]` starts an ad-hoc box; `--disk` is at most 512. `ec2 help` lists
  the classes. A class takes no `--disk` or `--spot`. `ec2 up` refuses, before
  any launch work, a launch that would take the fleet past the warden's 128 vCPU
  cap; the refusal names the fleet total and the box.
- `ec2 up <class> [--override-input <input> <flake-url>]...` builds the class
  toplevel with those flake input overrides. The flag repeats and works only
  for class launches.
- Several `ec2 up` launches on one host that need a new base image in the same
  region build it once. Each other launch prints a line saying it is waiting for
  the base image, waits for that build, and reuses its image.
- A class with `reboot = true` deploys with switch-to-configuration boot,
  reboots, and waits for a new boot id before the ready line. `<name> ready`
  stays the last stdout line.
- Spot launches try every zone of both regions offering the type, with
  regions ranked by AWS spot placement score and ties going to the cheaper
  spot price, then on-demand in the cheapest region first. The launch prints
  `market spot <zone>` or `market on-demand` before the ready line.
  `--spot-only` (class or ad hoc) makes spot attempts only, never on-demand.
  With no zone placing a box, the launch fails naming spot. A `spot = false`
  class refuses it. Ad hoc, it implies `--spot`.
- `ec2 ls` lists pending and running boxes. `ec2 down <name>` terminates one.
- Names are `<class>-xxx`, or `ec2-xxx` for ad-hoc boxes. Connect with
  `ssh joshsymonds@<name>`. A box keeps its name on the tailnet across reboots.
- A box powers off and terminates after `idleMinutes` with no ssh session, load
  of 1.0 or more, or busyCommand exiting 0. An ssh session counts only when a
  process in its scope is not sshd-session, VBCSCompiler (the Roslyn compiler
  server), or a dotnet MSBuild node (dotnet with MSBuild.dll and /nodemode: in
  its command line); a plain dotnet process still counts. It also terminates at
  `maxHours`. Defaults are 60 minutes idle and 24 hours max.
- The warden terminates the newest boxes while fleet boxes total more than 128
  vCPU, and any box up past its `fleet-max-hours` tag (default 24; a tag above
  48 counts as 24). It also terminates a box whose volumes are not one gp3 root
  volume of at most 512 GB, at 3000 IOPS and 125 MB/s, with DeleteOnTermination
  true. It deletes unattached fleet volumes. `ec2 up` refuses a launch that
  would pass the cap.
- Budget is $600/month (budget `ec2-fleet`). AWS emails at 50%, 80% and 100%;
  at 100% RunInstances and snapshot creation are denied. The launcher can
  read the budget (`budgets:ViewBudget`); its spend figure lags by hours.
- Boxes carry tag:ec2 and cannot reach ultraviolet, the NAS, or the home LAN.
  They hold no agenix secrets. Boxes of a class with `cache = true` carry IAM
  role ec2-fleet-cache, which can open sessions on bucket
  joshsymonds-ec2-fleet-cache--usw2-az1--x-s3 and nothing else. The class's
  prefix is mounted read-write (Mountpoint) at its path, owned by its user:
  commonframe uses /home/cf/.cache/commonframe with prefix commonframe/.
  Objects expire after 14 days. Other boxes carry no role. Keep it that way.
- Boot never waits on the cache mount; a failed mount leaves a cold local
  directory. The bucket is S3 Express One Zone in us-west-2, zone usw2-az1, so
  Ireland boxes reach it cross-region. A box starts warm only when its
  commonframe Sim build matches the one that baked the cache.
- Classes are defined in `hosts/ec2/classes.nix`, with modules in
  `hosts/ec2/classes/`.
