#!/usr/bin/env bash
# Combined system-monitor widget for tmux's status-right.
#
# Replaces separate `#(...)` shell-outs (cpu, ram, net, disk I/O, disk usage,
# failed-units) with a single one. Reads /proc and /sys directly — no iostat
# sample, no upstream plugin scripts. Output is cached for $ttl seconds so
# multi-client redraws don't re-run measurements.
#
# Every card keeps an identity accent when healthy and flips to peach (warn)
# or red (crit) under load. Severity is the worst of the card's own metric
# threshold and (where applicable) a PSI "some avg10" threshold — there is no
# separate pressure card, PSI only feeds per-card coloring.

set -euo pipefail

dir=${TMUX_STATUS_DIR:-/tmp}
mkdir -p "$dir"
psi_base=${TMUX_STATUS_PSI:-/proc/pressure}

cache=$dir/tmux-status.cache
lock=$dir/tmux-status.lock
state_cpu=$dir/tmux-status.cpu.state
state_net=$dir/tmux-status.net.state
state_disk=$dir/tmux-status.disk.state
ttl=4

# Delta-metric state files go stale after this many nanoseconds (15s). A
# stale or missing baseline is rebaselined and resampled over ~1s instead of
# rendering a long-window (e.g. multi-hour reattach) average.
stale_ns=$(( 15 * 1000000000 ))

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

# ---------- raw counter readers (no state I/O, no timestamps) ----------

now_ns() { date +%s%N; }

raw_cpu() {
  # busy = user+nice+system+irq+softirq+steal; idle = idle+iowait (matches
  # `top`'s default — iowait is NOT busy).
  local _cpu user nice sys idle iowait irq softirq steal _rest
  read -r _cpu user nice sys idle iowait irq softirq steal _rest < /proc/stat
  local busy=$(( user + nice + sys + irq + softirq + steal ))
  local idle_total=$(( idle + iowait ))
  printf '%d %d\n' "$busy" "$idle_total"
}

raw_net() {
  # Sum rx/tx bytes across real interfaces. Excludes loopback and virtual
  # interfaces (veth/docker/br/virbr).
  awk '
    $1 ~ /:$/ {
      iface = $1; sub(/:$/, "", iface)
      if (iface == "lo" || iface ~ /^(veth|docker|br-|virbr)/) next
      rx += $2; tx += $10
    }
    END { print rx+0, tx+0 }
  ' /proc/net/dev
}

