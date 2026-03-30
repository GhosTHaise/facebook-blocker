#!/bin/bash
# ============================================================
#  ytblock.sh — Schedule-aware YouTube blocker via /etc/hosts
#
#  Modes
#  ─────
#  schedule   Apply a recurring daily window (or two windows)
#             The daemon checks every minute and blocks/unblocks
#             automatically.  Restarts survive reboots if you add
#             the cronjob (see --install-cron).
#
#  for        Block YouTube right now for a fixed duration,
#             then automatically unblock.
#
#  block      Block immediately (no timer).
#  unblock    Unblock immediately.
#  status     Show current state + active schedule.
#  reset      Unblock and wipe saved schedule.
#
#  Usage examples
#  ──────────────
#  # Default two-window schedule (08:00-12:00 and 13:00-17:30), weekdays only
#  sudo ./ytblock.sh schedule
#
#  # One window, including weekends
#  sudo ./ytblock.sh schedule --from 09:00 --to 18:00 --weekends
#
#  # Two custom windows
#  sudo ./ytblock.sh schedule --from 08:00 --to 12:00 \
#                             --from2 14:00 --to2 18:00 --no-weekends
#
#  # Block for exactly 1 hour right now
#  sudo ./ytblock.sh for --duration 1h
#
#  # Block for 45 minutes right now
#  sudo ./ytblock.sh for --duration 45m
#
#  # One-shot block/unblock
#  sudo ./ytblock.sh block
#  sudo ./ytblock.sh unblock
#
#  # Run scheduler as background daemon
#  sudo ./ytblock.sh schedule --daemon
#
#  # Install a @reboot + minutely cron entry so the scheduler
#  # survives reboots automatically
#  sudo ./ytblock.sh schedule --install-cron
# ============================================================

set -euo pipefail

# ── Targets ──────────────────────────────────────────────────
DOMAINS=(
  "youtube.com"
  "www.youtube.com"
  "m.youtube.com"
  "youtu.be"
  "youtube-nocookie.com"
  "www.youtube-nocookie.com"
  "yt3.ggpht.com"           # YouTube thumbnails / avatars
  "ytimg.com"               # YouTube images (breaks player)
  "i.ytimg.com"
  "s.ytimg.com"
)

# ── Config ───────────────────────────────────────────────────
REDIRECT_IP="127.0.0.1"
HOSTS_FILE="/etc/hosts"
MARKER="# managed-by-ytblock.sh"
STATE_DIR="/var/lib/ytblock"
SCHEDULE_FILE="$STATE_DIR/schedule.conf"
PID_FILE="/var/run/ytblock.pid"
LOG_FILE="/var/log/ytblock.log"

# ── Defaults ─────────────────────────────────────────────────
DEFAULT_FROM1="08:00"
DEFAULT_TO1="12:00"
DEFAULT_FROM2="13:00"
DEFAULT_TO2="17:30"
DEFAULT_WEEKENDS="no"     # "yes" | "no"

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─────────────────────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}ytblock.sh${RESET} — Schedule-aware YouTube blocker

${BOLD}MODES${RESET}
  ${CYAN}schedule${RESET}   Set up / run a recurring daily block schedule
  ${CYAN}for${RESET}        Block YouTube for a fixed duration right now
  ${CYAN}block${RESET}      Block YouTube immediately (permanent until unblock)
  ${CYAN}unblock${RESET}    Remove the block immediately
  ${CYAN}status${RESET}     Show block state and active schedule
  ${CYAN}reset${RESET}      Unblock and delete saved schedule

${BOLD}SCHEDULE OPTIONS${RESET}
  --from HH:MM          First window start   (default: $DEFAULT_FROM1)
  --to   HH:MM          First window end     (default: $DEFAULT_TO1)
  --from2 HH:MM         Second window start  (default: $DEFAULT_FROM2)
  --to2   HH:MM         Second window end    (default: $DEFAULT_TO2)
  --no-second-window    Disable the second window
  --weekends            Also apply on Saturday & Sunday
  --no-weekends         Skip Saturday & Sunday (default)
  --daemon              Fork into the background and run forever
  --install-cron        Add cron entries so the scheduler auto-starts

