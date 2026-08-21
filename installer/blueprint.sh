#!/bin/bash
# ================================================================== #
#  blueprint.sh — Blueprint framework install/update/uninstall       #
#  Sourced by menu.sh. Provides: install_blueprint(),               #
#  update_blueprint(), uninstall_blueprint()                        #
#                                                                    #
#  KNOWN UPSTREAM BUG (patched here):                                #
#  Blueprint's own blueprint.sh contains:                            #
#    if [[ -f "/.dockerenv" ]]; then DOCKER="y"; FOLDER="/app"; fi   #
#  Any Docker-based environment (Codespaces, Docker, devcontainers) #
#  has /.dockerenv present, so Blueprint force-overrides its working #
#  directory to /app — even when the panel lives elsewhere. This    #
#  breaks the install ("cd: /app: No such file or directory") and   #
#  can leave the panel half-rebuilt (500 error). We patch that one   #
#  line right after downloading blueprint.sh, before running it.    #
# ================================================================== #

install_blueprint() {
  banner; echo "Install Blueprint"; line

  pre_check_blueprint || return

  local PHP_BIN; PHP_BIN="$(get_php_bin)"
  local PANEL_DIR
  PANEL_DIR="$(get_panel_dir)"
  save_state PANEL_DIR "$PANEL_DIR"
  export PTERODACTYL_DIRECTORY="$PANEL_DIR"

  msg "Downloading Blueprint..."
  cd "$PTERODACTYL_DIRECTORY" || { err "Not found: $PANEL_DIR"; pause; return; }
  wget -q "https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip" -O release.zip 2>>"$LOG_FILE"
  [ ! -s release.zip ] && { err "Download failed"; pause; return; }
  unzip -o -q release.zip; rm -f release.zip

  if [ -f "$PTERODACTYL_DIRECTORY/blueprint.sh" ]; then
    if grep -q 'FOLDER="/app"' "$PTERODACTYL_DIRECTORY/blueprint.sh"; then
      sed -i "s#FOLDER=\"/app\"#FOLDER=\"$PTERODACTYL_DIRECTORY\"#" "$PTERODACTYL_DIRECTORY/blueprint.sh"
      ok "Patched Blueprint's Docker-path bug (FOLDER now correctly points to $PTERODACTYL_DIRECTORY)"
    fi
  else
    err "blueprint.sh missing after extraction — download may be corrupt."
    pause; return
  fi

  npm i -g yarn >>"$LOG_FILE" 2>&1
  yarn install >>"$LOG_FILE" 2>&1

  printf 'WEBUSER="www-data";\nOWNERSHIP="www-data:www-data";\nUSERSHELL="/bin/bash";\n' > "$PTERODACTYL_DIRECTORY/.blueprintrc"

  msg "Running blueprint.sh..."
  chmod +x "$PTERODACTYL_DIRECTORY/blueprint.sh"
  bash "$PTERODACTYL_DIRECTORY/blueprint.sh" 2>&1 | tee -a "$LOG_FILE"

  line
  if command -v blueprint >/dev/null 2>&1 && [ -f "$PTERODACTYL_DIRECTORY/.blueprint/extensions/blueprint/private/db/is_installed" ]; then
    ok "Blueprint installed! Version: $(blueprint -version 2>/dev/null)"
  else
    err "Blueprint install did not finish cleanly. Check $LOG_FILE"
    warn "If your panel shows a 500 error, try: service nginx restart && chown -R www-data:www-data /var/www/pterodactyl"
  fi
  pause
}

update_blueprint() {
  banner; echo "Update Blueprint"; line
  command -v blueprint >/dev/null 2>&1 || { err "Blueprint not installed."; pause; return; }
  blueprint -upgrade 2>&1 | tee -a "$LOG_FILE"
  local BP_EXIT=${PIPESTATUS[0]}
  if [ "$BP_EXIT" -eq 0 ]; then
    ok "Blueprint updated. Version: $(blueprint -version 2>/dev/null)"
  else
    err "Blueprint update failed (exit code $BP_EXIT)"
  fi
  pause
}

uninstall_blueprint() {
  banner; echo "Uninstall Blueprint"; line
  warn "This wipes and re-downloads panel files. DB/servers NOT affected. .env backed up."
  echo ""
  read -r -p "Type CONFIRM to proceed: " C
  [ "$C" != "CONFIRM" ] && { warn "Cancelled."; pause; return; }

  # FIX (audit #7): PHP_BIN was referenced here but only ever declared
  # locally inside install_blueprint() — it was empty/undefined in this
  # function, silently falling back to a possibly-wrong "php" in PATH.
  local PHP_BIN; PHP_BIN="$(get_php_bin)"

  local PANEL_DIR
  PANEL_DIR="$(get_panel_dir)"
  [ -z "$PANEL_DIR" ] && { err "Panel not found."; pause; return; }
  cd "$PANEL_DIR" || return

  local BACKUP="/root/pterodactyl-env-backup-$(date +%s).bak"
  cp .env "$BACKUP" 2>/dev/null && ok "Backed up .env to $BACKUP"

  # FIX (audit #8): stop the queue worker BEFORE wiping application files.
  # Previously it kept running against files that were about to be
  # deleted/replaced underneath it.
  msg "Stopping queue worker..."
  pkill -f "artisan queue:work" 2>/dev/null || true

  "$PHP_BIN" artisan down >>"$LOG_FILE" 2>&1
  msg "Removing Blueprint & rebuilding panel..."
  find . -maxdepth 1 -not -name '.*' -exec rm -rf {} + 2>>"$LOG_FILE"
  rm -rf .blueprint .blueprintrc /usr/local/bin/blueprint 2>>"$LOG_FILE"

  msg "Re-downloading panel..."
  curl -Lo panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz" 2>>"$LOG_FILE"
  # FIX (audit #9): verify the download before extracting/proceeding —
  # previously this had no check at all, so a failed download would
  # extract garbage (or nothing) and continue anyway.
  if [ ! -s panel.tar.gz ]; then
    err "Panel re-download failed — file is empty. Restoring your .env and stopping here."
    cp "$BACKUP" .env 2>/dev/null
    err "Your panel is currently in maintenance mode with old files removed."
    err "Re-run this uninstall, or manually re-download panel.tar.gz, then: php artisan up"
    pause; return
  fi
  tar -xzf panel.tar.gz; chmod -R 755 storage/* bootstrap/cache/; rm -f panel.tar.gz
  cp "$BACKUP" .env
  chown www-data:www-data .env 2>/dev/null; chmod 640 .env 2>/dev/null

  msg "Reinstalling composer dependencies..."
  ensure_composer
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader >>"$LOG_FILE" 2>&1
  if [ $? -ne 0 ]; then
    err "Composer install failed during rebuild. Check $LOG_FILE."
    err "Panel is in maintenance mode with fresh files but no vendor/ — fix composer manually, then: php artisan up"
    pause; return
  fi

  "$PHP_BIN" artisan migrate --seed --force >>"$LOG_FILE" 2>&1
  chown -R www-data:www-data ./* 2>/dev/null
  "$PHP_BIN" artisan up >>"$LOG_FILE" 2>&1
  restart_service nginx

  > "$EXT_STATE_FILE"
  line; ok "Blueprint removed and panel restored."
  pause
}
