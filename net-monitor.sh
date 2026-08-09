#!/usr/bin/env bash
#
# net-monitor.sh — lightweight internet health check for video calls & daily work
#
# Pure macOS built-ins only (bash, curl, ping, awk). Nothing to install.
# Samples latency + download + upload on an interval, draws a live text chart,
# and reports p50/p90/p99 for each metric plus a Google Meet readiness verdict.
#
# Usage:
#   ./net-monitor.sh [options]
#
# Options:
#   -d, --duration SEC    total run time in seconds        (default: 20)
#   -i, --interval SEC    seconds between samples          (default: 5)
#   -H, --host HOST       host to ping for latency         (default: 1.1.1.1)
#       --dl-bytes N      bytes to pull per download probe (default: 8000000)
#       --ul-bytes N      bytes to push per upload probe   (default: 3000000)
#       --no-upload       skip the upload probe (faster samples)
#   -h, --help            show this help and exit
#
set -euo pipefail

# ---- defaults ---------------------------------------------------------------
DURATION=20
INTERVAL=5
PING_HOST="1.1.1.1"
DL_BYTES=8000000      # ~8 MB
UL_BYTES=3000000      # ~3 MB
DO_UPLOAD=1
DL_URL="https://speed.cloudflare.com/__down"
UL_URL="https://speed.cloudflare.com/__up"

# Google Meet / daily-work reference thresholds (Mbps down, Mbps up, ms latency)
MEET_DL=3.2
MEET_UL=2.0
MEET_LAT=100

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---- arg parsing ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--duration) DURATION="$2"; shift 2 ;;
    -i|--interval) INTERVAL="$2"; shift 2 ;;
    -H|--host)     PING_HOST="$2"; shift 2 ;;
    --dl-bytes)    DL_BYTES="$2"; shift 2 ;;
    --ul-bytes)    UL_BYTES="$2"; shift 2 ;;
    --no-upload)   DO_UPLOAD=0; shift ;;
    -h|--help)     usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
done

# ---- sample stores ----------------------------------------------------------
LAT_SAMPLES=()   # ms
DL_SAMPLES=()    # Mbps
UL_SAMPLES=()    # Mbps
FAILS=0

# ---- probes -----------------------------------------------------------------

# Latency in ms via 2 quick pings; echoes avg, or "" on failure.
probe_latency() {
  local out
  out=$(ping -c 2 -t 3 "$PING_HOST" 2>/dev/null) || { echo ""; return; }
  # macOS ping summary: round-trip min/avg/max/stddev = a/b/c/d ms
  echo "$out" | awk -F'=' '/round-trip|min\/avg\/max/ {split($2,a,"/"); print a[2]+0}'
}

# Download throughput in Mbps. Echoes value or "" on failure.
probe_download() {
  local speed_bps
  speed_bps=$(curl -s -o /dev/null --max-time "$INTERVAL" \
    -w '%{speed_download}' "${DL_URL}?bytes=${DL_BYTES}" 2>/dev/null) || { echo ""; return; }
  awk -v b="$speed_bps" 'BEGIN { if (b+0 <= 0) print ""; else printf "%.2f", (b*8)/1000000 }'
}

# Upload throughput in Mbps. Echoes value or "" on failure.
probe_upload() {
  local speed_bps
  speed_bps=$(head -c "$UL_BYTES" /dev/zero | curl -s -o /dev/null --max-time "$INTERVAL" \
    -H 'Content-Type: application/octet-stream' --data-binary @- \
    -w '%{speed_upload}' "$UL_URL" 2>/dev/null) || { echo ""; return; }
  awk -v b="$speed_bps" 'BEGIN { if (b+0 <= 0) print ""; else printf "%.2f", (b*8)/1000000 }'
}

# ---- helpers ----------------------------------------------------------------

