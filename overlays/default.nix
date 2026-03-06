# This file defines overlays
{inputs, ...}: let
  moarRev = "25be66bf628ad02e807ca929b5e7a1128511d255";
  moarVersion = "unstable-2025-11-09";
  moarVersionString = "${moarVersion}+g${builtins.substring 0 7 moarRev}";
in {
  default = final: prev: let
    shimmerPkg = inputs.shimmer.packages.${final.stdenv.hostPlatform.system}.default;
    devenvPkg = inputs.devenv.packages.${final.stdenv.hostPlatform.system}.devenv;
  in {
    devenv = devenvPkg;
    shimmer = shimmerPkg;
    myCaddy = final.callPackage ../pkgs/caddy {};
    starlark-lsp = final.callPackage ../pkgs/starlark-lsp {};
    nuclei = final.callPackage ../pkgs/nuclei {};
    mcp-atlassian = final.callPackage ../pkgs/mcp-atlassian {};
    claudeCodeCli = final.callPackage ../pkgs/claude-code-cli {};
    geminiCli = final.callPackage ../pkgs/gemini-cli {};
    deadcode = final.callPackage ../pkgs/deadcode {};
    golangciLintBin = final.callPackage ../pkgs/golangci-lint-bin {};
    heretic = final.callPackage ../pkgs/heretic {python3Packages = final.python312Packages;};
    coder = final.callPackage ../pkgs/coder-cli {inherit (final) unzip;};
    invidious-companion = final.callPackage ../pkgs/invidious-companion {};
    redlib-veraticus = final.callPackage ../pkgs/redlib-veraticus {
      inherit (inputs) crane;
      redlibSrc = inputs.redlib-fork.sourceInfo.outPath;
      redlibRev = inputs.redlib-fork.sourceInfo.rev;
      rustOverlay = inputs.rust-overlay;
    };

    # gocover-cobertura 1.3.0 fails to build with Go 1.24; rebuild with Go 1.23
    gocover-cobertura =
      final.callPackage
      (inputs.nixpkgs + "/pkgs/by-name/go/gocover-cobertura/package.nix")
      {
        buildGoModule = final.buildGo123Module;
      };

    # Package modifications
    waybar = prev.waybar.overrideAttrs (oldAttrs: {
      mesonFlags = oldAttrs.mesonFlags ++ ["-Dexperimental=true"];
      version = "0.9.21";
    });

    moor = prev.moor.overrideAttrs (_: {
      version = moarVersion;
      src = final.fetchFromGitHub {
        owner = "walles";
        repo = "moor";
        rev = moarRev;
        hash = "sha256-c2ypM5xglQbvgvU2Eq7sgMpNHSAsKEBDwQZC/Sf4GPU=";
      };
      vendorHash = "sha256-ve8QT2dIUZGTFYESt9vIllGTan22ciZr8SQzfqtqQfw=";
      ldflags = [
        "-s"
        "-w"
        "-X"
        "main.versionString=${moarVersionString}"
      ];
      postInstall = ''
        ln -s moor "$out/bin/moar"
        if [ -f ./moor.1 ]; then
          installManPage ./moor.1
        fi
      '';
    });
    moar = final.moor;

    # n8n - pinned to latest version
    n8n = prev.n8n.overrideAttrs (old: rec {
      version = "2.6.3";
      src = final.fetchFromGitHub {
        owner = "n8n-io";
        repo = "n8n";
        tag = "n8n@${version}";
        hash = "sha256-nViKshhkBL8odVDqKGTJTMjVpYtI0Qp3z59VI+DNsms=";
      };
      pnpmDeps = final.fetchPnpmDeps {
        inherit (old) pname;
        inherit version src;
        pnpm = final.pnpm_10;
        fetcherVersion = 3;
        hash = "sha256-vjgteuMd+lkEL9vT1Ngndk8G3Ad1esa1NBPpEHBFmDg=";
      };
    });

    # XIVLauncher customizations
    xivlauncher =
      prev.xivlauncher.override {
        steam = prev.steam.override {
          extraLibraries = _: [prev.gamemode.lib];
        };
      }
      // {
        desktopItems = [];
      };

    vaapiIntel = prev.vaapiIntel.override {
      enableHybridCodec = true;
    };

    # Stable packages available under pkgs.stable (if needed)
    stable = import inputs.nixpkgs-stable {
      system = final.stdenv.hostPlatform.system;
      config.allowUnfree = true;
    };
  };

  additions = _: _: {};
  modifications = _: _: {};
  unstable-packages = _: _: {};
  darwin = import ./darwin.nix;
}