${BOLD}DURATION OPTIONS (for "for" mode)${RESET}
  --duration VALUE      e.g. 30m  1h  90m  2h30m

${BOLD}EXAMPLES${RESET}
  sudo $0 schedule                              # default two-window, no weekends
  sudo $0 schedule --from 09:00 --to 17:00 --no-second-window --weekends
  sudo $0 schedule --from 08:00 --to 12:00 --from2 14:00 --to2 18:00
  sudo $0 schedule --daemon
  sudo $0 for --duration 1h
  sudo $0 for --duration 45m
  sudo $0 block
  sudo $0 unblock
  sudo $0 status
  sudo $0 reset
EOF
  exit 1
}

require_root() {
  [[ "$EUID" -eq 0 ]] || {
    echo -e "${RED}✗ Run as root: sudo $0 $*${RESET}"
    exit 1
  }
}

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null || true
  echo -e "$*"
}

# ── Host manipulation ─────────────────────────────────────────
is_blocked() {
  grep -q "${MARKER}" "$HOSTS_FILE" 2>/dev/null
}

do_block() {
  if ! is_blocked; then
    for domain in "${DOMAINS[@]}"; do
      echo "${REDIRECT_IP} ${domain} ${MARKER}" >> "$HOSTS_FILE"
    done
    log "${RED}🔒 YouTube blocked.${RESET}"
  fi
}

do_unblock() {
  if is_blocked; then
    sed -i "/${MARKER}/d" "$HOSTS_FILE"
    log "${GREEN}🔓 YouTube unblocked.${RESET}"
  fi
}

