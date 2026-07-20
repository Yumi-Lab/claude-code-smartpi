#!/usr/bin/env bash
# How many Claude Code agents can a Smart Pi One really run at once?
#
# The ceiling is RAM: max simultaneous ≈ MemAvailable / per-process-RSS. This harness
# measures both, on the real board, and then proves the daemon's bounded-concurrency
# model (N queued jobs drained K-at-a-time) keeps RAM flat.
#
#   ./agents-loadtest.sh rss                 # Phase A: peak RSS of one claude runtime
#   ./agents-loadtest.sh ramp [MAXK] [PROMPT]# Phase B: ramp REAL concurrent `claude -p` agents
#   ./agents-loadtest.sh daemon [LIB] [N] [K]# Phase C: daemon semaphore — N jobs, K live
#
# Phase B makes real API calls (tiny prompts). Needs a signed-in claude. It aborts a
# rung the moment MemAvailable drops under FLOOR_MB so it never freezes the board.
set -uo pipefail
FLOOR_MB="${FLOOR_MB:-70}"        # never let free memory drop below this
CLAUDE="${CLAUDE:-claude}"

avail_mb() { awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo; }
swap_mb()  { free -m | awk '/Swap:/{print $3}'; }

peak_rss_mb() { # runs "$@" in bg, polls VmHWM until exit, echoes peak MB
  "$@" >/dev/null 2>&1 & local p=$! peak=0 v
  while kill -0 "$p" 2>/dev/null; do
    v=$(awk '/VmHWM/{print $2}' /proc/$p/status 2>/dev/null || true)
    [ -n "${v:-}" ] && [ "$v" -gt "$peak" ] && peak=$v
    sleep 0.05
  done
  echo $((peak/1024))
}

phase_rss() {
  echo "== Phase A — RSS pic d'UN runtime claude =="
  echo "  MemAvailable départ : $(avail_mb) Mo"
  local r; r=$(peak_rss_mb $CLAUDE --version)
  echo "  claude --version → VmHWM pic = ${r} Mo/process"
  echo "  → plafond théorique ≈ $(( $(avail_mb) / (r>0?r:1) )) agents résidents simultanés"
}

phase_ramp() {
  local maxk="${1:-6}" prompt="${2:-Reply with exactly: OK}"
  echo "== Phase B — montée en charge : VRAIS agents concurrents (claude -p) =="
  printf '  %-4s %-9s %-9s %-8s %-7s %-8s\n' K min_avail swapΔ wall_s ok fail
  local base_swap; base_swap=$(swap_mb)
  for ((k=1;k<=maxk;k++)); do
    local a; a=$(avail_mb)
    if [ "$a" -lt "$FLOOR_MB" ]; then echo "  ⚠ MemAvailable ${a}Mo < ${FLOOR_MB}Mo — arrêt sûr avant K=$k"; break; fi
    local t0 minav=99999 ok=0 fail=0 pids=() rc
    t0=$(date +%s)
    for ((i=0;i<k;i++)); do
      ( $CLAUDE -p "$prompt" >/dev/null 2>&1 ) & pids+=($!)
    done
    # échantillonne la RAM pendant que les agents tournent
    while :; do
      local alive=0; for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
      [ "$alive" = 0 ] && break
      local av; av=$(avail_mb); [ "$av" -lt "$minav" ] && minav=$av
      sleep 0.2
    done
    for p in "${pids[@]}"; do if wait "$p"; then ok=$((ok+1)); else fail=$((fail+1)); fi; done
    local wall=$(( $(date +%s) - t0 )) sd=$(( $(swap_mb) - base_swap ))
    printf '  %-4s %-9s %-9s %-8s %-7s %-8s\n' "$k" "${minav}Mo" "${sd}Mo" "${wall}s" "$ok" "$fail"
    [ "$minav" -lt "$FLOOR_MB" ] && { echo "  → plancher RAM atteint à K=$k (min ${minav}Mo) — c'est le plafond réel"; break; }
  done
}

phase_daemon() {
  local lib="${1:?usage: daemon <LIB_dir> [N] [K]}" n="${2:-12}" k="${3:-3}"
  echo "== Phase C — daemon : $n jobs, plafond K=$k simultanés =="
  export CLAUDE_SOCK="/tmp/claude-loadtest.sock" CLAUDE_MAX_CONCURRENT="$k" CLAUDE_IDLE_MS=1500 CLAUDE_DAEMON_DEBUG=1
  rm -f "$CLAUDE_SOCK"
  local t0; t0=$(date +%s) minav=99999
  local pids=()
  for ((i=0;i<n;i++)); do ( echo "" | node "$lib/claude-client.mjs" -p "Reply with: J$i" >/dev/null 2>&1 ) & pids+=($!); done
  while :; do local alive=0; for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done; [ "$alive" = 0 ] && break
    local av; av=$(avail_mb); [ "$av" -lt "$minav" ] && minav=$av; sleep 0.2; done
  local ok=0; for p in "${pids[@]}"; do wait "$p" && ok=$((ok+1)); done
  echo "  $ok/$n jobs terminés, min MemAvailable=${minav}Mo, mur=$(( $(date +%s)-t0 ))s"
  sleep 2; [ -S "$CLAUDE_SOCK" ] && echo "  daemon encore là" || echo "  ✅ daemon auto-éteint (socket nettoyé)"
}

case "${1:-rss}" in
  rss)    phase_rss ;;
  ramp)   phase_ramp "${2:-6}" "${3:-Reply with exactly: OK}" ;;
  daemon) phase_daemon "${2:-}" "${3:-12}" "${4:-3}" ;;
  *) echo "usage: $0 {rss|ramp [MAXK] [PROMPT]|daemon <LIB> [N] [K]}"; exit 1 ;;
esac
