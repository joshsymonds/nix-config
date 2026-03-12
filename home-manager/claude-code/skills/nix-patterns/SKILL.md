---
name: writing-nix-config
description: Patterns for this nix-config flake repository. Use when editing .nix files, adding packages, creating modules, or debugging flake issues.
---

# Nix Configuration Patterns

## Critical Rules

| Rule | Why |
|------|-----|
| Run `update` after changes | Nothing takes effect until rebuilt |
| Run `git add` before `nix flake check` | Flakes only see git-tracked files |
| Use `lib.fakeHash` for unknown hashes | Nix will tell you the real hash on build failure |

## Common Mistakes

| Wrong | Right |
|-------|-------|
| Running `nix flake check` on new files without `git add` | `git add <file>` first |
| Editing config and expecting immediate effect | Run `update` to rebuild |
| Guessing SHA256 hashes | Use `lib.fakeHash`, build, copy real hash from error |
| Adding package only to overlay | Also add to `pkgs/default.nix` |

## Commands

```bash
update                              # Rebuild current system
nix flake check                     # Validate flake
nix build .#<package>               # Build package
nix eval .#nixosConfigurations.<host>.config.<option>  # Check config value
```

## Package Pattern

```nix
# pkgs/<name>/default.nix
{ lib, stdenv, fetchFromGitHub, ... }:
stdenv.mkDerivation rec {
  pname = "name";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "...";
    repo = "...";
    rev = "v${version}";
    hash = "sha256-AAAA...";  # Use lib.fakeHash first, nix will tell you real hash
  };

  meta = with lib; {
    description = "...";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
```

Then add to `pkgs/default.nix` and `overlays/default.nix`.

## Home Manager Module Pattern

```nix
# home-manager/<app>/default.nix
{ pkgs, lib, ... }: {
  home.packages = [ pkgs.app ];

  # Or use programs.<app> if module exists
  programs.app = {
    enable = true;
    settings = { ... };
  };
}
```

Then import in `home-manager/common.nix` or platform-specific file.

## Agenix Secret Pattern

```nix
# 1. Add to secrets/secrets.nix
"secrets/hosts/<host>/<name>.age".publicKeys = keys.<host>;

# 2. Declare in host config
age.secrets."<name>" = {
  file = ../../secrets/hosts/<host>/<name>.age;
  owner = "<service-user>";
  mode = "0400";
};

# 3. Create the secret
agenix -e secrets/hosts/<host>/<name>.age
```

## This Repo's Systems

| Host | Platform | Notes |
|------|----------|-------|
| ninuan | macOS | Primary dev, Aerospace WM |
| ultraviolet | NixOS | Headless server |
| bluedesert | NixOS | Headless server |
| echelon | NixOS | Headless server |
