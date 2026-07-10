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

if [[ -n ${TMUX_STATUS_DIR:-} ]]; then
  dir=$TMUX_STATUS_DIR
else
  dir=${XDG_RUNTIME_DIR:-/tmp}/tmux-status-$(id -u)
fi
mkdir -p "$dir"
# Fixed, guessable state-file names live under $dir (lock/cache/*.state). A
# world-writable parent (the /tmp fallback) lets an attacker pre-create $dir
# themselves before we ever run, which mkdir -p would silently accept. Refuse
# to operate on a directory we don't own instead of writing into (or
# chmod'ing) something an attacker controls. Reject a symlink outright first,
# so the guarantee doesn't rest implicitly on stat(1) not dereferencing.
if [[ -L $dir ]]; then
  echo "tmux-status: refusing to use $dir (symlink)" >&2
  exit 1
fi
if [[ $(stat -c %u "$dir") == "$(id -u)" ]]; then
  chmod 700 "$dir"
else
  echo "tmux-status: refusing to use $dir (not owned by current user)" >&2
  exit 1
fi
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
    printf '%s\n' "${d##*/}"
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

is_uint() {
  # $1 matches an unsigned integer literal — the only shape safe to feed
  # into bash arithmetic. A planted non-numeric first token (e.g.
  # `a[$(cmd)]`) in a state file fails this and is treated as missing data.
  [[ $1 =~ ^[0-9]+$ ]]
}

