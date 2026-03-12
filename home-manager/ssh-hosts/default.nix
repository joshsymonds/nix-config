_: {
  # 🌐 Smart SSH Host Commands for Mac - SSH only, no ET
  programs.zsh.initContent = ''
    # Configuration for all hosts
    declare -A HOST_IPS
    declare -A HOST_TAILSCALE

    # Define hosts with their local IPs and Tailscale names
    HOST_IPS[ultraviolet]="172.31.0.200"
    HOST_TAILSCALE[ultraviolet]="ultraviolet"

    HOST_IPS[bluedesert]="172.31.0.201"
    HOST_TAILSCALE[bluedesert]="bluedesert"

    HOST_IPS[echelon]="192.168.1.200"  # Different subnet
    HOST_TAILSCALE[echelon]="echelon"

    HOST_IPS[cloudbank]="127.0.0.1"  # Local machine
    HOST_TAILSCALE[cloudbank]=""  # Not on Tailscale

    HOST_IPS[ninuan]="127.0.0.1"  # Local machine
    HOST_TAILSCALE[ninuan]=""  # Not on Tailscale

    # Cache for Tailscale status (5 minute TTL)
    TAILSCALE_STATUS_CACHE=""
    TAILSCALE_STATUS_TIME=0

    # Fast Tailscale status check with caching
    _get_tailscale_status() {
      local current_time=$(date +%s)
      local cache_age=$((current_time - TAILSCALE_STATUS_TIME))

      # Use cache if less than 5 minutes old (300 seconds)
      if [ $cache_age -lt 300 ] && [ -n "$TAILSCALE_STATUS_CACHE" ]; then
        echo "$TAILSCALE_STATUS_CACHE"
        return 0
      fi

      # Check if Tailscale is available and running
      if command -v tailscale &> /dev/null && tailscale status --json &> /dev/null; then
        TAILSCALE_STATUS_CACHE=$(tailscale status --peers=false 2>/dev/null | grep -E "^\S+\s+" | awk '{print $1}')
        TAILSCALE_STATUS_TIME=$current_time
        echo "$TAILSCALE_STATUS_CACHE"
        return 0
      fi

      return 1
    }

    # Smart host connection function - SSH with optimal settings
    _smart_connect() {
      local hostname="$1"
      shift
      local extra_args=("$@")
      local use_autossh=false
      local use_et=true  # Default to ET

      # Check for connection type flags
      while [[ "$1" =~ ^- ]]; do
        case "$1" in
          -a|--auto)
            use_autossh=true
            use_et=false  # AutoSSH implies SSH
            shift
            ;;
          -e|--et)
            use_et=true
            shift
            ;;
          --ssh)
            # Force SSH instead of ET
            use_et=false
            use_autossh=false
            shift
            ;;
          *)
            break
            ;;
        esac
      done
      extra_args=("$@")

      # Check if host is configured
      if [ -z "''${HOST_IPS[$hostname]}" ]; then
        echo "❌ Unknown host: $hostname"
        echo "💡 Available hosts: ''${(k)HOST_IPS[@]}"
        return 1
      fi

      local local_ip="''${HOST_IPS[$hostname]}"
      local tailscale_name="''${HOST_TAILSCALE[$hostname]}"
      local target_host=""

      # Special case for localhost
      if [ "$local_ip" = "127.0.0.1" ]; then
        echo "🏠 This is the local machine!"
        return 0
      fi

      # Try Tailscale first if configured for this host
      if [ -n "$tailscale_name" ]; then
        local tailscale_hosts
        if tailscale_hosts=$(_get_tailscale_status); then
          if echo "$tailscale_hosts" | grep -q "^$tailscale_name$"; then
            # Quick ping test with very short timeout
            if ping -c 1 -W 1 "$tailscale_name" &> /dev/null; then
              target_host="$tailscale_name"
              echo "🔒 Connecting to $hostname via Tailscale..."
            fi
          fi
        fi
      fi

      # Fall back to local network if Tailscale didn't work
      if [ -z "$target_host" ]; then
        # Quick ping test for local network
        if ping -c 1 -W 1 "$local_ip" &> /dev/null; then
          target_host="$local_ip"
          echo "🏠 Connecting to $hostname via local network..."
        else
          echo "❌ Cannot reach $hostname via Tailscale or local network ($local_ip)"
          echo "💡 Make sure you're on the local network or connected to Tailscale"
          return 1
        fi
      fi

      # Handle command execution vs interactive connection
      if [ ''${#extra_args[@]} -gt 0 ]; then
        # Run command with ET or SSH
        if [ "$use_et" = true ] && command -v et &> /dev/null; then
          # Use ET with -c flag for command execution
          echo "⚡ Executing via Eternal Terminal..."
          et "$target_host:2022" -c "''${extra_args[*]}"
        elif [ "$use_autossh" = true ]; then
          # Use autossh for persistent connection with command
          AUTOSSH_GATETIME=0 autossh -M 0 -t "$target_host" "''${extra_args[@]}"
        else
          ssh -t "$target_host" "''${extra_args[@]}"
        fi
      else
        # Just connect interactively
        # Default to ET if available and not explicitly disabled
        if [ "$use_et" = true ] && command -v et &> /dev/null; then
          # Use Eternal Terminal for persistent low-latency connection
          echo "⚡ Using Eternal Terminal for low-latency persistent connection..."
          et "$target_host:2022"
        elif [ "$use_et" = true ] && ! command -v et &> /dev/null; then
          # ET requested (default) but not available
          echo "❌ Eternal Terminal not available, falling back to SSH..."
          ssh "$target_host"
        elif [ "$use_autossh" = true ]; then
          # Use autossh for persistent interactive connection
          echo "🔄 Using autossh for persistent connection..."
          AUTOSSH_GATETIME=0 autossh -M 0 "$target_host"
        elif command -v kitten &> /dev/null && [ -t 0 ]; then
          # STDIN is a terminal, safe to use kitten
          kitten ssh "$target_host"
        else
          ssh "$target_host"
        fi
      fi
    }

    # Create command for each host
    ultraviolet() {
      _smart_connect ultraviolet "$@"
    }

    bluedesert() {
      _smart_connect bluedesert "$@"
    }

    echelon() {
      _smart_connect echelon "$@"
    }

    cloudbank() {
      _smart_connect cloudbank "$@"
    }

    ninuan() {
      _smart_connect ninuan "$@"
    }

    # Legacy aliases for compatibility
    ultraviolet-ssh() {
      ultraviolet "$@"
    }

    bluedesert-ssh() {
      bluedesert "$@"
    }

    echelon-ssh() {
      echelon "$@"
    }

    # Universal 'ssh-to' command
    ssh-to() {
      if [ $# -lt 1 ]; then
        echo "Usage: ssh-to <hostname> [command]"
        echo "Available hosts: ''${(k)HOST_IPS[@]}"
        return 1
      fi
      _smart_connect "$@"
    }

    # List all configured hosts
    ssh-hosts() {
      echo "🌐 Configured SSH Hosts"
      echo "━━━━━━━━━━━━━━━━━━━━━"
      echo

      local tailscale_hosts
      tailscale_hosts=$(_get_tailscale_status 2>/dev/null || echo "")

      for host in ''${(k)HOST_IPS[@]}; do
        local ip="''${HOST_IPS[$host]}"
        local ts_name="''${HOST_TAILSCALE[$host]}"
        local status="❓"
        local via=""

        # Check connectivity
        if [ "$ip" = "127.0.0.1" ]; then
          status="🏠"
          via="local"
        elif [ -n "$ts_name" ] && echo "$tailscale_hosts" | grep -q "^$ts_name$"; then
          if ping -c 1 -W 1 "$ts_name" &> /dev/null; then
            status="🔒"
            via="tailscale"
          fi
        fi

        if [ "$via" = "" ] && ping -c 1 -W 1 "$ip" &> /dev/null; then
          status="🌐"
          via="local network"
        elif [ "$via" = "" ]; then
          status="❌"
          via="unreachable"
        fi

        printf "%-12s %s %-15s %s\n" "$host" "$status" "$ip" "($via)"
      done

      echo
      echo "Legend: 🏠 local | 🔒 tailscale | 🌐 local network | ❌ unreachable"
      echo
      echo "Connection: Uses Eternal Terminal (ET) by default for low-latency persistent connections"
      echo "For SSH: use --ssh flag (e.g., 'ultraviolet --ssh')"
      echo "For autossh: use -a flag (e.g., 'ultraviolet -a')"
    }

    # Convenient aliases
    alias bd="bluedesert"
  '';
}