# percentile: prints the p-th percentile (nearest-rank) of a whitespace list.
percentile() {
  local p="$1"; shift
  [[ $# -eq 0 ]] && { echo "n/a"; return; }
  printf '%s\n' "$@" | sort -n | awk -v p="$p" '
    { v[NR]=$1 }
    END {
      if (NR==0) { print "n/a"; exit }
      rank = p/100 * NR
      idx = int(rank); if (rank > idx) idx++     # ceil for nearest-rank
      if (idx < 1) idx=1; if (idx > NR) idx=NR
      printf "%.2f", v[idx]
    }'
}

# sparkline: renders numbers as unicode bars scaled to their own max.
sparkline() {
  [[ $# -eq 0 ]] && { echo ""; return; }
  printf '%s\n' "$@" | awk '
    { v[NR]=$1; if ($1>mx) mx=$1 }
    END {
      ticks[1]="▁"; ticks[2]="▂"; ticks[3]="▃"; ticks[4]="▄"
      ticks[5]="▅"; ticks[6]="▆"; ticks[7]="▇"; ticks[8]="█"
      if (mx<=0) mx=1
      line=""
      for (i=1;i<=NR;i++) {
        lvl = int(v[i]/mx*7)+1; if (lvl<1) lvl=1; if (lvl>8) lvl=8
        line=line ticks[lvl]
      }
      print line
    }'
}

last_of() { [[ $# -eq 0 ]] && echo "--" || echo "${!#}"; }

draw() {
  local elapsed="$1"
  printf '\033[H\033[2J'   # cursor home + clear screen
  echo "  net-monitor — internet health for calls & daily work"
  echo "  host=$PING_HOST  interval=${INTERVAL}s  elapsed=${elapsed}s / ${DURATION}s  samples=${#LAT_SAMPLES[@]}  fails=${FAILS}"
  echo "  ─────────────────────────────────────────────────────────────"
  echo
  printf "  ⬇  download %7s Mbps  %s\n" "$(last_of "${DL_SAMPLES[@]:-}")" "$(sparkline "${DL_SAMPLES[@]:-}")"
  echo
  if [[ "$DO_UPLOAD" -eq 1 ]]; then
    printf "  ⬆  upload   %7s Mbps  %s\n" "$(last_of "${UL_SAMPLES[@]:-}")" "$(sparkline "${UL_SAMPLES[@]:-}")"
    echo
  fi
  printf "  ⏱  latency  %7s ms    %s\n" "$(last_of "${LAT_SAMPLES[@]:-}")" "$(sparkline "${LAT_SAMPLES[@]:-}")"
  echo
  echo "  ─────────────────────────────────────────────────────────────"
  echo "  sampling…  (Ctrl-C to stop early and see the summary)"
}

# ---- summary ----------------------------------------------------------------
summary() {
  echo
  echo "  net-monitor — summary"
  echo "  host=$PING_HOST  duration=${DURATION}s  interval=${INTERVAL}s  samples=${#LAT_SAMPLES[@]}  failed=${FAILS}"
  echo "  ═════════════════════════════════════════════════════════════"

  local dl50 dl90 dl99 ul50 ul90 ul99 la50 la90 la99
  dl50=$(percentile 50 "${DL_SAMPLES[@]:-}"); dl90=$(percentile 90 "${DL_SAMPLES[@]:-}"); dl99=$(percentile 99 "${DL_SAMPLES[@]:-}")
  ul50=$(percentile 50 "${UL_SAMPLES[@]:-}"); ul90=$(percentile 90 "${UL_SAMPLES[@]:-}"); ul99=$(percentile 99 "${UL_SAMPLES[@]:-}")
  la50=$(percentile 50 "${LAT_SAMPLES[@]:-}"); la90=$(percentile 90 "${LAT_SAMPLES[@]:-}"); la99=$(percentile 99 "${LAT_SAMPLES[@]:-}")

  echo "  over time (${#LAT_SAMPLES[@]} samples, oldest → newest):"
  echo
  printf "  ⬇  download  %s\n" "$(sparkline "${DL_SAMPLES[@]:-}")"
  echo
  [[ "$DO_UPLOAD" -eq 1 ]] && { printf "  ⬆  upload    %s\n" "$(sparkline "${UL_SAMPLES[@]:-}")"; echo; }
  printf "  ⏱  latency   %s\n" "$(sparkline "${LAT_SAMPLES[@]:-}")"
  echo "  ─────────────────────────────────────────────────────────────"
  echo
  printf "  %-18s %10s %10s %10s\n" "metric" "p50" "p90" "p99"
  printf "  %-18s %10s %10s %10s\n" "──────" "───" "───" "───"
  echo
  printf "  %-18s %10s %10s %10s\n" "download (Mbps)" "$dl50" "$dl90" "$dl99"
  echo
  if [[ "$DO_UPLOAD" -eq 1 ]]; then
    printf "  %-18s %10s %10s %10s\n" "upload   (Mbps)" "$ul50" "$ul90" "$ul99"
    echo
  fi
  printf "  %-18s %10s %10s %10s\n" "latency  (ms)"   "$la50" "$la90" "$la99"
  echo "  ═════════════════════════════════════════════════════════════"

  # Verdict: judge against Meet thresholds using p90 (sustained worst-of-typical).
  echo "  Google Meet / daily-work readiness (judged on p90):"
  verdict_line "download" "$dl90" "$MEET_DL" "Mbps" "ge"
  [[ "$DO_UPLOAD" -eq 1 ]] && verdict_line "upload" "$ul90" "$MEET_UL" "Mbps" "ge"
  verdict_line "latency" "$la90" "$MEET_LAT" "ms" "le"
  echo "  ═════════════════════════════════════════════════════════════"
}

# verdict_line label value threshold unit cmp(ge|le)
verdict_line() {
  local label="$1" val="$2" thr="$3" unit="$4" cmp="$5"
  if [[ "$val" == "n/a" ]]; then
    printf "  %-9s  ⚠️  no data\n" "$label"; return
  fi
  local ok
  ok=$(awk -v v="$val" -v t="$thr" -v c="$cmp" 'BEGIN{
    if (c=="ge") print (v>=t)?1:0; else print (v<=t)?1:0 }')
  if [[ "$ok" -eq 1 ]]; then
    printf "  %-9s  ✅  %s %s  (need %s %s %s)\n" "$label" "$val" "$unit" \
      "$([[ $cmp == ge ]] && echo '≥' || echo '≤')" "$thr" "$unit"
  else
    printf "  %-9s  ❌  %s %s  (need %s %s %s)\n" "$label" "$val" "$unit" \
      "$([[ $cmp == ge ]] && echo '≥' || echo '≤')" "$thr" "$unit"
  fi
}

# ---- main loop --------------------------------------------------------------
trap 'summary; exit 0' INT
START=$SECONDS

while (( SECONDS - START < DURATION )); do
  loop_start=$SECONDS

  lat=$(probe_latency)
  dl=$(probe_download)
  ul=""
  [[ "$DO_UPLOAD" -eq 1 ]] && ul=$(probe_upload)

  [[ -n "$lat" ]] && LAT_SAMPLES+=("$lat")
  [[ -n "$dl"  ]] && DL_SAMPLES+=("$dl")
  [[ -n "$ul"  ]] && UL_SAMPLES+=("$ul")
  { [[ -z "$dl" ]] || [[ -z "$lat" ]]; } && FAILS=$((FAILS+1))

  draw "$((SECONDS - START))"

  # Pace to the interval (probes may have already consumed some/all of it).
  spent=$((SECONDS - loop_start))
  (( spent < INTERVAL )) && sleep "$((INTERVAL - spent))"
done

summary
