#!/bin/bash
# ================================================================== #
#  uninstall.sh — Panel + Wings uninstall (custom, no systemd)        #
#  Sourced by menu.sh. Provides: uninstall_panel(),                  #
#  uninstall_wings()                                                #
# ================================================================== #

uninstall_panel() {
  banner; echo "Uninstall Panel"; line
  warn "This permanently deletes the panel, its database and web server config."
  echo ""
  read -r -p "Type CONFIRM to proceed: " C
  [ "$C" != "CONFIRM" ] && { warn "Cancelled."; pause; return; }

  msg "Stopping queue worker..."
  pkill -f "artisan queue:work" 2>/dev/null || true

  msg "Removing panel files..."
  rm -rf /var/www/pterodactyl
  rm -f /usr/local/bin/composer

  # Remove nginx config
  [ -L /etc/nginx/sites-enabled/pterodactyl.conf ] && unlink /etc/nginx/sites-enabled/pterodactyl.conf
  rm -f /etc/nginx/sites-available/pterodactyl.conf
  # Restore default site
  [ ! -L /etc/nginx/sites-enabled/default ] && [ -f /etc/nginx/sites-available/default ] && ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  restart_service nginx

  msg "Removing cronjob..."
  crontab -l 2>/dev/null | grep -vF "* * * * * php /var/www/pterodactyl/artisan schedule:run" | crontab - 2>/dev/null || true

  # FIX: remove the watchdog cron + script too
  crontab -l 2>/dev/null | grep -vF "pterodactyl-watchdog.sh" | crontab - 2>/dev/null || true
  rm -f /usr/local/bin/pterodactyl-watchdog.sh 2>/dev/null

  # Start MariaDB if needed for DB cleanup
  if ! mariadb -u root -e "SELECT 1" >/dev/null 2>&1; then
    msg "Starting MariaDB for database cleanup..."
    start_service mariadb
  fi

  msg "Removing database..."
  if mariadb -u root -e "SELECT 1" >/dev/null 2>&1; then
    mariadb -u root -e "DROP DATABASE IF EXISTS panel;" 2>/dev/null || true
    mariadb -u root -e "DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';" 2>/dev/null || true
    mariadb -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    ok "Database 'panel' and user 'pterodactyl' removed"
  else
    warn "Could not connect to MariaDB - database not removed."
  fi

  # Clean up service files + state
  rm -f /etc/systemd/system/pteroq.service 2>/dev/null
  rm -f "$STATE_FILE"
  > "$EXT_STATE_FILE"

  line
  ok "Panel uninstall complete."
  pause
}

uninstall_wings() {
  banner; echo "Uninstall Wings (Node)"; line
  warn "This removes Wings and all servers running on this node!"
  echo ""
  read -r -p "Type CONFIRM to proceed: " C
  [ "$C" != "CONFIRM" ] && { warn "Cancelled."; pause; return; }

  msg "Stopping Wings..."
  pkill -f "/usr/local/bin/wings" 2>/dev/null || true

  msg "Removing Wings files..."
  rm -f /usr/local/bin/wings
  rm -f /etc/systemd/system/wings.service 2>/dev/null
  rm -rf /etc/pterodactyl
  rm -rf /var/lib/pterodactyl

  msg "Removing Docker containers..."
  docker system prune -a -f 2>/dev/null || true

  # FIX: remove watchdog cron entry for Wings (keep panel watchdog if panel still exists)
  crontab -l 2>/dev/null | grep -vF "pterodactyl-watchdog.sh" | crontab - 2>/dev/null || true
  rm -f /usr/local/bin/pterodactyl-watchdog.sh 2>/dev/null

  line
  ok "Wings uninstall complete."
  pause
}
