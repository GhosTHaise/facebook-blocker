#!/bin/bash
# ============================================================
#  block.sh — Universal domain blocker via /etc/hosts
#  Usage:
#    sudo ./block.sh block   <domain> [domain2 ...]
#    sudo ./block.sh unblock <domain> [domain2 ...]
#    sudo ./block.sh list
#    sudo ./block.sh reset
# ============================================================

REDIRECT_IP="127.0.0.1"
MARKER="# managed-by-block.sh"
HOSTS_FILE="/etc/hosts"

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Helpers ─────────────────────────────────────────────────
usage() {
  echo -e "${BOLD}Usage:${RESET}"
  echo -e "  sudo $0 block   <domain> [domain2 ...]   ${CYAN}# Block one or more domains${RESET}"
  echo -e "  sudo $0 unblock <domain> [domain2 ...]   ${CYAN}# Unblock one or more domains${RESET}"
  echo -e "  sudo $0 list                             ${CYAN}# Show all blocked domains${RESET}"
  echo -e "  sudo $0 reset                            ${CYAN}# Remove ALL managed blocks${RESET}"
  echo ""
  echo -e "${BOLD}Examples:${RESET}"
  echo -e "  sudo $0 block www.facebook.com www.instagram.com"
  echo -e "  sudo $0 unblock www.facebook.com"
  echo -e "  sudo $0 list"
  exit 1
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}✗ Please run as root: sudo $0 $*${RESET}"
    exit 1
  fi
}

is_blocked() {
  grep -q "^${REDIRECT_IP} ${1} ${MARKER}$" "$HOSTS_FILE" 2>/dev/null
}

# ── Commands ─────────────────────────────────────────────────
cmd_block() {
  [ $# -eq 0 ] && { echo -e "${RED}✗ Provide at least one domain to block.${RESET}"; usage; }
  for domain in "$@"; do
    if is_blocked "$domain"; then
      echo -e "${YELLOW}⚠ Already blocked:${RESET} $domain"
    else
      echo "${REDIRECT_IP} ${domain} ${MARKER}" >> "$HOSTS_FILE"
      echo -e "${GREEN}✓ Blocked:${RESET} $domain"
    fi
  done
}

cmd_unblock() {
  [ $# -eq 0 ] && { echo -e "${RED}✗ Provide at least one domain to unblock.${RESET}"; usage; }
  for domain in "$@"; do
    if is_blocked "$domain"; then
      sed -i "/^${REDIRECT_IP} ${domain} ${MARKER}$/d" "$HOSTS_FILE"
      echo -e "${GREEN}✓ Unblocked:${RESET} $domain"
    else
      echo -e "${YELLOW}⚠ Not currently blocked:${RESET} $domain"
    fi
  done
}

cmd_list() {
  echo -e "${BOLD}Currently blocked domains:${RESET}"
  local count=0
  while IFS= read -r line; do
    domain=$(echo "$line" | awk '{print $2}')
    echo -e "  ${RED}✗${RESET} $domain"
    ((count++))
  done < <(grep "${MARKER}$" "$HOSTS_FILE" 2>/dev/null)
  [ $count -eq 0 ] && echo -e "  ${CYAN}(none)${RESET}"
  echo -e "\n  Total: ${BOLD}$count${RESET} domain(s) blocked."
}

cmd_reset() {
  local count
  count=$(grep -c "${MARKER}$" "$HOSTS_FILE" 2>/dev/null || true)
  sed -i "/${MARKER}$/d" "$HOSTS_FILE"
  echo -e "${GREEN}✓ Removed all $count managed block(s).${RESET}"
}

# ── Main ─────────────────────────────────────────────────────
ACTION="${1:-}"
shift 2>/dev/null || true

case "$ACTION" in
  block)   require_root; cmd_block   "$@" ;;
  unblock) require_root; cmd_unblock "$@" ;;
  list)    cmd_list ;;
  reset)   require_root; cmd_reset ;;
  *)       usage ;;
esac