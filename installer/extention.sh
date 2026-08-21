#!/bin/bash
# ================================================================== #
#  extention.sh — Extension install/uninstall via Blueprint CLI       #
#  Sourced by menu.sh. Provides: install_extensions_menu(),           #
#  uninstall_extension_menu()                                       #
#                                                                    #
#  Pre-check: Panel must exist + Blueprint must be installed.        #
#  If Blueprint is missing, auto-installs it first.                 #
#                                                                    #
#  SECURITY (2026-08-20 audit):                                      #
#  - 'adminauditlogs' REMOVED: its admin.blade.php fetches your      #
#    panel_url to a hardcoded IP (51.79.143.69:3069/api/telemetry)   #
#    on every admin page load. That's telemetry you never opted     #
#    into, shipped inside an "audit logs" extension. Deleted.       #
#  - The "install all 65 extensions at once" option has been        #
#    REMOVED. These are third-party, mixed-age Blueprint packages —  #
#    some target Blueprint releases from 2024, some contain          #
#    shell_exec() calls (shownodeids, redirect), some download and    #
#    execute unpinned code from GitHub during install (monacoeditor).#
#    Blindly running 65 of those against a production panel in one    #
#    shot is not something this installer will do automatically.     #
#    Install extensions one at a time (or a deliberate few) and       #
#    review what you're adding.                                      #
# ================================================================== #

# --- Tracking helpers ---
track_extension()   { grep -qxF "$1" "$EXT_STATE_FILE" 2>/dev/null || echo "$1" >> "$EXT_STATE_FILE"; }
untrack_extension() { grep -vxF "$1" "$EXT_STATE_FILE" 2>/dev/null > "$EXT_STATE_FILE.tmp" || true; mv "$EXT_STATE_FILE.tmp" "$EXT_STATE_FILE" 2>/dev/null || true; }

install_one_extension() {
  local id="$1"
  local PANEL_DIR
  PANEL_DIR="$(get_panel_dir)"
  [ -z "$PANEL_DIR" ] && { err "Panel not found."; return 1; }

  msg "Downloading $id.blueprint..."
  curl -fsSL -o "$PANEL_DIR/$id.blueprint" "$REPO_RAW/extensions/$id.blueprint" || { err "Download failed: $REPO_RAW/extensions/$id.blueprint"; return 1; }

  cd "$PANEL_DIR" || return 1
  msg "Installing $id..."
  blueprint -install "$id" 2>&1 | tee -a "$LOG_FILE"
  local BP_EXIT=${PIPESTATUS[0]}
  if [ "$BP_EXIT" -eq 0 ]; then
    track_extension "$id"; ok "$id installed."
  else
    err "Failed to install $id (exit code $BP_EXIT)"
  fi
}

# --- Extension list (id|display name) ---
# NOTE: adminauditlogs removed (hardcoded-IP telemetry — see header).
EXTENSIONS=(
  "activitypurges|ActivityPurges" "autobackups|AutoBackups"
  "blueannoucements|Blue Annoucements" "configeditor|Config Editor" "consolelogs|Console Logs"
  "customcss|Custom CSS" "customserversort|Custom Server Sort" "databaseimportexport|Database Import/Export"
  "eggchanger|Egg Changer" "huxregister|HuxPlay Register" "laravellogs|Laravel Logs"
  "loader|Loader" "lyrdyannounce|Announce" "mclogs|MC Logs" "mcp|MCP Console" "mcplayer|Minecraft Player Manager v2"
  "mcplugins|MC Plugins Manager" "mctools|McTools" "minecraftmodmanager|Minecraft Mod Manager"
  "minecraftplayermanager|Minecraft Player Manager" "minecraftpluginmanager|Minecraft Plugin Manager"
  "modrinthbrowser|Modrinth Browser" "monacoeditor|Monaco Editor" "motdmaker|MOTD Maker"
  "mysqlautobackup|MySQL Backup Manager" "node|Node Usage Status" "nopagination|No Pagination"
  "paneladdressoverride|PanelAddressOverride" "playerlisting|Player Listing" "pstatistics|Cloud Statistics"
  "pterodactylcpuburst|CPU Burst" "pterodactylpanelban|PanelBan" "pterodactylramburst|RAM Burst"
  "pteromonaco|PteroMonaco" "pullfiles|Pull Files" "redirect|Redirect" "resourcealerts|Resource Alerts"
  "resourcemanager|Resource Manager" "sagaautosuspension|Auto Suspension" "sagaminecraftmodpackinstaller|SAGA Modpack Installer"
  "serverbackgrounds|Server Backgrounds" "servericonimporter|ServerIconImporter" "serverid|ServerID"
  "serverimporter|Server Importer" "serverpropsmanager|ServerPropsManager" "serversplitter|Server Splitter"
  "shownodeids|Show Node IDs" "sidebar|Sidebar" "simplefavicons|Simple Favicons" "simplefooters|Simple Footers"
  "snowflakes|Snowflakes" "sociallogin|SocialLogin" "startupchanger|StartupChanger" "stats|Stats"
  "stellar|Stellar v3.3" "subdomainmanager|SubdomainManager" "subdomains|SubDomains" "tawkto|TawkTo"
  "translations|Translations" "trashbin|Trash Bin" "urldownloader|URL Downloader" "vanillatweaks|VanillaTweaks"
  "versionchanger|Version Changer" "vminfo|VMInfo" "votifiertester|Votifier Tester"
)

