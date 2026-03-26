#!/bin/bash
# ============================================================
#  timelimit.sh — Track & enforce per-domain time quotas
#
#  How it works:
#    1. "watch" polls DNS to detect if the user is visiting
#       the target domain (via /proc/net/tcp or ss/netstat).
#    2. Accumulated seconds are stored in a state file.
#    3. Once the quota is reached, the domain is blocked via
#       /etc/hosts for the rest of the current hour.
#    4. At the top of the next hour the counter resets.
#
#  Usage:
#    sudo ./timelimit.sh watch   [--domain facebook.com] [--limit 180]
#    sudo ./timelimit.sh status  [--domain facebook.com]
#    sudo ./timelimit.sh reset   [--domain facebook.com]
#    sudo ./timelimit.sh unblock [--domain facebook.com]
#
#  Defaults: domain=facebook.com  limit=180s (3 min/hour)
#
#  Run in background:  sudo ./timelimit.sh watch &
#  Stop watching:      kill $(cat /tmp/timelimit_facebook.com.pid)
# ============================================================

# ── Defaults ─────────────────────────────────────────────────
DEFAULT_DOMAIN="facebook.com"
DEFAULT_LIMIT=180          # seconds per hour
POLL_INTERVAL=5            # how often to check (seconds)
HOSTS_FILE="/etc/hosts"
REDIRECT_IP="127.0.0.1"
STATE_DIR="/tmp/timelimit"
MARKER="# managed-by-timelimit.sh"

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Arg parsing ──────────────────────────────────────────────
DOMAIN="$DEFAULT_DOMAIN"
LIMIT="$DEFAULT_LIMIT"
ACTION="${1:-}"; shift 2>/dev/null || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --limit)  LIMIT="$2";  shift 2 ;;
    *) echo -e "${RED}Unknown option: $1${RESET}"; exit 1 ;;
  esac
done

# ── State files ──────────────────────────────────────────────
mkdir -p "$STATE_DIR"
SAFE_NAME="${DOMAIN//\//_}"
STATE_FILE="$STATE_DIR/${SAFE_NAME}.state"
PID_FILE="/tmp/timelimit_${SAFE_NAME}.pid"

# ── Helpers ──────────────────────────────────────────────────
usage() {
  echo -e "${BOLD}timelimit.sh — per-domain time quota enforcer${RESET}"
  echo ""
  echo -e "${BOLD}Usage:${RESET}"
  echo -e "  sudo $0 watch   [--domain DOMAIN] [--limit SECONDS]"
  echo -e "  sudo $0 status  [--domain DOMAIN]"
  echo -e "  sudo $0 reset   [--domain DOMAIN]"
  echo -e "  sudo $0 unblock [--domain DOMAIN]"
  echo ""
  echo -e "${BOLD}Options:${RESET}"
  echo -e "  --domain  Domain to monitor  (default: ${DEFAULT_DOMAIN})"
  echo -e "  --limit   Quota in seconds/hour (default: ${DEFAULT_LIMIT})"
  echo ""
  echo -e "${BOLD}Examples:${RESET}"
  echo -e "  sudo $0 watch                                  # Facebook, 3 min/h"
  echo -e "  sudo $0 watch --domain twitter.com --limit 300 # Twitter, 5 min/h"
  echo -e "  sudo $0 status --domain facebook.com"
  echo -e "  sudo $0 reset  --domain facebook.com"
  exit 1
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}✗ Please run as root: sudo $0 $ACTION --domain $DOMAIN${RESET}"
    exit 1
  fi
}

# Read state: "HOUR SECONDS_USED"
read_state() {
  if [ -f "$STATE_FILE" ]; then
    IFS=' ' read -r saved_hour saved_secs < "$STATE_FILE"
  else
    saved_hour=0; saved_secs=0
  fi
  echo "$saved_hour $saved_secs"
}

write_state() {
  echo "$1 $2" > "$STATE_FILE"
}

current_hour() {
  date +%Y%m%d%H
}

is_blocked() {
  grep -q "${REDIRECT_IP} ${DOMAIN} ${MARKER}" "$HOSTS_FILE" 2>/dev/null
}

block_domain() {
  if ! is_blocked; then
    # Block www + bare domain
    echo "${REDIRECT_IP} ${DOMAIN} ${MARKER}" >> "$HOSTS_FILE"
    echo "${REDIRECT_IP} www.${DOMAIN} ${MARKER}" >> "$HOSTS_FILE"
  fi
}

unblock_domain() {
  sed -i "/${MARKER}$/d" "$HOSTS_FILE"
}

