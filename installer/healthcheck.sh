#!/bin/bash
# ================================================================== #
#  healthcheck.sh — Diagnose + auto-repair common panel issues        #
#  Sourced by menu.sh. Provides: health_check()                     #
# ================================================================== #

health_check() {
  banner; echo "Health Check"; line
  msg "Running full diagnostic..."
  echo ""

  local PD; PD="$(get_panel_dir)"
  local PHP_BIN; PHP_BIN="$(get_php_bin)"
  local ISSUES=0

  # --- 1. Panel directory --- #
  if [ -z "$PD" ] || [ ! -d "$PD" ]; then
    err "Panel directory not found."
    ISSUES=$((ISSUES+1))
  else
    ok "Panel directory: $PD"
  fi

  # --- 2. .env file --- #
  if [ -n "$PD" ] && [ ! -f "$PD/.env" ]; then
    err ".env file missing — panel cannot run without it."
    ISSUES=$((ISSUES+1))
  elif [ -n "$PD" ]; then
    ok ".env file present"
  fi

  # --- 3. Services --- #
  for svc in mariadb redis phpfpm nginx; do
    if is_running "$svc"; then
      ok "$svc is running"
    else
      warn "$svc is NOT running — attempting to start..."
      case "$svc" in
        mariadb) ensure_mariadb_running ;;
        redis)   ensure_redis_running ;;
        phpfpm)  ensure_phpfpm_running ;;
        nginx)   start_service nginx; ensure_nginx_running ;;
      esac
      is_running "$svc" && ok "$svc recovered" || { err "$svc still down — check $LOG_FILE"; ISSUES=$((ISSUES+1)); }
    fi
  done

  # --- 4. Queue worker --- #
  if is_running queue; then
    ok "Queue worker is running"
  else
    warn "Queue worker not running — starting it..."
    if [ -n "$PD" ]; then
      nohup "$PHP_BIN" "$PD/artisan" queue:work --queue=high,standard,low --sleep=3 --tries=3 >>"$LOG_FILE" 2>&1 &
      sleep 1
      is_running queue && ok "Queue worker started" || warn "Could not confirm queue worker started"
    fi
  fi

  # --- 5. PHP version sanity --- #
  if command -v php >/dev/null 2>&1; then
    local phpver; phpver=$(php -v 2>/dev/null | head -1)
    if [[ "$phpver" == *"PHP 8.3"* ]] || [[ "$phpver" == *"PHP 8.2"* ]]; then
      ok "PHP version OK: $phpver"
    else
      warn "PHP version may be incompatible: $phpver"
      warn "If a custom PHP install is shadowing apt's PHP, this can break composer/artisan."
      ISSUES=$((ISSUES+1))
    fi
  else
    err "PHP not found at all."
    ISSUES=$((ISSUES+1))
  fi

  # --- 6. File permissions --- #
  if [ -n "$PD" ] && [ -d "$PD" ]; then
    local owner; owner=$(stat -c '%U' "$PD/storage" 2>/dev/null)
    if [ "$owner" != "www-data" ]; then
      warn "Panel files not owned by www-data (found: $owner) — fixing..."
      chown -R www-data:www-data "$PD" 2>/dev/null
      ok "Ownership fixed"
    else
      ok "File ownership OK (www-data)"
    fi
  fi

  # --- 7. Nginx config test --- #
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >>"$LOG_FILE" 2>&1; then
      ok "Nginx config valid"
    else
      err "Nginx config has errors — check $LOG_FILE"
      ISSUES=$((ISSUES+1))
    fi
  fi

  # --- 8. Docker/Codespaces environment notice --- #
  if [ -f /.dockerenv ]; then
    warn "Running inside a Docker/Codespaces container. Known gotchas:"
    warn "  - Let's Encrypt will fail if you're behind Cloudflare/a tunnel (expected, harmless)"
    warn "  - No systemd — this installer uses 'service'/nohup instead (already handled)"
    warn "  - Blueprint has a Docker-path bug — our installer patches it automatically"
    warn "    envs — our installer patches that automatically during [6] Install Blueprint"
  fi

  # --- 9. Blueprint sanity (if installed) --- #
  if command -v blueprint >/dev/null 2>&1 && [ -n "$PD" ]; then
    if [ -f "$PD/.blueprint/extensions/blueprint/private/db/is_installed" ]; then
      ok "Blueprint installed and marked complete"
    else
      warn "Blueprint command exists but install marker missing — install may have failed midway."
      warn "Recommended: Uninstall Blueprint (Themes & Extensions -> [6]), then Install Blueprint (Themes & Extensions -> [1]) again."
      ISSUES=$((ISSUES+1))
    fi
  fi

  # --- 10. Panel HTTP self-test --- #
  if command -v curl >/dev/null 2>&1; then
    local code; code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:80 2>/dev/null)
    if [ "$code" == "200" ] || [ "$code" == "302" ]; then
      ok "Panel responds locally (HTTP $code)"
    else
      err "Panel not responding locally (HTTP $code) — likely a 500 or nginx/php-fpm issue"
      msg "Check the actual error: tail -50 /var/log/nginx/pterodactyl.app-error.log"
      msg "Or: tail -50 $PD/storage/logs/laravel-*.log"
      ISSUES=$((ISSUES+1))
    fi
  fi

  line
  if [ "$ISSUES" -eq 0 ]; then
    ok "All checks passed. Panel looks healthy."
  else
    warn "$ISSUES issue(s) found. Auto-fixed what we could — re-run Health Check to confirm."
  fi
  pause
}
