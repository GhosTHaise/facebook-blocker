#!/bin/bash
# ============================================================
#  block_youtube.sh — Schedule-aware YouTube blocker via /etc/hosts
#
#  Fixes applied (v2):
#    • Cron syntax: removed bogus "root" field from user crontab
#    • reset: now kills daemon + removes cron entries
#    • /etc/hosts: atomic write via temp file (crash-safe)
#    • "for" mode: unblock deadline written to disk so a reboot
#      can still honour it via the _tick / systemd timer path
#    • Systemd: --install-systemd installs a proper .service +
#      .timer instead of the bash-daemon / cron approach
#
#  Modes
#  ─────
#  schedule        Apply a recurring daily window (or two windows).
#                  Use --install-systemd (recommended) or --install-cron
#                  to survive reboots.
#
#  for             Block YouTube right now for a fixed duration,
#                  then automatically unblock (reboot-safe with systemd).
#
#  block           Block immediately (no timer).
#  unblock         Unblock immediately.
#  status          Show current state + active schedule.
#  reset           Unblock, stop daemon, remove cron/systemd, wipe state.
#
#  Usage examples
#  ──────────────
#  # Default two-window schedule (08:00-12:00 and 13:00-17:30), weekdays only
#  sudo ./block_youtube.sh schedule
#
#  # Install as a systemd timer (recommended — survives reboots)
#  sudo ./block_youtube.sh schedule --from 08:00 --to 12:00 \
#                             --from2 13:00 --to2 17:30 \
#                             --install-systemd
#
#  # Install via cron (fallback if systemd unavailable)
#  sudo ./block_youtube.sh schedule --install-cron
#
#  # Block for exactly 1 hour right now
#  sudo ./block_youtube.sh for --duration 1h
#
#  # Block for 45 minutes right now
#  sudo ./block_youtube.sh for --duration 45m
#
#  # One-shot block/unblock
#  sudo ./block_youtube.sh block
#  sudo ./block_youtube.sh unblock
#
#  # Full teardown
#  sudo ./block_youtube.sh reset
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
  "yt3.ggpht.com"
  "ytimg.com"
  "i.ytimg.com"
  "s.ytimg.com"
)

# ── Config ───────────────────────────────────────────────────
REDIRECT_IP="127.0.0.1"
HOSTS_FILE="/etc/hosts"
MARKER="# managed-by-block_youtube.sh"
STATE_DIR="/var/lib/ytblock"
SCHEDULE_FILE="$STATE_DIR/schedule.conf"
FOR_DEADLINE_FILE="$STATE_DIR/for_deadline.conf"
PID_FILE="/var/run/ytblock.pid"
LOG_FILE="/var/log/ytblock.log"
SYSTEMD_SERVICE="/etc/systemd/system/ytblock.service"
SYSTEMD_TIMER="/etc/systemd/system/ytblock.timer"

# ── Defaults ─────────────────────────────────────────────────
DEFAULT_FROM1="08:00"
DEFAULT_TO1="12:00"
DEFAULT_FROM2="13:00"
DEFAULT_TO2="17:30"
DEFAULT_WEEKENDS="no"

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─────────────────────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}block_youtube.sh${RESET} — Schedule-aware YouTube blocker (v2)

${BOLD}MODES${RESET}
  ${CYAN}schedule${RESET}   Set up a recurring daily block schedule
  ${CYAN}for${RESET}        Block YouTube for a fixed duration right now
  ${CYAN}block${RESET}      Block YouTube immediately (permanent until unblock)
  ${CYAN}unblock${RESET}    Remove the block immediately
  ${CYAN}status${RESET}     Show block state and active schedule
  ${CYAN}reset${RESET}      Full teardown: unblock + stop daemon + remove cron/systemd

${BOLD}SCHEDULE OPTIONS${RESET}
  --from HH:MM          First window start    (default: $DEFAULT_FROM1)
  --to   HH:MM          First window end      (default: $DEFAULT_TO1)
  --from2 HH:MM         Second window start   (default: $DEFAULT_FROM2)
  --to2   HH:MM         Second window end     (default: $DEFAULT_TO2)
  --no-second-window    Disable the second window
  --weekends            Also apply on Saturday & Sunday
  --no-weekends         Skip Saturday & Sunday (default)
  --install-systemd     Install systemd .service + .timer (recommended)
  --install-cron        Install cron job (fallback if no systemd)
  --daemon              Run as a background bash daemon (least preferred)

${BOLD}DURATION OPTIONS  ("for" mode)${RESET}
  --duration VALUE      e.g. 30m  1h  90m  2h30m

