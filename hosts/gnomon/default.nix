let
  network = import ../../lib/network.nix;
  self = network.hosts.gnomon;
  subnet = network.subnets.${self.subnet};
in
  {
    inputs,
    lib,
    pkgs,
    config,
    ...
  }: {
    imports = [
      ./disko.nix
      ./qbittorrent-vpn.nix
      ./shutdown-hardening.nix
      ../../modules/desktop/dms-niri.nix
      ../../modules/hardware/gpu-nvidia.nix
      ../../modules/services/cloudflare-warp-dns.nix
      ../../modules/services/inference-stack.nix
      ../../modules/services/keyd.nix
      ../../modules/services/yubikey-auth.nix
      inputs.lanzaboote.nixosModules.lanzaboote
      inputs.nix-flatpak.nixosModules.nix-flatpak
    ];

    # creative-lab model/training store. Persisted (survives @root-blank
    # rollback) AND owned by the invoking user so rootless podman can write
    # storageDir -> the container's /workspace (devenv.nix). The wrapper's
    # persistDirectories is listOf str → impermanence creates the persist
    # backing root:root and a tmpfiles chown can't win the bind-mount
    # ordering race. So this entry is declared directly with impermanence's
    # native per-directory ownership (post-bindfs-migration submodule), and
    # /var/lib/comfyui is intentionally absent from persistDirectories.
    environment.persistence."/persist".directories = [
      {
        directory = "/var/lib/comfyui";
        user = "joshsymonds";
        group = "joshsymonds";
        mode = "0755";
      }
    ];

    # ── Keyboard: static Mac-style modifier remap on the Q6 HE ──────────
    # Physical bottom-left in Mac mode is [Ctrl][Option][Cmd][Space]. keyd
    # statically relabels the emitted modifier per key: corner Ctrl key →
    # Alt, Option → Super, Cmd → Ctrl. So Cmd+C/V/T/W fire the Linux
    # Ctrl+letter shortcuts in Firefox/Electron natively (no translation
    # layer), Option drives niri (Option+M = Spotify), and bare-Proton games
    # get clean Ctrl (Cmd key) + Alt (corner). kitty swaps Alt↔Ctrl back for
    # itself via app.conf so the terminal keeps interrupt on the corner and
    # copy on the command key. See modules/services/keyd.nix for the why.
    services.keyd-mac-style = {
      enable = true;
      users = ["joshsymonds"];
    };

    # ── YubiKey auth: sudo / polkit / greetd login / DMS lock ──────────
    # Touch the key plugged into the monitor's left-bezel Quick Access
    # USB-A to authenticate. Password remains as fallback. See
    # modules/services/yubikey-auth.nix for enrollment instructions.
    services.yubikey-auth.enable = true;

    # ── Performance profile ─────────────────────────────────────────────
    performance.profile = "dev";
    performance.cpuVendor = "amd";

    # ── Platform ────────────────────────────────────────────────────────
    nixpkgs.hostPlatform = "x86_64-linux";
    nixpkgs.config.allowUnfree = true;

    # ── CPU & GPU ───────────────────────────────────────────────────────
    hardware.cpu.amd.updateMicrocode = true;
    hardware.enableAllFirmware = true;
    hardware.enableRedistributableFirmware = true;

    hardware.gpu-nvidia = {
      enable = true;
      enable32Bit = true; # Steam/Proton, 32-bit Wine
      # 595.71.05 (this nixpkgs pin's production) faults under D3D12
      # PSO-compile load: Xid 109 "CTX SWITCH TIMEOUT" on GameThread
      # killed Satisfactory's device twice in a row (2026-06-12),
      # matching ValveSoftware/Proton#7580 reports blaming the 595
      # branch. Pin the 610.43.02 new-feature branch (hashes from
      # nixpkgs master) — where active Blackwell work lands. Fallbacks
      # if unstable: 595.80 production, 580.159.04 previous-stable.
      # Delete once the flake's nixpkgs ships a fixed production branch.
      package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
        version = "610.43.02";
        sha256_64bit = "sha256-MDSgVLtM33dS/43CclZMsQVROAS/9TU4lFkBsWyndGM=";
        openSha256 = "sha256-hP5NVZZ4vGsACHLmUDKq4uckpd/kn1GxCSYnnJfAuBs=";
        settingsSha256 = "sha256-0YAhufRgjDW+uR+kjaTb154fibpcDw8QowfrucoZsKE=";
        persistencedSha256 = "sha256-Whgv9X+v2fRhzliOl2LzltY9v1SxDafFfv3IUPqj/hk=";
      };
      # cudaArches deliberately left at module default (empty list).
      # Pinning to ["12.0"] (Blackwell-only) was technically tighter
      # but every CUDA package's hash diverged from cache.nixos-cuda.org
      # — forcing ~45-min local rebuilds for onnxruntime, pytorch,
      # ollama-cuda, etc. on every bump. Broad targeting matches the
      # public CI cache, so updates download instead of rebuilding.
      # Runtime perf is identical on a single-arch system (the unused
      # SMs just sit dead in the binary).
    };

    # ── Local LLM stack (llama-swap + llama-server + Open-WebUI) ────────
    # Successor to stygianlibrary's inference workload, migrated off Ollama
    # because Ollama doesn't expose llama.cpp's MoE-aware `--n-cpu-moe` /
    # `--fit on` flags — and on a 16 GB card with Gemma 4 26B-A4B those
    # flags are the difference between 14 tok/s (Ollama partial-layer
    # offload) and 80-100 tok/s (llama.cpp expert-only offload).
    #
    # GGUFs land in /var/lib/llama-models (persisted via disko.nix).
    # Open-WebUI talks to llama-swap over the OpenAI-compatible endpoint
    # so all the multi-model UX (picker, persona-per-model) still works;
    # llama-swap auto-spawns/evicts llama-server backends per model on
    # demand. Open-WebUI ships on 8081 because gluetun-qbittorrent holds
    # 8080 (see qbittorrent-vpn.nix).
    #
    # Sources: nohurry/gemma-4-26B-A4B-it-heretic-GUFF (Unsloth-imatrix
    # quants of coder3101's Heretic-abliterated Gemma 4 26B-A4B-it).
    # Pulls from nohurry here because llama.cpp reads them fine — the
    # Ollama 400 we hit before was Ollama's manifest parser, not the
    # GGUFs themselves.
    #
    # Flags follow the marlang r/LocalLLaMA recipe (5070 Ti + 9800X3D,
    # same hardware): --fit on auto-probes VRAM and picks MoE offload
    # depth; -np 1 drops recurrent state for single-user; -fa on +
    # q8_0 KV cache halves KV memory; -ub 2048 raises prefill
    # throughput; --mlock pins RAM pages so partial-offload doesn't
    # page-fault.
    services.inference-stack = {
      enable = true;
      openWebUI.port = 8081;
      models = let
        base = "https://huggingface.co/nohurry/gemma-4-26B-A4B-it-heretic-GUFF/resolve/main";
        # Dense Gemma 4 12B, Heretic-abliterated by igorls (0/100 genuine
        # refusals at KL 0.0284). Single-file GGUFs; llama.cpp reads them direct.
        base12 = "https://huggingface.co/igorls/gemma-4-12B-it-heretic-GGUF/resolve/main";
        # Qwen 3.6 27B Fable Fusion, Heretic-abliterated and tuned by DavidAU.
        # The LOW MTP IQ4_XS is the highest-quality build sized for a 16 GB
        # GPU. Upstream llama.cpp runs the same architecture about 14x faster
        # than KoboldCpp did on gnomon, so use the stack's standard backend.
        baseQwen36 = "https://huggingface.co/DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF/resolve/main";
        # Sampling params from Google's Gemma 4 partner recommendation
        # (model card + Unsloth docs).
        samplerFlags = [
          "--temp"
          "1.0"
          "--top-p"
          "0.95"
          "--top-k"
          "64"
          "--min-p"
          "0.0"
        ];
        # Common runtime flags. --fit on auto-picks the offload split.
        # --mlock + --no-mmap forces all weight pages resident in RAM,
        # which matters for the CPU-side experts in MoE partial offload.
        commonFlags =
          [
            "--fit"
            "on"
            "--fit-target"
            "256"
            "-np"
            "1"
            "-fa"
            "on"
            "--mlock"
            "--no-mmap"
            "-b"
            "512"
            "-ub"
            "512"
            "-ctk"
            "q8_0"
            "-ctv"
            "q8_0"
          ]
          ++ samplerFlags;
      in {
        "gemma4-heretic-iq4xs" = {
          ggufUrl = "${base}/gemma-4-26b-a4b-it-heretic.iq4_xs.gguf";
          flags = commonFlags ++ ["--fit-ctx" "16384"];
        };
        "gemma4-heretic-q5" = {
          ggufUrl = "${base}/gemma-4-26b-a4b-it-heretic.q5_k_m.gguf";
          flags = commonFlags ++ ["--fit-ctx" "32768"];
        };
        # Dense 12B at Q8_0 (~12 GB) — fits fully in 16 GB VRAM, all on-GPU.
        # Configured like the 26B entries: NO forced thinking. Heretic
        # abliterates the *direct* (non-thinking) response path, so
        # non-thinking is its reliably-uncensored mode; with thinking engaged
        # the chain-of-thought can re-derive a refusal. Roomy 32k ctx.
        "gemma4-12b-heretic-q8" = {
          ggufUrl = "${base12}/gemma-4-12B-it-heretic-Q8_0.gguf";
          flags = commonFlags ++ ["--fit-ctx" "32768"];
        };
        # STOCK (non-abliterated) dense 12B at Q8_0 (~12.7 GB), official
        # ggml-org GGUF — the grailquest local renderer candidate
        # (grailquest docs/llm-tractability.md §5: stock instruct is the
        # doctrine default; abliteration only if evals show refusals on the
        # authored seeds). Thinking disabled via --reasoning-budget 0 — a
        # plain flag, NOT --chat-template-kwargs JSON, because llama-swap
        # shell-parses cmd and strips the JSON's inner double quotes,
        # making llama-server exit 1 on invalid kwargs (hit live 2026-07).
        # grailquest's renderer and judges both run thinking-off by design.
        # Same proven Q8_0/32k footprint as the heretic 12B entry above.
        "gemma4-12b-it" = {
          ggufUrl = "https://huggingface.co/ggml-org/gemma-4-12B-it-GGUF/resolve/main/gemma-4-12B-it-Q8_0.gguf";
          flags = commonFlags ++ ["--fit-ctx" "32768" "--reasoning-budget" "0"];
        };
        # Dense 27B at LOW MTP IQ4_XS (~14.1 GiB). Qwen 3.6 has full attention
        # on only 16/64 layers, making 32k context practical; Q4 KV and
        # llama.cpp autofit minimize the amount that cannot remain in VRAM.
        "qwen3.6-fable-27b-iq4xs-mtp" = {
          ggufUrl = "${baseQwen36}/Qwen3.6-27B-Fable-Fus-711-UnHeretic-NM-DAU-NEO-MAX-NEO-LOW-MTP-IQ4_XS.gguf";
          flags = [
            "--fit"
            "on"
            "--fit-target"
            "256"
            "-c"
            "32768"
            "-np"
            "1"
            "-fa"
            "on"
            "--mlock"
            "--no-mmap"
            "-b"
            "2048"
            "-ub"
            "2048"
            "-ctk"
            "q4_0"
            "-ctv"
            "q4_0"
            "--spec-type"
            "draft-mtp"
            "--spec-draft-n-max"
            "2"
            "--spec-draft-type-k"
            "q4_0"
            "--spec-draft-type-v"
            "q4_0"
            "--jinja"
          ];
        };
        # Qwen3.8-27B (released 2026-08-15 JST) — Tiltyard local-pilot
        # seats. Unsloth GGUFs, arch qwen35, MTP tensors stripped (no
        # spec-draft flags). NO sampler flags baked in: the Tiltyard
        # cohorts pass sampling + chat_template_kwargs per-request via
        # extra_body (llama-swap shell-parses cmd, so JSON flags can't
        # go here anyway — see gemma4-12b-it note above). --jinja for
        # tool calling; --reasoning-format deepseek streams thinking as
        # reasoning_content, which tiltyard's decoder consumes. Explicit
        # -ngl (measured 2026-08-14 alongside the desktop's ~1.5 GB VRAM;
        # --fit mis-probes when other processes hold VRAM): iq4xs 53/65
        # ~= 12 tok/s gen, q3kxl 63/65 ~= 28 tok/s gen. stygianlibrary
        # runs the same models headless at higher splits.
        "qwen3.8-27b-iq4xs" = {
          ggufUrl = "https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-IQ4_XS.gguf";
          flags = [
            "-ngl"
            "53"
            "-c"
            "32768"
            "-np"
            "1"
            "-fa"
            "on"
            "--mlock"
            "--no-mmap"
            "-b"
            "512"
            "-ub"
            "512"
            "-ctk"
            "q8_0"
            "-ctv"
            "q8_0"
            "--jinja"
            "--reasoning-format"
            "deepseek"
          ];
        };
        "qwen3.8-27b-q3kxl" = {
          ggufUrl = "https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-Q3_K_XL.gguf";
          flags = [
            "-ngl"
            "63"
            "-c"
            "32768"
            "-np"
            "1"
            "-fa"
            "on"
            "--mlock"
            "--no-mmap"
            "-b"
            "512"
            "-ub"
            "512"
            "-ctk"
            "q8_0"
            "-ctv"
            "q8_0"
            "--jinja"
            "--reasoning-format"
            "deepseek"
          ];
        };
      };
    };

    # ── Desktop session (niri + DMS, see modules/desktop/dms-niri.nix) ──
    desktop.dms-niri.enable = true;

    # ── Display manager: DankGreeter via greetd ─────────────────────────
    # The greetd-based DMS greeter. halmasuit (the system compositor that
    # owns DRM master initramfs→shutdown to eliminate boot flashes) is
    # being validated on the stygianlibrary test rig; until that work
    # lands, gnomon boots the conventional greetd greeter so it isn't
    # pinned behind in-progress halmasuit debugging. Re-enable halmasuit
    # by re-importing modules/desktop/halmasuit.nix and setting
    # desktop.halmasuit.enable = true (and flipping greeter.enable off).
    desktop.dms-niri.greeter.enable = true;

    # ── Keyboard: Caps Lock → Escape ────────────────────────────────────
    # Handled by keyd at the evdev layer (modules/services/keyd.nix,
    # capslock = esc in [main]), not xkb — keyd rewrites the key event
    # itself so the remap reaches scancode-reading games, which an
    # xkb-level caps:escape silently misses. keyd starts before greetd
    # (multi-user vs graphical target), so caps→esc covers the greeter,
    # Wayland, TTYs, and games.
    console.useXkbConfig = true;

    # ── HID device access for WebHID configurators ──────────────────────
    # Grant the seat-local user read/write on these devices' hidraw nodes
    # so Chromium's WebHID can open the vendor interface. Without uaccess
    # the device shows up in the picker but selection fails with "Failed
    # to select device".
    #   04f3:026e — SOLAKAKA E9 PRO mouse (driver.yuandaxin-tech.com)
    #   3434:0b60 — Keychron Q6 HE keyboard (launcher.keychron.com)
    services.udev.extraRules = ''
      KERNEL=="hidraw*", ATTRS{idVendor}=="04f3", ATTRS{idProduct}=="026e", MODE="0660", TAG+="uaccess"
      KERNEL=="hidraw*", ATTRS{idVendor}=="3434", ATTRS{idProduct}=="0b60", MODE="0660", TAG+="uaccess"
    '';

    # ── Bluetooth: disabled ─────────────────────────────────────────────
    # Probed live: zero connected devices, zero paired devices, no
    # journal activity in 7+ days. The radio was on but unused. Disabling
    # the userspace stack here; the bluetooth + btusb kernel modules are
    # not blacklisted on gnomon (only on servers via server-hardening.nix)
    # so a future re-enable just needs flipping this back to true.
    hardware.bluetooth.enable = false;

    # ── Wi-Fi: blacklisted ──────────────────────────────────────────────
    # Gnomon is permanently on ethernet (r8169); the onboard rtw89 card
    # was auto-binding regardless. Driver-only blacklist — mac80211 and
    # cfg80211 stay loadable here (unlike the servers) so a future
    # re-enable is just deleting these lines. Bluetooth on the same combo
    # card uses btusb, not these modules, so this doesn't block a BT
    # re-enable either.
    boot.blacklistedKernelModules = [
      "rtw89_8922ae"
      "rtw89_pci"
    ];

    # i2c-dev for DDC/CI brightness control over the external Dell U2724Ds.
    # DMS's Go backend (core/internal/server/brightness/ddc.go in the
    # DankMaterialShell flake input) talks i2c directly via /dev/i2c-* — no
    # ddcutil binary needed. `hardware.i2c.enable` loads the i2c-dev kernel
    # module, creates the i2c group, and installs udev rules giving the
    # group rw on /dev/i2c-*.
    #
    # One-time manual step per monitor: enable DDC/CI in the Dell U2724D's
    # on-screen menu (Display Settings → DDC/CI → On). Without that, the
    # /dev/i2c-* nodes exist but no monitor responds, so DMS shows the
    # brightness OSD but slider drags do nothing.
    hardware.i2c.enable = true;
    users.users.joshsymonds.extraGroups = ["i2c"];

    # ── Gaming ──────────────────────────────────────────────────────────
    # Steam compatibility: use the stock "Proton CachyOS x86_64-v3" tool
    # (AVX2/x86_64-v3 ISA build, Steam Linux Runtime sniper variant; prebuilt
    # and pulled from the tokidoki cache below — no compile cost). Set it as
    # the default in Steam → Settings → Compatibility ("Run other titles
    # with…").
    #
    # The shared gaming overlay bakes the NVAPI / iGPU-filter defaults into
    # proton-cachyos's user_settings.py. It intentionally omits
    # PROTON_USE_WAYLAND, inheriting proton-cachyos's compatibility-first X11
    # driver through Xwayland. A per-title Steam launch option can opt into
    # native Wine Wayland with `PROTON_USE_WAYLAND=1 %command%`.
    #
    # We do NOT use gamescope. For titles opted into native Wine Wayland,
    # nesting it forces them back onto XWayland (gamescope never exposes
    # wl_subcompositor, which Wine's wayland driver needs), and on this niri +
    # NVIDIA stack it never presents anyway (the game hangs at startup and no
    # window maps). niri provides natively the only things it would have given
    # us — fullscreen, VRR, HDR.
    #
    # NOTE: programs.steam.gamescopeSession is deliberately NOT enabled.
    # It installs a second wayland-sessions entry (steam.desktop); with
    # gnomon's impermanence wiping DankGreeter's memory.json every boot,
    # the greeter's no-saved-session fallback is a nondeterministic race
    # for session index 0, so an enabled Steam session randomly hijacks login.
    programs.steam = {
      enable = true;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = false;
      extraCompatPackages = with pkgs; [
        proton-cachyos-x86_64-v3
      ];
    };
    hardware.steam-hardware.enable = true;

    # Substituters live in modules/nix/substituters.nix (single source
    # of truth, feature-gated). gnomon picks up tokidoki + lantian because
    # programs.steam.enable=true below, and the CUDA cache because
    # hardware.gpu-nvidia.enable=true above.

    # ── Flatpak (declarative via nix-flatpak) ───────────────────────────
    # `services.flatpak.packages` is reconciled on activation: missing apps
    # are installed, declared apps are updated, and anything not on the list
    # is uninstalled (uninstallUnmanaged = true). The Flathub remote is
    # auto-added by nix-flatpak — no imperative `flatpak remote-add` needed.
    #
    # Why Zoom is here and not in nixpkgs: the official zoom-us client has
    # hard-coded /usr/share/xdg-desktop-portal/portals/ lookups for the
    # screencast path, and niri's portal layout doesn't match. The us.zoom.Zoom
    # Flatpak ships with the FHS layout Zoom expects, so screen sharing on
    # Wayland just works without the in-app config workarounds we used to
    # carry in home-manager/hosts/gnomon.nix (zoomus.conf).
    #
    # Persistence: /var/lib/flatpak is on @root (ephemeral). Without persisting
    # it, every reboot would re-download the GNOME runtime + Zoom (~500 MB).
    # See hosts/gnomon/disko.nix for the persistDirectories entry.
    services.flatpak = {
      enable = true;
      uninstallUnmanaged = true;
      packages = ["us.zoom.Zoom"];
    };

    # ── 1Password ───────────────────────────────────────────────────────
    # Enabling at system level provides:
    #   - `op` CLI on PATH
    #   - SSH-agent unix socket (~/.1password/agent.sock) for git/ssh signing
    #   - PolicyKit integration so the GUI can prompt for system auth
    #     (Quick Unlock, app permissions). polkitPolicyOwners is the list
    #     of users allowed to invoke that.
    programs._1password.enable = true;
    programs._1password-gui = {
      enable = true;
      polkitPolicyOwners = ["joshsymonds"];
    };

    # ── Boot: lanzaboote-signed UKI ─────────────────────────────────────
    # bootspec is unconditionally generated now (boot.bootspec.enable was
    # removed upstream, nixos-unstable 2026-06).
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = true;
    boot.lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
      # ESP is only 1 GiB (modules/disko/btrfs-impermanence.nix
      # hardcodes that — fleet-wide default sized for pre-halmasuit
      # initramfs sizes ~120 MiB). Halmasuit Phase B's NVIDIA-bearing
      # initramfs is ~370 MiB per distinct hash, so the conventional
      # 8-generation retention overflows. 4 retained generations is
      # the realistic ceiling on this ESP: ~2 distinct initramfs
      # hashes alongside 4 UKI stubs + kernel + bootloader files
      # leaves enough room for one in-flight rebuild.
      configurationLimit = 4;
    };

    # ── Kernel: CachyOS latest (generic march) ──────────────────────────
    # Overrides hosts/common.nix's mkDefault linuxPackages_latest. Same
    # mainline Linux source the rest of the fleet runs, with the CachyOS
    # patch stack on top (BORE-EEVDF scheduler, cachy patchset, BBR3).
    # Those patches are where CachyOS earns its tail-latency wins —
    # independent of march flag.
    #
    # Was -x86_64-v3 previously. The retained binary caches do not cover
    # the v3-suffixed variant, and eating a 25–30 min from-source rebuild
    # per kernel bump for sub-1% kernel perf was the wrong trade: the kernel
    # forbids SSE/AVX outside
    # kernel_fpu_begin/end via arch/x86/Makefile -mno-* flags, so
    # -march=v3 can only enable narrow GPR instructions (BMI1/2, LZCNT,
    # MOVBE) in kernel code; SIMD subsystems like crypto/RAID are
    # runtime-dispatched via alternative_call regardless of -march.
    # Userspace v3 (proton-cachyos) keeps its v3 builds where AVX2
    # actually fires in hot loops; the kernel is generic and substituted
    # from the retained lantian Attic cache.
    #
    # The -lto variant is also skipped — clang+ThinLTO would force the
    # out-of-tree it87 module below to build with LLVM too
    # (kernelModuleLLVMOverride), and the LTO kernel-perf gain
    # doesn't pay for that integration work.
    #
    # nvidiaPackages.production is auto-derived by linuxPackagesFor —
    # the NVIDIA proprietary blob rebuilds against this kernel. No
    # special compat shims required; CachyOS is a major NVIDIA distro.
    boot.kernelPackages = inputs.nix-cachyos-kernel.legacyPackages.x86_64-linux.linuxPackages-cachyos-latest;

    # ── Boot: AM5 / 9800X3D ─────────────────────────────────────────────
    # amd_pstate=active matches the X3D's preferred frequency-driver mode.
    # mitigations=auto keeps default kernel mitigations; gamers sometimes pass
    # =off for a few % perf at security cost — explicit "auto" so the choice
    # is visible if you ever revisit it.
    # acpi_enforce_resources=lax: the IT8696E super-I/O on Gigabyte X870
    # boards declares its IO ports in ACPI, which the kernel refuses to
    # let drivers touch under default strict resource enforcement. lax
    # downgrades that refusal to a warning, so the out-of-tree it87
    # module below can claim the ports and expose fan tachs + PWM.
    boot.kernelParams = [
      "amd_pstate=active"
      "mitigations=auto"
      "acpi_enforce_resources=lax"
      # Quiet boot (Epic #42 Layer A) removed 2026-08-14: the suppressed
      # console made the stygianlibrary boot-hang triage impossible —
      # boot messages stay visible on both hosts now.
      # Epic #42 R6: previously this set `loglevel=1` here, but NixOS
      # appends `loglevel=${toString boot.consoleLogLevel}` AFTER the
      # explicit kernelParams, and consoleLogLevel defaults to 4. The
      # later occurrence wins (the kernel takes the last `loglevel=N`
      # token), so the explicit `loglevel=1` had no effect on gen-404
      # and the RDSEED32 ERR-level message (level 3) reached the
      # console because 3 < 4. The fix is to set `boot.consoleLogLevel`
      # directly (below), which becomes the only `loglevel=` token in
      # the cmdline and makes the suppression actually take effect.
      # Initramfs udev quiet (the gen-399 t+6.6s `nvidia: loading
      # out-of-tree module ...` line) and post-pivot udev quiet.
      "fbcon=nodefer"
      # ── Boot at panel native (Layer B) ────────────────────────────────
      # Hint the kernel to set the simpledrm framebuffer at the monitor's
      # native mode (2560x1440 — both DP-2 and DP-3 are connected at
      # this resolution). When firmware GOP honors the hint, the
      # subsequent simpledrm → nvidia-drm modeset is a no-op (same
      # pixel clock, same timings, no monitor re-sync blank). If the
      # firmware GOP can't satisfy it, this param is a no-op — falls
      # back to whatever mode firmware actually exposed; no harm done.
      "video=2560x1440"
    ];

    # consoleLogLevel left at the NixOS default (4): boot diagnostics
    # visible on console (2026-08-14, same change as dropping quiet
    # above). The Epic #42 R6 `loglevel=1` suppression is retired; the
    # RDSEED32 firmware nag returns to the console, which is fine.

    # ── it87 fan tach / PWM (out-of-tree) ───────────────────────────────
    # Mainline it87 doesn't recognize the IT8689E/IT8696E chip IDs on
    # newer Gigabyte boards (X670/X870). The out-of-tree fork
    # (config.boot.kernelPackages.it87, ultimately frankcrawford/it87)
    # carries the ID additions. Exposes fan*_input (RPMs) and pwm*
    # (duty cycle) under /sys/class/hwmon/, which lm_sensors / hass-cli
    # can surface for monitoring.
    #
    # NB: lantian Attic does NOT pre-build kernel modules other than zfs,
    # so this rebuilds locally on every kernel bump. Few minutes per
    # `update`; acceptable trade for the fan visibility.
    boot.extraModulePackages = [
      config.boot.kernelPackages.it87
    ];
    boot.kernelModules = ["kvm-amd" "it87"];

    # NVIDIA modules in initrd avoid the simpledrm → nvidia-drm mode-switch
    # flash on boot. Keeps the kernel console text-mode but at the panel's
    # native resolution from the first frame. (modesetting.enable in
    # gpu-nvidia.nix already sets nvidia-drm.modeset=1.)
    boot.initrd.kernelModules = ["nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm"];

    # 5s grace to hit space for the recovery menu — long enough to actually
    # catch a misbehaving kernel without making routine boots feel sluggish.
    boot.loader.timeout = 5;

    # ── Boot: initrd hardware modules ──────────────────────────────────
    # Standard for AM5 NVMe + USB. If real hardware reveals missing modules
    # at install time, fold them into THIS file in a follow-up commit.
    boot.initrd.availableKernelModules = [
      "nvme"
      "xhci_pci"
      "ahci"
      "usbhid"
      "usb_storage"
      "sd_mod"
    ];

    # ── LUKS: FIDO2 unlock fallback ────────────────────────────────────
    # systemd-initrd auto-tries enrolled tokens in order: systemd-tpm2 first
    # (silent, normal boot), then systemd-fido2 (touch the YubiKey), then
    # the passphrase prompt. fido2-device=auto makes the FIDO2 attempt
    # explicit so a future systemd change can't quietly drop it. Both
    # YubiKeys are enrolled via `systemd-cryptenroll --fido2-device=auto`.
    boot.initrd.luks.devices.cryptroot.crypttabExtraOpts = ["fido2-device=auto"];

    # ── Networking: static IP via systemd-networkd, wildcard interface match ──
    # Same pattern as ultraviolet/vermissian — no hardcoded interface name.
    # The actual NIC (whatever its kernel-assigned `enX` name is) is matched
    # by the `en*` glob, so changing motherboards or upgrading the kernel's
    # device naming doesn't break the static-IP config.
    networking = {
      useDHCP = false;
      useNetworkd = true; # disable legacy scripted networking; systemd-networkd handles it
      hostName = "gnomon";
      firewall = {
        enable = true;
        trustedInterfaces = ["tailscale0"];
        allowedTCPPorts = [22];
      };
    };

    # ── Tailscale ───────────────────────────────────────────────────────
    # Workstation-mode client: no subnet routing, no exit-node advertising.
    # `openFirewall = true` opens the WireGuard UDP port automatically;
    # tailscale0 is in trustedInterfaces above so peers can reach local services.
    services.tailscale = {
      enable = true;
      package = pkgs.tailscale;
      useRoutingFeatures = "client";
      openFirewall = true;
    };

    # WARP enrollment is interactive and local. In Traffic and DNS mode,
    # Cloudflare processes system DNS while connected; tray Disconnect is the
    # personal-DNS privacy boundary. Do not add ProtectSystem=strict here:
    # Gnomon observed EROFS while WARP applied DNS because the upstream unit
    # only allow-lists the existing /etc/resolv.conf, not its parent directory.
    services.cloudflare-warp = {
      enable = true;
      openFirewall = false;
    };

    # WARP's own DNS handling stops at /etc/resolv.conf, which glibc never
    # reads here; without this, Gateway sees no lookups and FQDN-based egress
    # policies never match. See the module for the full reasoning.
    services.cloudflareWarpDns.enable = true;

    environment.systemPackages = with pkgs; [sbctl tailscale];

    # Wired LAN comes up in 1-3s when the cable is live; without this cap,
    # systemd-networkd-wait-online holds network-online.target for the full
    # 120s default if the link is unplugged or the switch is down. 10s is
    # generous for the healthy case and bounds the cold-boot stall for
    # everything that depends on network-online (gluetun, NFS-via-network,
    # tailscale, etc.) when the network really is gone.
    systemd.network.wait-online = {
      anyInterface = true;
      timeout = 10;
    };
    systemd.network.networks."10-lan" = {
      matchConfig.Name = "en*";
      address = ["${self.ip}/${toString subnet.prefixLength}"];
      gateway = [subnet.gateway];
      dns = subnet.nameservers;
    };

    # ── State version ───────────────────────────────────────────────────
    system.stateVersion = "25.05";
  }
