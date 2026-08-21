#!/bin/bash
# ================================================================== #
#  service.sh — Start/stop/restart controls for Panel + Wings         #
#  Sourced by menu.sh. Provides: manage_panel_services(),             #
#  manage_wings_service()                                            #
# ================================================================== #

_panel_status_line() {
  local name="$1" key="$2"
  if is_running "$key"; then
    echo -e "  ${C_GREEN}●${C_NC} $name — running"
  else
    echo -e "  ${C_RED}●${C_NC} $name — stopped"
  fi
}

start_panel_stack() {
  msg "Starting panel services..."
  ensure_mariadb_running
  ensure_redis_running
  ensure_phpfpm_running
  start_service nginx; ensure_nginx_running
  local PD; PD="$(get_panel_dir)"
  if [ -n "$PD" ] && ! is_running queue; then
    nohup "$(get_php_bin)" "$PD/artisan" queue:work --queue=high,standard,low --sleep=3 --tries=3 >>"$LOG_FILE" 2>&1 &
    ok "Queue worker started"
  fi
}

stop_panel_stack() {
  msg "Stopping panel services..."
  stop_service pteroq
  stop_service nginx
  stop_service php8.3-fpm
  stop_service redis-server
  stop_service mariadb
  ok "Panel services stopped"
}

restart_panel_stack() {
  stop_panel_stack
  sleep 1
  start_panel_stack
  ok "Panel services restarted"
}

manage_panel_services() {
  while true; do
    banner; echo "Manage Panel Services"; line
    _panel_status_line "MariaDB"  mariadb
    _panel_status_line "Redis"    redis
    _panel_status_line "PHP-FPM"  phpfpm
    _panel_status_line "Nginx"    nginx
    _panel_status_line "Queue"    queue
    line
    echo " [1] Start all"
    echo " [2] Stop all"
    echo " [3] Restart all"
    echo " [4] Restart Nginx only"
    echo " [5] Restart PHP-FPM only"
    echo " [6] Restart Queue worker only"
    echo " [0] Back"
    line
    read -r -p "Select an option: " C
    case "$C" in
      1) start_panel_stack; pause ;;
      2) stop_panel_stack; pause ;;
      3) restart_panel_stack; pause ;;
      4) restart_service nginx; ok "Nginx restarted"; pause ;;
      5) restart_service php8.3-fpm; ok "PHP-FPM restarted"; pause ;;
      6) stop_service pteroq; local PD; PD="$(get_panel_dir)"; nohup "$(get_php_bin)" "$PD/artisan" queue:work --queue=high,standard,low --sleep=3 --tries=3 >>"$LOG_FILE" 2>&1 & ok "Queue worker restarted"; pause ;;
      0) return ;;
      *) warn "Invalid option."; sleep 1 ;;
    esac
  done
}

manage_wings_service() {
  while true; do
    banner; echo "Manage Wings (Node Daemon)"; line
    _panel_status_line "Docker" docker
    _panel_status_line "Wings"  wings
    line
    echo " [1] Start Wings"
    echo " [2] Stop Wings"
    echo " [3] Restart Wings"
    echo " [0] Back"
    line
    read -r -p "Select an option: " C
    case "$C" in
      1)
        command -v wings >/dev/null 2>&1 || { err "Wings not installed. Use [2] Node Install first."; pause; continue; }
        docker info >/dev/null 2>&1 || (dockerd >"$LOG_FILE" 2>&1 &)
        nohup /usr/local/bin/wings >>"$LOG_FILE" 2>&1 &
        sleep 2; ok "Wings started"; pause ;;
      2) stop_service wings; ok "Wings stopped"; pause ;;
      3) stop_service wings; sleep 1; nohup /usr/local/bin/wings >>"$LOG_FILE" 2>&1 & sleep 2; ok "Wings restarted"; pause ;;
      0) return ;;
      *) warn "Invalid option."; sleep 1 ;;
    esac
  done
}