${BOLD}EXAMPLES${RESET}
  sudo $0 schedule --install-systemd
  sudo $0 schedule --from 09:00 --to 17:00 --no-second-window --weekends --install-systemd
  sudo $0 schedule --from 08:00 --to 12:00 --from2 14:00 --to2 18:00 --install-cron
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
  local plain; plain=$(echo -e "$*" | sed 's/\x1B\[[0-9;]*m//g')
  echo "$(date '+%Y-%m-%d %H:%M:%S') $plain" >> "$LOG_FILE" 2>/dev/null || true
  echo -e "$*"
}

mkdir -p "$STATE_DIR"

# ─────────────────────────────────────────────────────────────
#  /etc/hosts — atomic, crash-safe manipulation
#  We write to a temp file then mv (atomic on same filesystem).
# ─────────────────────────────────────────────────────────────
is_blocked() {
  grep -q "${MARKER}" "$HOSTS_FILE" 2>/dev/null
}

do_block() {
  if ! is_blocked; then
    # Build new content: existing hosts + our entries
    local tmp; tmp=$(mktemp)
    cp "$HOSTS_FILE" "$tmp"
    for domain in "${DOMAINS[@]}"; do
      echo "${REDIRECT_IP} ${domain} ${MARKER}" >> "$tmp"
    done
    # Atomic replace
    mv "$tmp" "$HOSTS_FILE"
    log "${RED}🔒 YouTube blocked.${RESET}"
  fi
}

do_unblock() {
  if is_blocked; then
    local tmp; tmp=$(mktemp)
    grep -v "${MARKER}" "$HOSTS_FILE" > "$tmp" || true
    mv "$tmp" "$HOSTS_FILE"
    log "${GREEN}🔓 YouTube unblocked.${RESET}"
  fi
}

