{
  lib,
  pkgs,
  ...
}: let
  sshAgentSocket = "$XDG_RUNTIME_DIR/ssh-agent.socket";

  # Script to find and add all git-related SSH keys
  addGitKeys = pkgs.writeShellScriptBin "ssh-add-git-keys" ''
    #!${pkgs.bash}/bin/bash
    export PATH="${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.gawk}/bin:${pkgs.gnused}/bin:${pkgs.openssh}/bin:$PATH"

    # Function to check if a key is already added
    is_key_added() {
      local key_file="$1"
      local fingerprint
      fingerprint=$(ssh-keygen -lf "$key_file.pub" 2>/dev/null | awk '{print $2}')
      [ -n "$fingerprint" ] && ssh-add -l 2>/dev/null | grep -q "$fingerprint"
    }

    # Function to add a key if not already added
    add_key_if_needed() {
      local key_file="$1"
      if [ -f "$key_file" ] && [ -f "$key_file.pub" ]; then
        if ! is_key_added "$key_file"; then
          echo "Adding SSH key: $key_file"
          ssh-add "$key_file" 2>/dev/null
        else
          echo "Key already added: $key_file"
        fi
      fi
    }

    # Common git-related key patterns
    for pattern in "id_rsa" "id_ed25519" "id_ecdsa" "github" "gitlab" "bitbucket" "git"; do
      for key in ~/.ssh/$pattern ~/.ssh/*_$pattern ~/.ssh/$pattern_*; do
        # Skip glob patterns that don't match
        [ -f "$key" ] || continue
        # Skip public keys
        [[ "$key" == *.pub ]] && continue
        # Skip backup files
        [[ "$key" == *~ ]] && continue

        add_key_if_needed "$key"
      done
    done

    # Also check for keys mentioned in SSH config
    if [ -f ~/.ssh/config ]; then
      for key in $(grep -h "^\s*IdentityFile" ~/.ssh/config 2>/dev/null | awk '{print $2}' | sed "s|^~|$HOME|"); do
        [ -f "$key" ] && add_key_if_needed "$key"
      done
    fi
  '';
in {
  # SSH client configuration improvements
  programs = {
    ssh = {
      enable = true;
      enableDefaultConfig = false;
      extraConfig = ''
        # Use the systemd/launchd managed SSH agent socket
        ${lib.optionalString pkgs.stdenv.isLinux ''
          IdentityAgent /run/user/1000/ssh-agent.socket
        ''}

        # macOS specific: use system keychain for passphrase caching
        ${lib.optionalString pkgs.stdenv.isDarwin ''
          UseKeychain yes
          IdentityFile ~/.ssh/github
        ''}
      '';

      matchBlocks."*" = {
        addKeysToAgent = "yes"; # Automatically add keys to agent when used
      };
    };

    # Shell aliases for convenience
    zsh.shellAliases = {
      ssh-keys = "ssh-add -l";
      ssh-add-all = "ssh-add-git-keys";
    };
  };

  # Linux: systemd user service for SSH agent
  systemd.user.services.ssh-agent = lib.mkIf pkgs.stdenv.isLinux {
    Unit = {
      Description = "SSH Agent";
      Documentation = "man:ssh-agent(1)";
    };

    Service = {
      Type = "simple";
      Environment = "SSH_AUTH_SOCK=%t/ssh-agent.socket";
      ExecStart = "${pkgs.openssh}/bin/ssh-agent -D -a %t/ssh-agent.socket";
      ExecStartPost = "${addGitKeys}/bin/ssh-add-git-keys";
      Restart = "on-failure";
      RestartSec = "5s";
    };

    Install = {
      WantedBy = ["default.target"];
    };
  };

  # Linux: Set SSH_AUTH_SOCK environment variable
  home.sessionVariables = lib.mkIf pkgs.stdenv.isLinux {
    SSH_AUTH_SOCK = sshAgentSocket;
  };

  # Add the helper script to user packages
  home.packages = [addGitKeys];
}