# Detect active TCP connections to the domain using DNS resolution + ss/netstat
is_user_active() {
  local domain="$1"
  # Resolve IPs for the domain
  local ips
  ips=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}')
  ips+=" "$(getent hosts "www.$domain" 2>/dev/null | awk '{print $1}')

  if [ -z "$(echo "$ips" | tr -d ' ')" ]; then
    return 1  # Can't resolve = probably already blocked or offline
  fi

  # Check ss for ESTABLISHED connections to those IPs
  if command -v ss &>/dev/null; then
    for ip in $ips; do
      if ss -tn state established 2>/dev/null | grep -q "$ip"; then
        return 0
      fi
    done
  elif command -v netstat &>/dev/null; then
    for ip in $ips; do
      if netstat -tn 2>/dev/null | grep -qE "ESTABLISHED.*$ip"; then
        return 0
      fi
    done
  fi
  return 1
}

fmt_time() {
  local secs=$1
  printf "%dm %02ds" $((secs/60)) $((secs%60))
}

# ── Commands ─────────────────────────────────────────────────
cmd_watch() {
  require_root
  echo $$ > "$PID_FILE"
  echo -e "${BOLD}⏱  Watching ${CYAN}${DOMAIN}${RESET}${BOLD} — quota: $(fmt_time $LIMIT)/hour${RESET}"
  echo -e "   State file : $STATE_FILE"
  echo -e "   Stop with  : kill \$(cat $PID_FILE)\n"

  while true; do
    local now_hour; now_hour=$(current_hour)
    IFS=' ' read -r saved_hour saved_secs <<< "$(read_state)"

    # Reset counter at the top of a new hour
    if [ "$now_hour" != "$saved_hour" ]; then
      echo -e "\n${CYAN}↺  New hour — resetting counter & unblocking${RESET}"
      saved_secs=0
      unblock_domain
    fi

    if is_blocked; then
      write_state "$now_hour" "$saved_secs"
      sleep "$POLL_INTERVAL"
      continue
    fi

    if is_user_active "$DOMAIN"; then
      saved_secs=$((saved_secs + POLL_INTERVAL))
      local remaining=$((LIMIT - saved_secs))
      printf "\r  ${YELLOW}●${RESET} Active  — used: ${BOLD}$(fmt_time $saved_secs)${RESET} / $(fmt_time $LIMIT)   remaining: ${BOLD}$(fmt_time $((remaining > 0 ? remaining : 0)))${RESET}   "

      if [ "$saved_secs" -ge "$LIMIT" ]; then
        echo -e "\n\n${RED}🔒 Quota reached! Blocking ${DOMAIN} until next hour...${RESET}"
        block_domain
      fi
    else
      printf "\r  ${GREEN}○${RESET} Idle    — used: ${BOLD}$(fmt_time $saved_secs)${RESET} / $(fmt_time $LIMIT)   remaining: ${BOLD}$(fmt_time $((LIMIT - saved_secs)))${RESET}   "
    fi

    write_state "$now_hour" "$saved_secs"
    sleep "$POLL_INTERVAL"
  done
}

cmd_status() {
  IFS=' ' read -r saved_hour saved_secs <<< "$(read_state)"
  local now_hour; now_hour=$(current_hour)
  local used=$saved_secs
  [ "$saved_hour" != "$now_hour" ] && used=0   # stale = reset

  echo -e "${BOLD}Status for:${RESET} $DOMAIN"
  echo -e "  Quota       : $(fmt_time $LIMIT) / hour"
  echo -e "  Used so far : $(fmt_time $used)"
  echo -e "  Remaining   : $(fmt_time $((LIMIT - used > 0 ? LIMIT - used : 0)))"
  if is_blocked; then
    echo -e "  Blocked     : ${RED}YES — until next hour reset${RESET}"
  else
    echo -e "  Blocked     : ${GREEN}no${RESET}"
  fi
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo -e "  Watcher PID : $(cat "$PID_FILE") (running)"
  else
    echo -e "  Watcher PID : ${YELLOW}not running${RESET}"
  fi
}

cmd_reset() {
  require_root
  write_state "$(current_hour)" 0
  unblock_domain
  echo -e "${GREEN}✓ Counter reset and $DOMAIN unblocked.${RESET}"
}

cmd_unblock() {
  require_root
  unblock_domain
  echo -e "${GREEN}✓ $DOMAIN unblocked (counter NOT reset).${RESET}"
}

# ── Main ─────────────────────────────────────────────────────
case "$ACTION" in
  watch)   cmd_watch ;;
  status)  cmd_status ;;
  reset)   cmd_reset ;;
  unblock) cmd_unblock ;;
  *)       usage ;;
esac