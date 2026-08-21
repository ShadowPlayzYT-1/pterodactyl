#!/bin/bash
# ================================================================== #
#  panel.sh — Pterodactyl Panel installation (custom, no systemd)     #
#  Sourced by menu.sh. Provides: panel_install()                      #
# ================================================================== #

# run_or_die <description> <command...> — FIX (audit #22): several
# critical artisan steps had their exit codes silently ignored, so one
# failing step (e.g. key:generate) let the installer sail on and report
# "complete" over a broken panel. This wraps a step, logs it, and aborts
# with a clear message if it fails.
_panel_run_or_die() {
  local desc="$1"; shift
  "$@" >>"$LOG_FILE" 2>&1
  if [ $? -ne 0 ]; then
    err "$desc FAILED. Check $LOG_FILE for the exact error."
    pause; return 1
  fi
  return 0
}

panel_install() {
  banner; echo "Panel Install"; line
  msg "Custom installer - no systemd required."
  msg "Auto-configures: timezone (Asia/Kolkata), MariaDB, Redis, Nginx, HTTPS."
  echo ""

  local FQDN EMAIL USERNAME PASSWORD IS_IP="false"
  ask_nonempty FQDN "Panel domain or IP (e.g. panel.yourdomain.com): "
  ask_email EMAIL "Admin email address: "
  ask_nonempty USERNAME "Admin username: "
  ask_password PASSWORD "Admin password: "

  if is_ip_address "$FQDN"; then IS_IP="true"; warn "IP detected - no HTTPS. Panel runs on HTTP."; fi

  local MYSQL_PASSWORD; MYSQL_PASSWORD=$(random_password)
  local PANEL_DIR="/var/www/pterodactyl"
  local APP_URL="http://$FQDN"; [ "$IS_IP" == "false" ] && APP_URL="https://$FQDN"

  line; msg "Starting installation... 5-15 minutes."
  echo "  Domain/IP : $FQDN"; echo "  Timezone  : $DEFAULT_TIMEZONE"
  echo "  Admin     : $USERNAME <$EMAIL>"
  echo "  HTTPS     : $([ "$IS_IP" == "true" ] && echo "no" || echo "yes (Let's Encrypt)")"
  if [ -f /.dockerenv ]; then
    warn "Docker/Codespaces environment detected — if you're behind a Cloudflare"
    warn "Tunnel or reverse proxy, Let's Encrypt will FAIL (that's expected/fine)."
    warn "Your tunnel/proxy handles HTTPS instead. Panel still works over HTTP internally."
  fi
  line

  pre_check_panel

  local PHP_BIN
  PHP_BIN="$(get_php_bin)"
  if [ -z "$PHP_BIN" ] || ! "$PHP_BIN" -v 2>/dev/null | head -1 | grep -q "PHP 8.3"; then
    err "PHP 8.3 is NOT active. This will cause composer/artisan to fail."
    err "Current php: $(php -v 2>/dev/null | head -1 || echo 'not found')"
    err "Attempting force install..."
    ensure_php
    PHP_BIN="$(get_php_bin)"
    if ! "$PHP_BIN" -v 2>/dev/null | head -1 | grep -q "PHP 8.3"; then
      err "PHP 8.3 still not available after force install. Aborting."
      err "Try manually: apt-get install -y php8.3 php8.3-cli php8.3-fpm php8.3-mysql php8.3-zip php8.3-gd php8.3-bcmath php8.3-mbstring php8.3-xml php8.3-curl"
      pause; return 1
    fi
  fi
  ok "PHP verified: $("$PHP_BIN" -v 2>/dev/null | head -1)"

  msg "Starting MariaDB..."; ensure_mariadb_running
  msg "Starting Redis..."; ensure_redis_running
  msg "Starting PHP-FPM..."; ensure_phpfpm_running

  command -v composer >/dev/null 2>&1 || ensure_composer

  msg "Downloading Pterodactyl panel..."
  mkdir -p "$PANEL_DIR"; cd "$PANEL_DIR" || { err "Cannot create $PANEL_DIR"; pause; return 1; }
  curl -Lo panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz" 2>>"$LOG_FILE"
  [ ! -s panel.tar.gz ] && { err "Download failed"; pause; return 1; }
  tar -xzvf panel.tar.gz >>"$LOG_FILE" 2>&1; rm -f panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/; cp .env.example .env
  ok "Panel files downloaded"

  msg "Installing composer dependencies..."
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader >>"$LOG_FILE" 2>&1
  if [ $? -ne 0 ]; then err "Composer failed. Check $LOG_FILE"; pause; return 1; fi
  ok "Dependencies installed"

  # Database (idempotent — safe to re-run)
  msg "Creating database..."
  local DB_OK=1
  mariadb -u root -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$MYSQL_PASSWORD';" >>"$LOG_FILE" 2>&1 || {
    mariadb -u root -e "DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1'; CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$MYSQL_PASSWORD';" >>"$LOG_FILE" 2>&1 || DB_OK=0
  }
  mariadb -u root -e "CREATE DATABASE IF NOT EXISTS panel;" >>"$LOG_FILE" 2>&1 || DB_OK=0
  mariadb -u root -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1'; FLUSH PRIVILEGES;" >>"$LOG_FILE" 2>&1 || DB_OK=0

  if [ "$DB_OK" -eq 1 ]; then
    ok "Database created"
  else
    err "Database creation had critical errors — check $LOG_FILE. Aborting rather than continuing on a broken DB."
    pause; return 1
  fi

  # Configure — FIX (audit #22): every critical artisan step below now
  # aborts on failure instead of silently continuing.
  msg "Configuring panel..."
  _panel_run_or_die "APP_KEY generation" "$PHP_BIN" artisan key:generate --force || return 1
  _panel_run_or_die "Environment setup" "$PHP_BIN" artisan p:environment:setup \
    --author="$EMAIL" --url="$APP_URL" --timezone="$DEFAULT_TIMEZONE" \
    --cache="redis" --session="redis" --queue="redis" --redis-host="localhost" \
    --redis-pass="null" --redis-port="6379" --telemetry="true" --settings-ui=true || return 1
  _panel_run_or_die "Database environment setup" "$PHP_BIN" artisan p:environment:database \
    --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="$MYSQL_PASSWORD" || return 1
  msg "Running migrations..."
  _panel_run_or_die "Migrations" "$PHP_BIN" artisan migrate --seed --force || return 1
  msg "Creating admin user..."
  "$PHP_BIN" artisan p:user:make --email="$EMAIL" --username="$USERNAME" --name-first="Admin" --name-last="User" --password="$PASSWORD" --admin=1 >>"$LOG_FILE" 2>&1
  if [ $? -ne 0 ]; then
    err "Admin user creation failed (exit code $?). Panel is otherwise installed — fix with [8] Add Admin User once it's up."
  else
    ok "Admin user created"
  fi
  ok "Panel configured"

  # Permissions + cron. FIX (audit #5): the previous chown pattern used
  # "$PANEL_DIR"/* which glob-excludes dotfiles — meaning .env (which
  # holds APP_KEY, DB password, Redis config) was never actually chowned
  # or permission-hardened. Fixed explicitly below.
  chown -R www-data:www-data "$PANEL_DIR" >>"$LOG_FILE" 2>&1
  chown www-data:www-data "$PANEL_DIR/.env" 2>/dev/null
  chmod 640 "$PANEL_DIR/.env" 2>/dev/null
  (crontab -l 2>/dev/null; echo "* * * * * $PHP_BIN $PANEL_DIR/artisan schedule:run >> /dev/null 2>&1") | crontab -
  ok "Permissions + cron set (.env locked to 640, www-data:www-data)"

  # Nginx. FIX (audit #23): "Nginx configured" used to print unconditionally
  # even if `nginx -t` failed — now it's gated on the actual test result.
  msg "Configuring Nginx..."
  local NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  cat > "$NGINX_CONF" << 'NGINXCONF'
server {
    listen 80;
    listen [::]:80;
    server_name __FQDN__;
    root __PANEL_DIR__/public;
    index index.html index.htm index.php;
    charset utf-8;
    location / { try_files $uri $uri/ /index.php?$query_string; }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt { access_log off; log_not_found off; }
    access_log off;
    error_log /var/log/nginx/pterodactyl.app-error.log error;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }
    location ~ /\.ht { deny all; }
}
NGINXCONF
  sed -i "s@__FQDN__@$FQDN@g" "$NGINX_CONF"
  sed -i "s@__PANEL_DIR__@$PANEL_DIR@g" "$NGINX_CONF"
  ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pterodactyl.conf
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null

  if nginx -t >>"$LOG_FILE" 2>&1; then
    start_service nginx
    ok "Nginx configured"
  else
    err "Nginx config test FAILED — panel will not be reachable until this is fixed."
    err "Check $LOG_FILE, then: nginx -t   (to see the exact error)"
  fi

  # Let's Encrypt. FIX (audit #6): if Certbot fails/times out, APP_URL in
  # .env previously stayed "https://..." even though Nginx never got a
  # cert, causing redirect loops / broken session cookies. Now we actively
  # rewrite APP_URL back to http:// on failure so .env matches reality.
  if [ "$IS_IP" == "false" ]; then
    msg "Configuring Let's Encrypt (30s timeout, won't hang)..."
    if timeout 30 certbot --nginx --redirect --no-eff-email --email "$EMAIL" -d "$FQDN" --non-interactive >>"$LOG_FILE" 2>&1; then
      ok "HTTPS configured"; save_state USE_SSL "yes"
    else
      warn "Let's Encrypt didn't complete in 30s — likely DNS not pointing here yet,"
      warn "or you're behind Cloudflare/a tunnel (which is fine, it handles HTTPS itself)."
      warn "Panel runs on HTTP for now — correcting APP_URL in .env to match."
      sed -i "s#^APP_URL=.*#APP_URL=http://$FQDN#" "$PANEL_DIR/.env" 2>/dev/null
      "$PHP_BIN" artisan config:clear >>"$LOG_FILE" 2>&1
      save_state USE_SSL "no"
    fi
  else save_state USE_SSL "no"; fi

  # Queue worker
  msg "Starting queue worker..."
  pkill -f "artisan queue:work" 2>/dev/null || true
  nohup "$PHP_BIN" "$PANEL_DIR/artisan" queue:work --queue=high,standard,low --sleep=3 --tries=3 >>"$LOG_FILE" 2>&1 &
  ok "Queue worker started"

  # Reliability: since there's no systemd here, install a cron watchdog so
  # a crashed/killed queue worker (or, later, Wings) gets auto-restarted.
  install_watchdog_cron

  save_state FQDN "$FQDN"; save_state PANEL_DIR "$PANEL_DIR"; save_state MYSQL_PASSWORD "$MYSQL_PASSWORD"
  line; ok "Panel installation complete!"
  echo ""
  local FINAL_SCHEME="https"; [ "$(load_state USE_SSL)" == "no" ] && FINAL_SCHEME="http"
  echo "  Panel URL : $FINAL_SCHEME://$FQDN"
  echo "  Login     : $EMAIL / (password you set)"; echo ""
  msg "If anything looks down, restart services manually:"
  msg "  service nginx restart && service php8.3-fpm restart"
  msg "  nohup $PHP_BIN $PANEL_DIR/artisan queue:work --queue=high,standard,low &"
  pause
}