# ── Time helpers ──────────────────────────────────────────────
# Convert HH:MM to minutes-since-midnight
hhmm_to_min() {
  local h m
  IFS=: read -r h m <<< "$1"
  echo $(( 10#$h * 60 + 10#$m ))
}

# Parse duration strings like 1h, 45m, 2h30m → seconds
parse_duration() {
  local raw="$1" secs=0 h=0 m=0
  if [[ "$raw" =~ ^([0-9]+)h([0-9]+)m$ ]]; then
    h="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"
  elif [[ "$raw" =~ ^([0-9]+)h$ ]]; then
    h="${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^([0-9]+)m$ ]]; then
    m="${BASH_REMATCH[1]}"
  else
    echo -e "${RED}✗ Unrecognised duration: $raw  (use e.g. 1h, 45m, 2h30m)${RESET}"
    exit 1
  fi
  secs=$(( h*3600 + m*60 ))
  [[ "$secs" -gt 0 ]] || { echo -e "${RED}✗ Duration must be > 0.${RESET}"; exit 1; }
  echo "$secs"
}

now_min() {
  date +%H:%M | { IFS=: read h m; echo $(( 10#$h * 60 + 10#$m )); }
}

is_weekend() {
  local dow; dow=$(date +%u)   # 1=Mon … 7=Sun
  [[ "$dow" -ge 6 ]]
}

# ── Schedule persistence ──────────────────────────────────────
save_schedule() {
  mkdir -p "$STATE_DIR"
  cat > "$SCHEDULE_FILE" <<EOF
FROM1=$1
TO1=$2
FROM2=$3
TO2=$4
SECOND_WINDOW=$5
WEEKENDS=$6
EOF
  log "${CYAN}Schedule saved → $SCHEDULE_FILE${RESET}"
}

load_schedule() {
  [[ -f "$SCHEDULE_FILE" ]] || {
    echo -e "${YELLOW}⚠ No saved schedule. Run: sudo $0 schedule${RESET}"
    exit 1
  }
  # shellcheck source=/dev/null
  source "$SCHEDULE_FILE"
}

# ─────────────────────────────────────────────────────────────
#  Commands
# ─────────────────────────────────────────────────────────────

cmd_block() {
  require_root
  do_block
}

cmd_unblock() {
  require_root
  do_unblock
}

cmd_status() {
  echo -e "${BOLD}── YouTube Blocker Status ──────────────────────${RESET}"
  if is_blocked; then
    echo -e "  Blocked : ${RED}YES${RESET}"
  else
    echo -e "  Blocked : ${GREEN}no${RESET}"
  fi

  if [[ -f "$SCHEDULE_FILE" ]]; then
    source "$SCHEDULE_FILE"
    echo -e "\n  ${BOLD}Saved schedule:${RESET}"
    echo -e "  Window 1  : ${FROM1} → ${TO1}"
    if [[ "${SECOND_WINDOW:-yes}" == "yes" ]]; then
      echo -e "  Window 2  : ${FROM2} → ${TO2}"
    else
      echo -e "  Window 2  : (disabled)"
    fi
    echo -e "  Weekends  : ${WEEKENDS:-no}"
  else
    echo -e "\n  ${YELLOW}No saved schedule.${RESET}"
  fi

  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo -e "  Daemon    : running (PID $(cat "$PID_FILE"))"
  else
    echo -e "  Daemon    : ${YELLOW}not running${RESET}"
  fi
}

cmd_reset() {
  require_root
  do_unblock
  rm -f "$SCHEDULE_FILE" "$PID_FILE"
  echo -e "${GREEN}✓ YouTube unblocked and schedule wiped.${RESET}"
}

# ── "for" mode: block for a fixed duration ────────────────────
cmd_for() {
  require_root
  local duration=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --duration) duration="$2"; shift 2 ;;
      *) echo -e "${RED}Unknown option: $1${RESET}"; usage ;;
    esac
  done

  [[ -n "$duration" ]] || { echo -e "${RED}✗ --duration required.${RESET}"; usage; }
  local secs; secs=$(parse_duration "$duration")

  do_block

  local end_ts=$(( $(date +%s) + secs ))
  local human_end; human_end=$(date -d "@$end_ts" '+%H:%M:%S' 2>/dev/null \
                               || date -r "$end_ts" '+%H:%M:%S' 2>/dev/null)

  echo -e "  ${BOLD}YouTube blocked for ${duration}${RESET} — unblocking at ${human_end}"
  echo -e "  (sleeping in background; PID $$)"

  # Background waiter
  (
    sleep "$secs"
    do_unblock
    log "${GREEN}✓ Fixed-duration block expired — YouTube unblocked.${RESET}"
  ) &
  disown
}

# ── schedule daemon loop ──────────────────────────────────────
run_scheduler() {
  local from1 to1 from2 to2 second_window weekends
  load_schedule
  from1="$FROM1"; to1="$TO1"
  from2="$FROM2"; to2="$TO2"
  second_window="${SECOND_WINDOW:-yes}"
  weekends="${WEEKENDS:-no}"

  echo $$ > "$PID_FILE"
  log "${BOLD}⏱  Scheduler running (PID $$)${RESET}"
  log "   Window 1 : $from1 → $to1"
  [[ "$second_window" == "yes" ]] && log "   Window 2 : $from2 → $to2"
  log "   Weekends : $weekends"

  local from1_m; from1_m=$(hhmm_to_min "$from1")
  local to1_m;   to1_m=$(hhmm_to_min "$to1")
  local from2_m; from2_m=$(hhmm_to_min "$from2")
  local to2_m;   to2_m=$(hhmm_to_min "$to2")

  while true; do
    local now; now=$(now_min)

    # Weekend check
    local skip=0
    if is_weekend && [[ "$weekends" == "no" ]]; then
      skip=1
    fi

    local should_block=0
    if [[ "$skip" -eq 0 ]]; then
      # Window 1
      if (( now >= from1_m && now < to1_m )); then
        should_block=1
      fi
      # Window 2
      if [[ "$second_window" == "yes" ]] && (( now >= from2_m && now < to2_m )); then
        should_block=1
      fi
    fi

    if [[ "$should_block" -eq 1 ]]; then
      do_block
    else
      do_unblock
    fi

    sleep 60
  done
}

# ── "schedule" command: parse args, save, optionally daemonise ─
cmd_schedule() {
  require_root

  local from1="$DEFAULT_FROM1" to1="$DEFAULT_TO1"
  local from2="$DEFAULT_FROM2" to2="$DEFAULT_TO2"
  local second_window="yes"
  local weekends="$DEFAULT_WEEKENDS"
  local daemon=0
  local install_cron=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)              from1="$2";         shift 2 ;;
      --to)                to1="$2";           shift 2 ;;
      --from2)             from2="$2";         shift 2 ;;
      --to2)               to2="$2";           shift 2 ;;
      --no-second-window)  second_window="no"; shift   ;;
      --weekends)          weekends="yes";     shift   ;;
      --no-weekends)       weekends="no";      shift   ;;
      --daemon)            daemon=1;           shift   ;;
      --install-cron)      install_cron=1;     shift   ;;
      *) echo -e "${RED}Unknown option: $1${RESET}"; usage ;;
    esac
  done

  # Validate HH:MM format
  local re='^([01][0-9]|2[0-3]):[0-5][0-9]$'
  for t in "$from1" "$to1" "$from2" "$to2"; do
    [[ "$t" =~ $re ]] || {
      echo -e "${RED}✗ Invalid time: $t  (expected HH:MM)${RESET}"
      exit 1
    }
  done

  save_schedule "$from1" "$to1" "$from2" "$to2" "$second_window" "$weekends"

  # ── Install cron ─────────────────────────────────────────────
  if [[ "$install_cron" -eq 1 ]]; then
    local script_path; script_path="$(realpath "$0")"
    # Remove old entries
    crontab -l 2>/dev/null | grep -v "ytblock.sh" | crontab - || true
    # Add: run every minute + at reboot
    (
      crontab -l 2>/dev/null || true
      echo "* * * * * root $script_path _tick >> $LOG_FILE 2>&1"
      echo "@reboot    root $script_path _tick >> $LOG_FILE 2>&1"
    ) | crontab -
    echo -e "${GREEN}✓ Cron entries installed. Scheduler will run every minute.${RESET}"
    return
  fi

  # ── Daemon mode ──────────────────────────────────────────────
  if [[ "$daemon" -eq 1 ]]; then
    # Kill previous daemon if any
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      kill "$(cat "$PID_FILE")" && echo -e "${YELLOW}↺ Stopped previous daemon.${RESET}"
    fi
    nohup "$0" _run_scheduler >> "$LOG_FILE" 2>&1 &
    disown
    echo -e "${GREEN}✓ Scheduler daemon started (PID $!). Logs: $LOG_FILE${RESET}"
  else
    # Foreground mode
    run_scheduler
  fi
}