physical_disks() {
  # Top-level /sys/block entries whose resolved device path is NOT under
  # /devices/virtual/ — excludes loop, zram, dm, ram.
  local d resolved
  for d in /sys/block/*; do
    [[ -e $d ]] || continue
    resolved=$(readlink -f "$d" 2>/dev/null) || continue
    case $resolved in
      */devices/virtual/*) continue ;;
    esac
    basename "$d"
  done
}

raw_disk() {
  # Sectors read (field 6) and written (field 10) from /proc/diskstats,
  # ×512 for bytes, summed over physical disks only.
  local devs
  devs=$(physical_disks)
  if [[ -z $devs ]]; then
    printf '0 0\n'
    return
  fi
  awk -v devlist="$devs" '
    BEGIN {
      n = split(devlist, arr, "\n")
      for (i = 1; i <= n; i++) want[arr[i]] = 1
    }
    ($3 in want) { rd += $6; wr += $10 }
    END { printf "%.0f %.0f\n", (rd + 0) * 512, (wr + 0) * 512 }
  ' /proc/diskstats
}

read_load1() {
  awk '{ print $1 }' /proc/loadavg
}

read_mem() {
  local mem_total=0 mem_avail=0 key val _rest
  while read -r key val _rest; do
    case $key in
      MemTotal:)     mem_total=$val ;;
      MemAvailable:) mem_avail=$val ;;
    esac
  done < /proc/meminfo
  printf '%d %d\n' "$mem_total" "$mem_avail"
}

read_disk_pct() {
  df --output=pcent / | awk 'NR==2 { gsub(/[ %]/, ""); printf "%s", $0 }'
}

read_psi() {
  # "some avg10=" value for $1 (cpu/memory/io). 0 if PSI is unavailable —
  # guarded, never aborts under set -e.
  local f="$psi_base/$1" val=""
  if [[ -r $f ]]; then
    val=$(awk '
      $1 == "some" {
        for (i = 2; i <= NF; i++) {
          if ($i ~ /^avg10=/) { sub(/^avg10=/, "", $i); print $i; exit }
        }
      }
    ' "$f" 2>/dev/null || true)
  fi
  printf '%s\n' "${val:-0}"
}

read_failed_units() {
  systemctl --failed --no-legend --plain --state=failed 2>/dev/null | wc -l
}

human() {
  local n=$1
  if   (( n < 1024 ));       then printf '%dB' "$n"
  elif (( n < 1048576 ));    then printf '%dK' $(( n / 1024 ))
  elif (( n < 1073741824 )); then printf '%dM' $(( n / 1048576 ))
  else                            printf '%dG' $(( n / 1073741824 ))
  fi
}

# ---------- state helpers ----------

state_is_stale() {
  # $1 = state file, $2 = now (ns). Echoes 1 (stale/missing) or 0 (fresh).
  local f=$1 now=$2 ts _rest
  if [[ ! -f $f ]]; then
    echo 1
    return
  fi
  read -r ts _rest < "$f" || true
  if [[ -z ${ts:-} ]]; then
    echo 1
    return
  fi
  if (( now - ts > stale_ns )); then
    echo 1
  else
    echo 0
  fi
}

# ---------- shared delta measurement (cpu% + net rate + disk I/O rate) ----------
#
# Single resample path: if ANY of the three delta state files is stale or
# missing, rebaseline all three together, sleep ~1s once, then measure over
# that fresh window. Otherwise measure over the existing (sub-15s) window.
# No sleep in the common (fresh-state) path.

CPU_PCT=0
NET_RX_RATE=0
NET_TX_RATE=0
DISK_RD_RATE=0
DISK_WR_RATE=0

measure_all() {
  local now cpu_stale net_stale disk_stale any_stale
  now=$(now_ns)
  cpu_stale=$(state_is_stale "$state_cpu" "$now")
  net_stale=$(state_is_stale "$state_net" "$now")
  disk_stale=$(state_is_stale "$state_disk" "$now")
  any_stale=0
  if [[ $cpu_stale == 1 || $net_stale == 1 || $disk_stale == 1 ]]; then
    any_stale=1
  fi

  local base_ts cpu_busy0 cpu_idle0 net_rx0 net_tx0 disk_rd0 disk_wr0

  if (( any_stale == 1 )); then
    read -r cpu_busy0 cpu_idle0 < <(raw_cpu)
    read -r net_rx0 net_tx0 < <(raw_net)
    read -r disk_rd0 disk_wr0 < <(raw_disk)
    base_ts=$now
    printf '%s %s %s\n' "$base_ts" "$cpu_busy0" "$cpu_idle0" > "$state_cpu"
    printf '%s %s %s\n' "$base_ts" "$net_rx0" "$net_tx0" > "$state_net"
    printf '%s %s %s\n' "$base_ts" "$disk_rd0" "$disk_wr0" > "$state_disk"
    sleep 1
    now=$(now_ns)
  else
    read -r base_ts cpu_busy0 cpu_idle0 < "$state_cpu"
    read -r _ net_rx0 net_tx0 < "$state_net"
    read -r _ disk_rd0 disk_wr0 < "$state_disk"
  fi

  local cpu_busy1 cpu_idle1 net_rx1 net_tx1 disk_rd1 disk_wr1
  read -r cpu_busy1 cpu_idle1 < <(raw_cpu)
  read -r net_rx1 net_tx1 < <(raw_net)
  read -r disk_rd1 disk_wr1 < <(raw_disk)

  printf '%s %s %s\n' "$now" "$cpu_busy1" "$cpu_idle1" > "$state_cpu"
  printf '%s %s %s\n' "$now" "$net_rx1" "$net_tx1" > "$state_net"
  printf '%s %s %s\n' "$now" "$disk_rd1" "$disk_wr1" > "$state_disk"

  local busy_delta=$(( cpu_busy1 - cpu_busy0 ))
  local idle_delta=$(( cpu_idle1 - cpu_idle0 ))
  local total_delta=$(( busy_delta + idle_delta ))
  if (( total_delta <= 0 )); then
    CPU_PCT=0
  else
    CPU_PCT=$(( (100 * busy_delta) / total_delta ))
  fi

  local window_ns=$(( now - base_ts ))
  if (( window_ns <= 0 )); then window_ns=1000000000; fi

  NET_RX_RATE=$(( (net_rx1 - net_rx0) * 1000000000 / window_ns ))
  NET_TX_RATE=$(( (net_tx1 - net_tx0) * 1000000000 / window_ns ))
  DISK_RD_RATE=$(( (disk_rd1 - disk_rd0) * 1000000000 / window_ns ))
  DISK_WR_RATE=$(( (disk_wr1 - disk_wr0) * 1000000000 / window_ns ))
}

# ---------- severity / coloring ----------

sev_ge() {
  # $1 = value, $2 = warn threshold, $3 = crit threshold -> echoes 0/1/2.
  # awk comparison handles both int and float values uniformly.
  awk -v v="$1" -v w="$2" -v c="$3" 'BEGIN {
    if (v + 0 >= c + 0)      { print 2 }
    else if (v + 0 >= w + 0) { print 1 }
    else                     { print 0 }
  }'
}

max_sev() {
  if (( $1 > $2 )); then printf '%s' "$1"; else printf '%s' "$2"; fi
}

accent_for() {
  # $1 = identity accent, $2 = severity (0/1/2).
  case $2 in
    2) printf '#f38ba8' ;;
    1) printf '#fab387' ;;
    *) printf '%s' "$1" ;;
  esac
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
  measure_all

  local load1 mem_total mem_avail used_kb used_bytes used_pct disk_pct
  load1=$(read_load1)
  read -r mem_total mem_avail < <(read_mem)
  used_kb=$(( mem_total - mem_avail ))
  if (( used_kb < 0 )); then used_kb=0; fi
  used_bytes=$(( used_kb * 1024 ))
  if (( mem_total > 0 )); then
    used_pct=$(( (100 * used_kb) / mem_total ))
  else
    used_pct=0
  fi
  disk_pct=$(read_disk_pct)
  [[ -z $disk_pct ]] && disk_pct=0

  local psi_cpu psi_mem psi_io
  psi_cpu=$(read_psi cpu)
  psi_mem=$(read_psi memory)
  psi_io=$(read_psi io)

  local nproc_n
  nproc_n=$(nproc 2>/dev/null || echo 1)
  (( nproc_n < 1 )) && nproc_n=1
  local load_ratio
  load_ratio=$(awk -v l="$load1" -v n="$nproc_n" 'BEGIN { printf "%.4f", l / n }')

  local sev_cpu sev_ram sev_disk_io sev_disk_usage
  sev_cpu=$(max_sev "$(sev_ge "$load_ratio" 0.7 1.0)" "$(sev_ge "$psi_cpu" 20 50)")
  sev_ram=$(max_sev "$(sev_ge "$used_pct" 75 90)" "$(sev_ge "$psi_mem" 20 50)")
  sev_disk_io=$(sev_ge "$psi_io" 20 50)
  sev_disk_usage=$(sev_ge "$disk_pct" 85 95)

  local net_str disk_io_str failed
  net_str=$(printf '↓%s ↑%s' "$(human "$NET_RX_RATE")" "$(human "$NET_TX_RATE")")
  disk_io_str=$(printf '↓%s ↑%s' "$(human "$DISK_RD_RATE")" "$(human "$DISK_WR_RATE")")
  failed=$(read_failed_units)

  pill '#94e2d5' '󰈀' "$net_str"
  pill "$(accent_for '#f9e2af' "$sev_cpu")" '' "${CPU_PCT}% ${load1}"
  pill "$(accent_for '#cba6f7' "$sev_ram")" '' "$(human "$used_bytes")"
  pill "$(accent_for '#89dceb' "$sev_disk_io")" '󰓅' "$disk_io_str"
  pill "$(accent_for '#89b4fa' "$sev_disk_usage")" '󰋊' "${disk_pct}%"
  if (( failed > 0 )); then
    pill '#fab387' '󰀦' "$failed"
  fi
}

build_status > "$cache.tmp" && mv "$cache.tmp" "$cache"
cat "$cache"
