#!/bin/bash
# ================================================================== #
#  admin.sh — Add admin user to existing panel                        #
#  Sourced by menu.sh. Provides: add_admin_user()                    #
#                                                                    #
#  Pre-check: Panel must exist + PHP must be installed.              #
# ================================================================== #

add_admin_user() {
  banner; echo "Add Admin User"; line

  panel_exists_or_die || return
  ensure_php

  local PHP_BIN
  PHP_BIN="$(get_php_bin)"
  if [ -z "$PHP_BIN" ] || ! "$PHP_BIN" -v 2>/dev/null | head -1 | grep -q "PHP 8.3"; then
    err "PHP 8.3 not available. Cannot create admin user."
    pause; return
  fi

  local PANEL_DIR
  PANEL_DIR="$(get_panel_dir)"
  msg "Panel directory: $PANEL_DIR"

  local EMAIL USERNAME FIRST="Admin" LAST="User" PASSWORD
  ask_email EMAIL "New admin email: "
  ask_nonempty USERNAME "New admin username: "
  ask_password PASSWORD "New admin password: "

  cd "$PANEL_DIR" || { err "Panel directory not found: $PANEL_DIR"; pause; return; }

  "$PHP_BIN" artisan p:user:make \
    --email="$EMAIL" \
    --username="$USERNAME" \
    --name-first="$FIRST" \
    --name-last="$LAST" \
    --password="$PASSWORD" \
    --admin=1 2>&1 | tee -a "$LOG_FILE"

  # FIX (audit #21): the command's exit status was never checked — a
  # duplicate email/username, invalid input, or DB error would still print
  # "created" because we always printed success unconditionally.
  local EXIT=${PIPESTATUS[0]}
  line
  if [ "$EXIT" -eq 0 ]; then
    ok "Admin user $USERNAME <$EMAIL> created."
  else
    err "Failed to create admin user (exit code $EXIT). See output above / $LOG_FILE."
    err "Common causes: duplicate email/username, or a database connection issue."
  fi
  pause
}