# Internal: one-shot tick for cron usage
cmd_tick() {
  load_schedule
  local from1="$FROM1" to1="$TO1" from2="$FROM2" to2="$TO2"
  local second_window="${SECOND_WINDOW:-yes}"
  local weekends="${WEEKENDS:-no}"

  local from1_m; from1_m=$(hhmm_to_min "$from1")
  local to1_m;   to1_m=$(hhmm_to_min "$to1")
  local from2_m; from2_m=$(hhmm_to_min "$from2")
  local to2_m;   to2_m=$(hhmm_to_min "$to2")
  local now;     now=$(now_min)

  local skip=0
  is_weekend && [[ "$weekends" == "no" ]] && skip=1

  local should_block=0
  if [[ "$skip" -eq 0 ]]; then
    (( now >= from1_m && now < to1_m )) && should_block=1
    if [[ "$second_window" == "yes" ]] && (( now >= from2_m && now < to2_m )); then
      should_block=1
    fi
  fi

  if [[ "$should_block" -eq 1 ]]; then do_block; else do_unblock; fi
}

# ─────────────────────────────────────────────────────────────
#  Main dispatcher
# ─────────────────────────────────────────────────────────────
ACTION="${1:-}"
shift 2>/dev/null || true

case "$ACTION" in
  schedule)       cmd_schedule "$@" ;;
  for)            cmd_for      "$@" ;;
  block)          cmd_block ;;
  unblock)        cmd_unblock ;;
  status)         cmd_status ;;
  reset)          cmd_reset ;;
  _run_scheduler) run_scheduler ;;   # internal: daemon entry point
  _tick)          cmd_tick ;;        # internal: cron entry point
  *)              usage ;;
esac