state_is_stale() {
  # $1 = state file, $2 = now (ns). Echoes 1 (stale/missing) or 0 (fresh).
  local f=$1 now=$2 ts _rest
  if [[ ! -f $f ]]; then
    echo 1
    return
  fi
  read -r ts _rest < "$f" || true
  if [[ -z ${ts:-} ]] || ! is_uint "$ts"; then
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

  if (( any_stale == 0 )); then
    read -r base_ts cpu_busy0 cpu_idle0 < "$state_cpu"
    read -r _ net_rx0 net_tx0 < "$state_net"
    read -r _ disk_rd0 disk_wr0 < "$state_disk"
    # Defense in depth: even though state_is_stale already validated the
    # timestamp column, every numeric field that reaches arithmetic below
    # must be validated too — a planted non-numeric baseline counter is
    # just as dangerous as a planted timestamp. Any bad field forces a
    # rebaseline instead of reaching `(( ))`.
    local v
    for v in "$base_ts" "$cpu_busy0" "$cpu_idle0" "$net_rx0" "$net_tx0" "$disk_rd0" "$disk_wr0"; do
      if ! is_uint "$v"; then
        any_stale=1
        break
      fi
    done
  fi

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

  # Scale-and-divide in awk (double precision) instead of bash 64-bit
  # arithmetic: `delta * 1e9` overflows a signed 64-bit intermediate once a
  # window's byte/sector delta exceeds ~8.59 GiB (fires under heavy disk
  # I/O), wrapping negative and corrupting human()'s output. One awk call
  # computes all four rates together.
  read -r NET_RX_RATE NET_TX_RATE DISK_RD_RATE DISK_WR_RATE < <(awk \
    -v rx1="$net_rx1" -v rx0="$net_rx0" \
    -v tx1="$net_tx1" -v tx0="$net_tx0" \
    -v rd1="$disk_rd1" -v rd0="$disk_rd0" \
    -v wr1="$disk_wr1" -v wr0="$disk_wr0" \
    -v w="$window_ns" '
    BEGIN {
      printf "%.0f %.0f %.0f %.0f\n",
        (rx1 - rx0) * 1000000000 / w,
        (tx1 - tx0) * 1000000000 / w,
        (rd1 - rd0) * 1000000000 / w,
        (wr1 - wr0) * 1000000000 / w
    }')
}

# ---------- severity / coloring ----------

# severity_awk: single awk invocation replacing the former per-metric
# sev_ge (×6 forks) + max_sev (×2 forks) + load_ratio awk + three read_psi
# forks (each its own [[ -r ]] test + awk). Reads the three PSI files
# itself (missing/unreadable -> 0, matching read_psi's degrade-gracefully
# behavior) and emits: sev_cpu sev_ram sev_disk_io sev_disk_usage
# load_round (load1 rounded to nearest integer, for the CPU card's N/nproc
# display). Severity is the worst of the metric's own threshold and (where
# applicable) its PSI threshold — identical semantics to the old sev_ge/
# max_sev pairing.
severity_awk() {
  awk \
    -v load1="$1" -v nproc="$2" -v used_pct="$3" -v disk_pct="$4" \
    -v psi_cpu_f="$5" -v psi_mem_f="$6" -v psi_io_f="$7" '
  function read_psi_val(f,    line, i, n, parts, val) {
    val = 0
    while ((getline line < f) > 0) {
      if (line ~ /^some /) {
        n = split(line, parts, " ")
        for (i = 1; i <= n; i++) {
          if (parts[i] ~ /^avg10=/) {
            val = substr(parts[i], index(parts[i], "=") + 1) + 0
            break
          }
        }
        break
      }
    }
    close(f)
    return val
  }
  function sev(v, w, c) {
    if (v + 0 >= c + 0)      { return 2 }
    else if (v + 0 >= w + 0) { return 1 }
    else                     { return 0 }
  }
  function maxi(a, b) { return (a > b) ? a : b }
  BEGIN {
    psi_cpu = read_psi_val(psi_cpu_f)
    psi_mem = read_psi_val(psi_mem_f)
    psi_io  = read_psi_val(psi_io_f)
    load_ratio = (nproc + 0 > 0) ? load1 / nproc : 0

    sev_cpu        = maxi(sev(load_ratio, 0.7, 1.0), sev(psi_cpu, 20, 50))
    sev_ram        = maxi(sev(used_pct, 75, 90), sev(psi_mem, 20, 50))
    sev_disk_io    = sev(psi_io, 20, 50)
    sev_disk_usage = sev(disk_pct, 85, 95)
    load_round     = sprintf("%.0f", load1)

    printf "%d %d %d %d %s\n", sev_cpu, sev_ram, sev_disk_io, sev_disk_usage, load_round
  }'
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

  local nproc_n
  nproc_n=$(nproc 2>/dev/null || echo 1)
  (( nproc_n < 1 )) && nproc_n=1

  local sev_cpu sev_ram sev_disk_io sev_disk_usage load_round
  read -r sev_cpu sev_ram sev_disk_io sev_disk_usage load_round < <(severity_awk \
    "$load1" "$nproc_n" "$used_pct" "$disk_pct" \
    "$psi_base/cpu" "$psi_base/memory" "$psi_base/io")

  local net_str disk_io_str failed
  net_str=$(printf '↓%s ↑%s' "$(human "$NET_RX_RATE")" "$(human "$NET_TX_RATE")")
  disk_io_str=$(printf '↓%s ↑%s' "$(human "$DISK_RD_RATE")" "$(human "$DISK_WR_RATE")")
  failed=$(read_failed_units)

  pill '#94e2d5' '󰈀' "$net_str"
  pill "$(accent_for '#f9e2af' "$sev_cpu")" '' "${CPU_PCT}% ${load_round}/${nproc_n}"
  pill "$(accent_for '#cba6f7' "$sev_ram")" '' "$(human "$used_bytes")"
  pill "$(accent_for '#89dceb' "$sev_disk_io")" '󰓅' "$disk_io_str"
  pill "$(accent_for '#89b4fa' "$sev_disk_usage")" '󰋊' "${disk_pct}%"
  if (( failed > 0 )); then
    pill '#fab387' '󰀦' "$failed"
  fi
}

build_status > "$cache.tmp" && mv "$cache.tmp" "$cache"
cat "$cache"
