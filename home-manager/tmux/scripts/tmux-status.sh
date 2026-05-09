#!/usr/bin/env bash
# Combined system-monitor widget for tmux's status-right.
#
# Replaces five separate `#(...)` shell-outs (cpu, ram, net, disk, failed-units)
# with a single one. Reads /proc directly — no iostat sample, no upstream
# plugin scripts. Output is cached for $ttl seconds so multi-client redraws
# don't re-run measurements.

set -euo pipefail

cache=/tmp/tmux-status.cache
lock=/tmp/tmux-status.lock
state_cpu=/tmp/tmux-status.cpu.state
state_net=/tmp/tmux-status.net.state
ttl=4

serve_if_fresh() {
  if [[ -f $cache ]]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$cache") ))
    if (( age < ttl )); then
      cat "$cache"
      return 0
    fi
  fi
  return 1
}

serve_if_fresh && exit 0

exec 9>"$lock"
if ! flock -n 9; then
  [[ -f $cache ]] && cat "$cache"
  exit 0
fi
serve_if_fresh && exit 0

# ---------- measurements ----------

read_cpu_pct() {
  # CPU% from a /proc/stat delta against a state file. iowait is counted as
  # idle (matches `top`'s default). First run returns 0.
  local _cpu user nice sys idle iowait _rest
  read -r _cpu user nice sys idle iowait _rest < /proc/stat
  local total=$(( user + nice + sys + idle + iowait ))
  local idle_total=$(( idle + iowait ))
  local prev_total=0 prev_idle=0
  if [[ -f $state_cpu ]]; then
    read -r prev_total prev_idle < "$state_cpu" || true
  fi
  printf '%d %d\n' "$total" "$idle_total" > "$state_cpu"
  local dt=$(( total - prev_total ))
  local di=$(( idle_total - prev_idle ))
  if (( dt <= 0 )); then echo 0; return; fi
  echo $(( (100 * (dt - di)) / dt ))
}

read_ram_pct() {
  local mem_total=0 mem_avail=0 key val _rest
  while read -r key val _rest; do
    case $key in
      MemTotal:)     mem_total=$val ;;
      MemAvailable:) mem_avail=$val ;;
    esac
  done < /proc/meminfo
  if (( mem_total == 0 )); then echo 0; return; fi
  echo $(( (100 * (mem_total - mem_avail)) / mem_total ))
}

read_disk_pct() {
  df --output=pcent / | awk 'NR==2 { gsub(/[ %]/, ""); printf "%s", $0 }'
}

human() {
  local n=$1
  if   (( n < 1024 ));       then printf '%dB' "$n"
  elif (( n < 1048576 ));    then printf '%dK' $(( n / 1024 ))
  elif (( n < 1073741824 )); then printf '%dM' $(( n / 1048576 ))
  else                            printf '%dG' $(( n / 1073741824 ))
  fi
}

read_net_speed() {
  # Sum rx/tx bytes across real interfaces, deltas vs state file. Excludes
  # loopback and virtual interfaces (veth/docker/br/virbr).
  local now rx_curr tx_curr
  now=$(date +%s%N)
  read -r rx_curr tx_curr < <(awk '
    $1 ~ /:$/ {
      iface = $1; sub(/:$/, "", iface)
      if (iface == "lo" || iface ~ /^(veth|docker|br-|virbr)/) next
      rx += $2; tx += $10
    }
    END { print rx+0, tx+0 }
  ' /proc/net/dev)
  local prev_now=0 prev_rx=0 prev_tx=0
  if [[ -f $state_net ]]; then
    read -r prev_now prev_rx prev_tx < "$state_net" || true
  fi
  printf '%s %s %s\n' "$now" "$rx_curr" "$tx_curr" > "$state_net"
  if (( prev_now == 0 )); then printf '↓0 ↑0'; return; fi
  local dt=$(( now - prev_now ))
  if (( dt <= 0 )); then printf '↓0 ↑0'; return; fi
  local rx_rate=$(( (rx_curr - prev_rx) * 1000000000 / dt ))
  local tx_rate=$(( (tx_curr - prev_tx) * 1000000000 / dt ))
  printf '↓%s ↑%s' "$(human "$rx_rate")" "$(human "$tx_rate")"
}

read_failed_units() {
  systemctl --failed --no-legend --plain --state=failed 2>/dev/null | wc -l
}

# ---------- format ----------
# U+E0B6 (powerline rounded-left). Right side is just trailing space drawn in
# the dark bg color, which produces a flat right edge — same visual as the
# previous catppuccin "rounded" status pills.
LSEP=$'\xee\x82\xb6'

pill() {
  local accent=$1 icon=$2 text=$3
  printf '#[fg=%s]%s#[fg=#11111b,bg=%s]%s  #[fg=#cdd6f4,bg=#313244] %s#[fg=#313244] ' \
    "$accent" "$LSEP" "$accent" "$icon" "$text"
}

build_status() {
  local cpu ram disk net failed
  cpu=$(read_cpu_pct)
  ram=$(read_ram_pct)
  disk=$(read_disk_pct)
  net=$(read_net_speed)
  failed=$(read_failed_units)
  pill '#94e2d5' '󰈀' "$net"
  pill '#f9e2af' '' "${cpu}%"
  pill '#cba6f7' '󰍛' "${ram}%"
  pill '#89b4fa' '󰋊' "${disk}%"
  if (( failed > 0 )); then
    pill '#fab387' '󰀦' "$failed"
  fi
}

build_status > "$cache.tmp" && mv "$cache.tmp" "$cache"
cat "$cache"
