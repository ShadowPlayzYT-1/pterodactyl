#!/bin/bash
######################################################################################
#                                                                                    #
#  NextDev Pterodactyl Easy Installer                                                #
#  Developer: ShadowPlayzYT                                                          #
#  Run: bash <(curl -s https://raw.githubusercontent.com/ShadowPlayzYT-1/pterodactyl/main/menu.sh)
#                                                                                    #
#  v12 — Security audit: removed Nebula (telemetry), removed AdminAuditLogs         #
#  (hardcoded IP telemetry), removed "Install All Extensions", hardened perms,     #
#  added auto-node setup, cron watchdog, checksum verification.                     #
#                                                                                    #
######################################################################################

set -o pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" 2>/dev/null && pwd || echo "")"

load_script() {
  local name="$1"
  if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/installer/$name" ]; then
    source "$SELF_DIR/installer/$name"; return
  fi
  local cache="${SCRIPT_DIR:-/tmp/pterodactyl-easy-installer}/$name"
  if [ -f "$cache" ] && [ -s "$cache" ]; then source "$cache"; return; fi
  echo "  Downloading $name..."
  curl -sSL "${REPO_RAW:-https://raw.githubusercontent.com/ShadowPlayzYT-1/pterodactyl/main}/installer/$name" -o "$cache" 2>/dev/null
  if [ -s "$cache" ]; then source "$cache"; else
    echo "  ERROR: Failed to download $name"
    exit 1
  fi
}

# --- Boot --- #
load_script "common.sh"
mkdir -p "${SCRIPT_DIR:-/tmp/pterodactyl-easy-installer}"; touch "${LOG_FILE:-/var/log/pterodactyl-easy-installer.log}"

load_script "panel.sh"
load_script "wings.sh"
load_script "autosetup.sh"
load_script "panelwings.sh"
load_script "admin.sh"
load_script "blueprint.sh"
load_script "nebula.sh"
load_script "extention.sh"
load_script "service.sh"
load_script "healthcheck.sh"
load_script "uninstall.sh"

# ----------------------- UI ------------------------- #

draw_banner() {
  clear
  echo -e "${C_CYAN}${C_BOLD}"
  cat << 'BANNER'
  ███╗   ██╗███████╗██╗  ██╗████████╗
  ████╗  ██║██╔════╝╚██╗██╔╝╚══██╔══╝
  ██╔██╗ ██║█████╗   ╚███╔╝     ██║
  ██║╚██╗ ██║██╔══╝   ██╔██╗     ██║
  ██║ ╚████║███████╗██╔╝ ██╗    ██║
  ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝    ╚═╝
BANNER
  echo -e "${C_NC}"
  echo -e "${C_BOLD}           NextDev Pterodactyl Installer${C_NC}"
  echo -e "${C_YELLOW}           Developer: ShadowPlayzYT${C_NC}"
  echo -e "${C_CYAN}  ───────────────────────────────────────────${C_NC}"
}

draw_menu() {
  draw_banner
  echo ""
  echo -e "  ${C_BOLD}[1]${C_NC}  Install Panel"
  echo -e "  ${C_BOLD}[2]${C_NC}  Install Wings"
  echo -e "  ${C_BOLD}[3]${C_NC}  Setup Wings (paste deploy command)"
  echo -e "  ${C_BOLD}[4]${C_NC}  Auto Node Setup (Panel + Wings)"
  echo -e "  ${C_BOLD}[5]${C_NC}  Themes & Extensions"
  echo -e "  ${C_BOLD}[6]${C_NC}  Uninstall Panel"
  echo -e "  ${C_BOLD}[7]${C_NC}  Uninstall Wings"
  echo -e "  ${C_BOLD}[8]${C_NC}  Add Admin User"
  echo -e "  ${C_BOLD}[9]${C_NC}  Manage Services"
  echo -e "  ${C_BOLD}[10]${C_NC} Health Check"
  echo -e "  ${C_BOLD}[0]${C_NC}  Exit"
  echo ""
  echo -e "${C_CYAN}  ───────────────────────────────────────────${C_NC}"
}

draw_themes_menu() {
  draw_banner
  echo -e "  ${C_BOLD}Themes & Extensions${C_NC}"
  echo -e "${C_CYAN}  ───────────────────────────────────────────${C_NC}"
  echo ""
  echo -e "  ${C_BOLD}[1]${C_NC}  Install Blueprint"
  echo -e "  ${C_BOLD}[2]${C_NC}  Install Extensions"
  echo -e "  ${C_BOLD}[3]${C_NC}  Uninstall Extension"
  echo -e "  ${C_BOLD}[4]${C_NC}  Uninstall Blueprint"
  echo -e "  ${C_BOLD}[5]${C_NC}  Update Blueprint"
  echo -e "  ${C_BOLD}[6]${C_NC}  Remove Nebula (cleanup)"
  echo -e "  ${C_BOLD}[0]${C_NC}  Back"
  echo ""
  echo -e "${C_CYAN}  ───────────────────────────────────────────${C_NC}"
}

draw_services_menu() {
  draw_banner
  echo -e "  ${C_BOLD}Manage Services${C_NC}"
  echo -e "${C_CYAN}  ───────────────────────────────────────────${C_NC}"
  echo ""
  echo -e "  ${C_BOLD}[1]${C_NC}  Manage Panel Services"
  echo -e "  ${C_BOLD}[2]${C_NC}  Manage Wings Service"
  echo -e "  ${C_BOLD}[0]${C_NC}  Back"
  echo ""
  echo -e "${C_CYAN}  ───────────────────────────────────────────${C_NC}"
}

# ----------------------- Menus ------------------------- #

themes_menu() {
  while true; do
    draw_themes_menu
    read -r -p "  Select an option: " TC
    case "$TC" in
      1) install_blueprint ;;
      2) install_extensions_menu ;;
      3) uninstall_extension_menu ;;
      4) uninstall_blueprint ;;
      5) update_blueprint ;;
      6) uninstall_nebula ;;
      0) return ;;
      *) warn "Invalid option."; sleep 1 ;;
    esac
  done
}

services_menu() {
  while true; do
    draw_services_menu
    read -r -p "  Select an option: " SC
    case "$SC" in
      1) manage_panel_services ;;
      2) manage_wings_service ;;
      0) return ;;
      *) warn "Invalid option."; sleep 1 ;;
    esac
  done
}

main_menu() {
  while true; do
    draw_menu
    read -r -p "  Select an option: " CHOICE
    case "$CHOICE" in
      1) panel_install ;;
      2) wings_install ;;
      3) wings_setup_token ;;
      4) panel_wings_auto ;;
      5) themes_menu ;;
      6) uninstall_panel ;;
      7) uninstall_wings ;;
      8) add_admin_user ;;
      9) services_menu ;;
      10) health_check ;;
      0) echo -e "\n  ${C_BOLD}Thanks for using NextDev!${C_NC} Bye!\n"; exit 0 ;;
      *) warn "Invalid option."; sleep 1 ;;
    esac
  done
}

# --- Start --- #
require_root
ensure_base_tools
main_menu