install_extensions_menu() {
  banner; echo "Install Extensions"; line

  panel_exists_or_die || return
  ensure_base_tools
  ensure_blueprint_or_install || { err "Cannot proceed without Blueprint."; pause; return; }

  warn "Third-party extensions run arbitrary install scripts against your panel."
  warn "Install a few deliberately — not all at once. Some are years old and untested"
  warn "against the current Blueprint/Pterodactyl release."
  echo ""

  local i=1
  for entry in "${EXTENSIONS[@]}"; do
    IFS='|' read -r id name <<< "$entry"
    printf "  %2d) %-34s (%s)\n" "$i" "$name" "$id"
    i=$((i+1))
  done
  echo ""
  echo "Enter numbers (e.g. 3 12 40), or 0 to cancel."
  local SEL
  read -r -p "> " SEL
  [ "$SEL" == "0" ] && return

  for n in $SEL; do
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#EXTENSIONS[@]}" ] && {
      IFS='|' read -r id _ <<< "${EXTENSIONS[$((n-1))]}"
      install_one_extension "$id"
    } || warn "Skip: $n"
  done
  pause
}

uninstall_extension_menu() {
  banner; echo "Uninstall Extension"; line

  if ! command -v blueprint >/dev/null 2>&1; then
    err "Blueprint not installed — nothing to uninstall."
    pause; return
  fi

  if [ ! -s "$EXT_STATE_FILE" ]; then
    warn "No tracked extensions. Type an identifier manually."
    echo ""
    local MID
    read -r -p "Extension ID to remove (Enter=cancel): " MID
    [ -z "$MID" ] && { pause; return; }
    local PD; PD="$(get_panel_dir)"; cd "$PD" 2>/dev/null || true
    blueprint -remove "$MID" 2>&1 | tee -a "$LOG_FILE"
    local BP_EXIT=${PIPESTATUS[0]}
    if [ "$BP_EXIT" -eq 0 ]; then
      untrack_extension "$MID"; ok "$MID removed."
    else
      err "Failed to remove $MID (exit code $BP_EXIT)"
    fi
    pause; return
  fi

  mapfile -t INSTALLED < "$EXT_STATE_FILE"
  local i=1
  for id in "${INSTALLED[@]}"; do
    [ -z "$id" ] && continue
    printf "  %2d) %s\n" "$i" "$id"
    i=$((i+1))
  done
  echo ""
  echo "Enter numbers, 'all', or 0 to cancel."
  local SEL
  read -r -p "> " SEL
  [ "$SEL" == "0" ] && return

  local PD; PD="$(get_panel_dir)"; cd "$PD" 2>/dev/null || true
  if [ "$SEL" == "all" ]; then
    for id in "${INSTALLED[@]}"; do
      [ -z "$id" ] && continue
      blueprint -remove "$id" 2>&1 | tee -a "$LOG_FILE"
      [ ${PIPESTATUS[0]} -eq 0 ] && untrack_extension "$id" || warn "Failed to remove $id"
    done
  else
    for n in $SEL; do
      [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#INSTALLED[@]}" ] && {
        local id="${INSTALLED[$((n-1))]}"
        blueprint -remove "$id" 2>&1 | tee -a "$LOG_FILE"
        [ ${PIPESTATUS[0]} -eq 0 ] && untrack_extension "$id" || warn "Failed to remove $id"
      } || warn "Skip: $n"
    done
  fi
  ok "Done."
  pause
}