# ─────────────────────────────────────────────────────────────
#  Time helpers
# ─────────────────────────────────────────────────────────────
hhmm_to_min() {
  local h m
  IFS=: read -r h m <<< "$1"
  echo $(( 10#$h * 60 + 10#$m ))
}

parse_duration() {
  local raw="$1" h=0 m=0 secs=0
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
  date +%H:%M | { IFS=: read -r h m; echo $(( 10#$h * 60 + 10#$m )); }
}

is_weekend() {
  local dow; dow=$(date +%u)   # 1=Mon … 7=Sun
  [[ "$dow" -ge 6 ]]
}

# ─────────────────────────────────────────────────────────────
#  Schedule persistence
# ─────────────────────────────────────────────────────────────
save_schedule() {
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
#  Core tick logic — shared by cron, systemd, and daemon loop
# ─────────────────────────────────────────────────────────────
evaluate_and_apply() {
  # 1. Check "for" deadline first — it takes priority
  if [[ -f "$FOR_DEADLINE_FILE" ]]; then
    local deadline; deadline=$(cat "$FOR_DEADLINE_FILE")
    local now_ts; now_ts=$(date +%s)
    if (( now_ts < deadline )); then
      do_block
      return
    else
      # Deadline passed — clean up and fall through to schedule logic
      rm -f "$FOR_DEADLINE_FILE"
      log "${GREEN}✓ Fixed-duration block expired.${RESET}"
    fi
  fi

  # 2. No saved schedule → leave hosts as-is
  [[ -f "$SCHEDULE_FILE" ]] || return

  source "$SCHEDULE_FILE"
  local from1="${FROM1}" to1="${TO1}"
  local from2="${FROM2}" to2="${TO2}"
  local second_window="${SECOND_WINDOW:-yes}"
  local weekends="${WEEKENDS:-no}"

  local from1_m; from1_m=$(hhmm_to_min "$from1")
  local to1_m;   to1_m=$(hhmm_to_min "$to1")
  local from2_m; from2_m=$(hhmm_to_min "$from2")
  local to2_m;   to2_m=$(hhmm_to_min "$to2")
  local now;     now=$(now_min)

  local should_block=0

  if is_weekend && [[ "$weekends" == "no" ]]; then
    should_block=0
  else
    (( now >= from1_m && now < to1_m )) && should_block=1
    if [[ "$second_window" == "yes" ]] && (( now >= from2_m && now < to2_m )); then
      should_block=1
    fi
  fi

  if [[ "$should_block" -eq 1 ]]; then do_block; else do_unblock; fi
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
  rm -f "$FOR_DEADLINE_FILE"   # Cancel any active "for" timer
  do_unblock
}

cmd_status() {
  echo -e "${BOLD}── YouTube Blocker Status ──────────────────────${RESET}"
  if is_blocked; then
    echo -e "  Blocked     : ${RED}YES${RESET}"
  else
    echo -e "  Blocked     : ${GREEN}no${RESET}"
  fi

  if [[ -f "$FOR_DEADLINE_FILE" ]]; then
    local deadline; deadline=$(cat "$FOR_DEADLINE_FILE")
    local now_ts;   now_ts=$(date +%s)
    if (( now_ts < deadline )); then
      local remaining=$(( deadline - now_ts ))
      local human_end; human_end=$(date -d "@$deadline" '+%H:%M:%S' 2>/dev/null \
                                   || date -r "$deadline" '+%H:%M:%S' 2>/dev/null)
      echo -e "  \"for\" timer : active — unblocks at ${human_end} ($(( remaining/60 ))m $(( remaining%60 ))s left)"
    else
      echo -e "  \"for\" timer : expired"
    fi
  fi

  if [[ -f "$SCHEDULE_FILE" ]]; then
    source "$SCHEDULE_FILE"
    echo -e "\n  ${BOLD}Saved schedule:${RESET}"
    echo -e "  Window 1    : ${FROM1} → ${TO1}"
    if [[ "${SECOND_WINDOW:-yes}" == "yes" ]]; then
      echo -e "  Window 2    : ${FROM2} → ${TO2}"
    else
      echo -e "  Window 2    : (disabled)"
    fi
    echo -e "  Weekends    : ${WEEKENDS:-no}"
  else
    echo -e "\n  ${YELLOW}No saved schedule.${RESET}"
  fi

  # Systemd
  if systemctl is-active --quiet ytblock.timer 2>/dev/null; then
    echo -e "  Systemd     : ${GREEN}timer active${RESET}"
  elif [[ -f "$SYSTEMD_TIMER" ]]; then
    echo -e "  Systemd     : ${YELLOW}installed but not active${RESET}"
  fi

  # Bash daemon
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo -e "  Bash daemon : running (PID $(cat "$PID_FILE"))"
  fi

  # Cron
  if crontab -l 2>/dev/null | grep -q "ytblock"; then
    echo -e "  Cron        : ${GREEN}entry present${RESET}"
  fi
}

# ── reset: full teardown ──────────────────────────────────────
cmd_reset() {
  require_root

  # 1. Unblock hosts
  rm -f "$FOR_DEADLINE_FILE"
  do_unblock

  # 2. Kill bash daemon
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    kill "$(cat "$PID_FILE")"
    echo -e "${YELLOW}↺  Stopped background daemon (PID $(cat "$PID_FILE")).${RESET}"
  fi

  # 3. Remove systemd units
  if [[ -f "$SYSTEMD_TIMER" ]] || [[ -f "$SYSTEMD_SERVICE" ]]; then
    systemctl stop  ytblock.timer ytblock.service 2>/dev/null || true
    systemctl disable ytblock.timer               2>/dev/null || true
    rm -f "$SYSTEMD_TIMER" "$SYSTEMD_SERVICE"
    systemctl daemon-reload
    echo -e "${YELLOW}↺  Removed systemd units.${RESET}"
  fi

  # 4. Remove cron entries (root's crontab)
  if crontab -l 2>/dev/null | grep -q "ytblock"; then
    crontab -l 2>/dev/null | grep -v "ytblock" | crontab -
    echo -e "${YELLOW}↺  Removed cron entries.${RESET}"
  fi

  # 5. Wipe state files
  rm -f "$SCHEDULE_FILE" "$PID_FILE"

  echo -e "${GREEN}✓ Full reset complete. YouTube unblocked, all automation removed.${RESET}"
}

# ── "for" mode ────────────────────────────────────────────────
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

  # Write deadline to disk — survives reboots
  local deadline=$(( $(date +%s) + secs ))
  echo "$deadline" > "$FOR_DEADLINE_FILE"

  do_block

  local human_end; human_end=$(date -d "@$deadline" '+%H:%M:%S' 2>/dev/null \
                               || date -r "$deadline" '+%H:%M:%S' 2>/dev/null)
  echo -e "  ${BOLD}YouTube blocked for ${duration}${RESET} — unblocks at ${human_end}"

  if systemctl is-active --quiet ytblock.timer 2>/dev/null; then
    echo -e "  ${CYAN}ℹ The systemd timer will handle the unblock automatically.${RESET}"
  else
    echo -e "  ${YELLOW}⚠ No systemd timer active. Running background waiter (not reboot-safe).${RESET}"
    echo -e "    Install the timer with: sudo $0 schedule --install-systemd"
    (
      sleep "$secs"
      rm -f "$FOR_DEADLINE_FILE"
      do_unblock
      log "${GREEN}✓ Fixed-duration block expired — YouTube unblocked.${RESET}"
    ) &
    disown
  fi
}

# ── systemd install ───────────────────────────────────────────
install_systemd() {
  local script_path; script_path="$(realpath "$0")"

  cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=YouTube blocker — evaluate schedule
After=network.target

[Service]
Type=oneshot
ExecStart=$script_path _tick
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
EOF

  cat > "$SYSTEMD_TIMER" <<EOF
[Unit]
Description=YouTube blocker — run every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now ytblock.timer
  echo -e "${GREEN}✓ Systemd timer installed and started.${RESET}"
  echo -e "  Check with : systemctl status ytblock.timer"
  echo -e "  Logs       : journalctl -u ytblock.service  or  tail $LOG_FILE"
}

# ── bash daemon loop ──────────────────────────────────────────
run_scheduler_loop() {
  echo $$ > "$PID_FILE"
  log "${BOLD}⏱  Bash scheduler daemon running (PID $$)${RESET}"
  while true; do
    evaluate_and_apply
    sleep 60
  done
}

# ── "schedule" command ────────────────────────────────────────
cmd_schedule() {
  require_root

  local from1="$DEFAULT_FROM1" to1="$DEFAULT_TO1"
  local from2="$DEFAULT_FROM2" to2="$DEFAULT_TO2"
  local second_window="yes"
  local weekends="$DEFAULT_WEEKENDS"
  local daemon=0
  local install_cron=0
  local install_systemd_flag=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)              from1="$2";              shift 2 ;;
      --to)                to1="$2";                shift 2 ;;
      --from2)             from2="$2";              shift 2 ;;
      --to2)               to2="$2";                shift 2 ;;
      --no-second-window)  second_window="no";      shift   ;;
      --weekends)          weekends="yes";           shift   ;;
      --no-weekends)       weekends="no";            shift   ;;
      --daemon)            daemon=1;                 shift   ;;
      --install-cron)      install_cron=1;           shift   ;;
      --install-systemd)   install_systemd_flag=1;  shift   ;;
      *) echo -e "${RED}Unknown option: $1${RESET}"; usage ;;
    esac
  done

  # Validate HH:MM
  local re='^([01][0-9]|2[0-3]):[0-5][0-9]$'
  for t in "$from1" "$to1" "$from2" "$to2"; do
    [[ "$t" =~ $re ]] || {
      echo -e "${RED}✗ Invalid time: $t  (expected HH:MM, e.g. 08:00)${RESET}"
      exit 1
    }
  done

  save_schedule "$from1" "$to1" "$from2" "$to2" "$second_window" "$weekends"

  # ── Systemd (recommended) ─────────────────────────────────
  if [[ "$install_systemd_flag" -eq 1 ]]; then
    install_systemd
    return
  fi

  # ── Cron (fallback) ───────────────────────────────────────
  if [[ "$install_cron" -eq 1 ]]; then
    local script_path; script_path="$(realpath "$0")"
    # Remove old ytblock cron entries, then append new ones
    # FIX: no "root" field — this is a personal (root user) crontab
    (
      crontab -l 2>/dev/null | grep -v "ytblock" || true
      echo "* * * * * $script_path _tick >> $LOG_FILE 2>&1"
      echo "@reboot    $script_path _tick >> $LOG_FILE 2>&1"
    ) | crontab -
    echo -e "${GREEN}✓ Cron entries installed (no 'root' field — correct for user crontab).${RESET}"
    echo -e "  Verify with: sudo crontab -l | grep ytblock"
    return
  fi

  # ── Bash daemon ───────────────────────────────────────────
  if [[ "$daemon" -eq 1 ]]; then
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      kill "$(cat "$PID_FILE")"
      echo -e "${YELLOW}↺ Stopped previous daemon.${RESET}"
    fi
    nohup "$0" _run_scheduler >> "$LOG_FILE" 2>&1 &
    disown
    echo -e "${GREEN}✓ Bash daemon started (PID $!). Logs: $LOG_FILE${RESET}"
    echo -e "  ${YELLOW}⚠ This does NOT survive reboots. Use --install-systemd instead.${RESET}"
  else
    # Foreground
    run_scheduler_loop
  fi
}

# ─────────────────────────────────────────────────────────────
#  Main dispatcher
# ─────────────────────────────────────────────────────────────
ACTION="${1:-}"
shift 2>/dev/null || true

case "$ACTION" in
  schedule)        cmd_schedule "$@" ;;
  for)             cmd_for      "$@" ;;
  block)           cmd_block ;;
  unblock)         cmd_unblock ;;
  status)          cmd_status ;;
  reset)           cmd_reset ;;
  _run_scheduler)  run_scheduler_loop ;;   # internal: bash daemon entry
  _tick)           require_root; evaluate_and_apply ;;  # internal: cron/systemd
  *)               usage ;;
esac