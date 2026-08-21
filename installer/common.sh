#!/bin/bash
# ================================================================== #
#  common.sh — Shared functions, config, UI, state, service mgmt     #
#  Sourced by all other scripts. Do NOT run directly.                 #
# ================================================================== #

# ------------------------- Config -------------------------- #
REPO_RAW="https://raw.githubusercontent.com/ShadowPlayzYT-1/pterodactyl/main"
SCRIPT_DIR="/tmp/pterodactyl-easy-installer"

STATE_DIR="/etc/pterodactyl-easy-installer"
STATE_FILE="$STATE_DIR/state.conf"
EXT_STATE_FILE="$STATE_DIR/installed_extensions"
LOG_FILE="/var/log/pterodactyl-easy-installer.log"

DEFAULT_TIMEZONE="Asia/Kolkata"
DEFAULT_PANEL_DIR="/var/www/pterodactyl"

# --- Fix: ensure apt-installed PHP 8.3 is used, not custom PHP --- #
export PATH="/usr/bin:/usr/sbin:$PATH"
if [ -e /usr/bin/php8.3 ]; then
  CURRENT_PHP="/usr/bin/php"
  if [ ! -e "$CURRENT_PHP" ] || ! "$CURRENT_PHP" -v 2>/dev/null | grep -q "PHP 8.3"; then
    ln -sf /usr/bin/php8.3 /usr/bin/php 2>/dev/null || true
  fi
fi

# --------------------------- UI ------------------------------ #
C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_NC='\033[0m'

msg()   { echo -e "${C_CYAN}*${C_NC} $1"; }
ok()    { echo -e "${C_GREEN}✔${C_NC} $1"; }
warn()  { echo -e "${C_YELLOW}!${C_NC} $1"; }
err()   { echo -e "${C_RED}✘${C_NC} $1" 1>&2; }
line()  { echo -e "${C_CYAN}------------------------------------------------------------${C_NC}"; }
pause() { echo ""; read -r -p "Press [Enter] to return to the menu..." _; }

# FIX: banner ASCII was missing a space in the "X" glyph (line 4), making
# it render slightly lopsided. Fixed to match the other letters' spacing.
banner() {
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

# --------------------- State management ---------------------- #
# FIX (security audit #4): state dir/file can contain the generated
# MySQL password and, now, an Application API key. Lock permissions down
# so only root can read them.
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true
touch "$EXT_STATE_FILE"
chmod 600 "$EXT_STATE_FILE" 2>/dev/null || true

save_state() {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true
  touch "$STATE_FILE"
  grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
  mv "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null || true
  echo "$1=$2" >> "$STATE_FILE"
  chmod 600 "$STATE_FILE" 2>/dev/null || true
}

load_state() {
  [ -f "$STATE_FILE" ] || return 0
  grep "^$1=" "$STATE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2-
}

get_panel_dir() {
  local d; d="$(load_state PANEL_DIR)"
  if [ -n "$d" ] && [ -d "$d" ]; then echo "$d"
  elif [ -d "$DEFAULT_PANEL_DIR" ]; then echo "$DEFAULT_PANEL_DIR"
  else echo ""; fi
}

# ----------------------- Helpers ----------------------------- #
require_root() {
  if [ "$EUID" -ne 0 ]; then
    err "This script must be run as root. Try: sudo bash menu.sh"
    exit 1
  fi
}

is_ip_address() {
  [ "$1" == "localhost" ] && return 0
  # Validate IPv4 with octet range check (rejects 999.999.999.999 etc.)
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for octet in "${BASH_REMATCH[@]:1:4}"; do
    [ "$octet" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

random_password() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }

valid_email_re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'

ask_nonempty() {
  local __v="$1" __p="$2" __r=""
  while [ -z "$__r" ]; do read -r -p "$__p" __r; [ -z "$__r" ] && err "This cannot be empty."; done
  printf -v "$__v" '%s' "$__r"
}

ask_email() {
  local __v="$1" __p="$2" __r=""
  while true; do read -r -p "$__p" __r; [[ "$__r" =~ $valid_email_re ]] && break; err "Please enter a valid email address."; done
  printf -v "$__v" '%s' "$__r"
}

ask_password() {
  local __v="$1" __p="$2" __r="" __r2=""
  while true; do
    read -r -s -p "$__p" __r; echo
    [ -z "$__r" ] && { err "Password cannot be empty."; continue; }
    read -r -s -p "Confirm password: " __r2; echo
    [ "$__r" != "$__r2" ] && { err "Passwords do not match."; continue; }
    break
  done
  printf -v "$__v" '%s' "$__r"
}

# ================================================================ #
#  DEPENDENCY AUTO-CHECK / AUTO-INSTALL                             #
#  Called at the start of every action, before doing real work.    #
# ================================================================ #

ensure_pkg() {
  local cmd="$1" pkg="${2:-$1}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    msg "Missing dependency '$cmd' — installing $pkg..."
    apt-get update -y >>"$LOG_FILE" 2>&1
    apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1
    if command -v "$cmd" >/dev/null 2>&1; then
      ok "$cmd installed"
    else
      warn "Could not auto-install $cmd (package: $pkg). Check $LOG_FILE"
      return 1
    fi
  fi
  return 0
}

ensure_base_tools() {
  ensure_pkg curl curl
  ensure_pkg wget wget
  ensure_pkg unzip unzip
  ensure_pkg zip zip
  ensure_pkg git git
  ensure_pkg tar tar
  ensure_pkg gpg gnupg
  ensure_pkg lsb_release lsb-release
}

ensure_base_deps() { ensure_base_tools; }

# check_os_supported — warns (does not hard-block) if the distro isn't one
# we've actually tested (audit #11/#12: blindly adding Debian repos or
# guessing Docker's repo on an unknown distro can break APT).
check_os_supported() {
  local os_id="" os_ver=""
  if [ -f /etc/os-release ]; then
    os_id="$(. /etc/os-release; echo "$ID")"
    os_ver="$(. /etc/os-release; echo "$VERSION_ID")"
  fi
  case "$os_id" in
    ubuntu)
      case "$os_ver" in 20.04|22.04|24.04) return 0 ;; esac ;;
    debian)
      case "$os_ver" in 11|12) return 0 ;; esac ;;
  esac
  warn "Untested OS detected: ${os_id:-unknown} ${os_ver:-unknown}."
  warn "This installer is tested on Ubuntu 20.04/22.04/24.04 and Debian 11/12."
  warn "Continuing anyway, but APT repo setup (PHP/Docker) may behave unexpectedly."
  return 1
}

# ensure_php — makes sure PHP 8.3 + required extensions are present.
# CRITICAL: checks for PHP 8.3 SPECIFICALLY, not just "any PHP".
# Environments like Codespaces have custom PHP 8.4 that shadows the system
# PHP. If we don't install 8.3 and force the symlink, composer/artisan fail
# because 8.4 is missing extensions Pterodactyl needs.
ensure_php() {
  local NEED_83=false

  if [ ! -e /usr/bin/php8.3 ]; then
    NEED_83=true
  fi

  if command -v php >/dev/null 2>&1; then
    if ! php -v 2>/dev/null | head -1 | grep -q "PHP 8.3"; then
      if [ ! -e /usr/bin/php8.3 ]; then
        NEED_83=true
      fi
    fi
  else
    NEED_83=true
  fi

  if [ "$NEED_83" == "true" ]; then
    msg "PHP 8.3 not available — installing from sury repo..."
    check_os_supported
    apt-get update -y >>"$LOG_FILE" 2>&1
    apt-get install -y software-properties-common ca-certificates gnupg curl >>"$LOG_FILE" 2>&1
    command -v add-apt-repository >/dev/null 2>&1 && add-apt-repository universe -y >>"$LOG_FILE" 2>&1
    curl -o /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg 2>>"$LOG_FILE"
    local os_codename; os_codename="$(lsb_release -sc 2>/dev/null)"
    [ -z "$os_codename" ] && os_codename="bookworm"
    echo "deb https://packages.sury.org/php/ $os_codename main" | tee /etc/apt/sources.list.d/php.list >/dev/null
    apt-get update -y >>"$LOG_FILE" 2>&1
    apt-get install -y php8.3 php8.3-cli php8.3-common php8.3-gd php8.3-mysql \
      php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-fpm php8.3-curl \
      php8.3-zip >>"$LOG_FILE" 2>&1
  fi

  if [ -e /usr/bin/php8.3 ]; then
    ln -sf /usr/bin/php8.3 /usr/bin/php
    if /usr/bin/php -v 2>/dev/null | head -1 | grep -q "PHP 8.3"; then
      ok "PHP 8.3 active: $(/usr/bin/php -v 2>/dev/null | head -1)"
    else
      warn "Symlink created but /usr/bin/php reports wrong version — custom PHP may shadow it"
      warn "Will use /usr/bin/php8.3 directly for artisan/composer commands"
    fi
  else
    err "PHP 8.3 installation FAILED — /usr/bin/php8.3 not found after apt-get install"
    err "Check $LOG_FILE for apt errors. The sury repo may not be available for your distro."
    return 1
  fi

  for ext in pdo_mysql zip bcmath sodium gd mbstring xml curl; do
    ensure_php_ext "$ext"
  done

  return 0
}

# get_php_bin — returns the correct PHP 8.3 binary path.
# Used by panel.sh and other scripts to avoid PATH shadowing issues.
get_php_bin() {
  if [ -e /usr/bin/php8.3 ] && /usr/bin/php8.3 -v 2>/dev/null | head -1 | grep -q "PHP 8.3"; then
    echo "/usr/bin/php8.3"
  elif command -v php >/dev/null 2>&1 && php -v 2>/dev/null | head -1 | grep -q "PHP 8.3"; then
    echo "php"
  else
    echo "php"
  fi
}

# ensure_php_ext — FIX: correctly maps extension name -> apt package name
# (pdo_mysql ships in php8.3-mysql, not a nonexistent php8.3-pdo_mysql
# package), and checks/queries via the real php8.3 binary so a shadowing
# custom PHP (e.g. 8.4) doesn't produce false "missing" reports.
ensure_php_ext() {
  local ext="$1" pkg
  case "$ext" in
    pdo_mysql) pkg="php8.3-mysql" ;;
    *) pkg="php8.3-$ext" ;;
  esac
  local php_bin="php"
  [ -e /usr/bin/php8.3 ] && php_bin="/usr/bin/php8.3"

  if $php_bin -m 2>/dev/null | grep -qi "^$ext$"; then
    ok "php-$ext already loaded"
    return 0
  fi
  msg "php-$ext missing — installing $pkg..."
  apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1
  if $php_bin -m 2>/dev/null | grep -qi "^$ext$"; then
    ok "php-$ext installed"
    return 0
  fi
  warn "php-$ext not available as $pkg (may be bundled in php8.3-common)"
  return 0
}

# ensure_composer — installs Composer if missing.
ensure_composer() {
  if ! command -v composer >/dev/null 2>&1; then
    msg "Installing Composer..."
    curl -sS https://getcomposer.org/installer 2>>"$LOG_FILE" | "$(get_php_bin)" -- --install-dir=/usr/local/bin --filename=composer >>"$LOG_FILE" 2>&1
  fi
  command -v composer >/dev/null 2>&1 && ok "Composer ready" || warn "Composer install failed. Check $LOG_FILE"
}

# ensure_node22 — installs Node.js 22.x if missing or wrong version.
ensure_node22() {
  if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null)" != v22* ]]; then
    msg "Installing Node.js 22..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key 2>>"$LOG_FILE" | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg 2>>"$LOG_FILE"
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list >/dev/null
    apt-get update -y >>"$LOG_FILE" 2>&1
    apt-get install -y nodejs >>"$LOG_FILE" 2>&1
  fi
  command -v node >/dev/null 2>&1 && ok "Node.js: $(node -v 2>/dev/null)" || warn "Node.js install failed. Check $LOG_FILE"
}

# ensure_yarn — installs Yarn (via npm) if missing.
ensure_yarn() {
  if ! command -v yarn >/dev/null 2>&1; then
    msg "Installing Yarn..."
    npm i -g yarn >>"$LOG_FILE" 2>&1
  fi
  command -v yarn >/dev/null 2>&1 && ok "Yarn ready" || warn "Yarn install failed. Check $LOG_FILE"
}

# ensure_docker — installs Docker CE if missing.
# FIX (audit #12): don't blindly guess the distro for the repo URL — use
# /etc/os-release ID_LIKE when lsb_release is unavailable, and warn instead
# of silently defaulting to ubuntu on an unrelated distro.
ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    msg "Installing Docker..."
    check_os_supported
    apt-get update -y >>"$LOG_FILE" 2>&1
    apt-get install -y ca-certificates gnupg lsb-release curl >>"$LOG_FILE" 2>&1
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg 2>>"$LOG_FILE" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg 2>>"$LOG_FILE"
    local os_distro
    os_distro=$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ -z "$os_distro" ] && [ -f /etc/os-release ]; then
      os_distro="$(. /etc/os-release; echo "$ID")"
    fi
    if [ -z "$os_distro" ]; then
      warn "Could not detect distro — defaulting Docker repo to 'debian'. If this fails, install Docker manually."
      os_distro="debian"
    fi
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$os_distro $(lsb_release -cs 2>/dev/null) stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null
    apt-get update -y >>"$LOG_FILE" 2>&1
    apt-get install -y docker-ce docker-ce-cli containerd.io >>"$LOG_FILE" 2>&1
  fi
  command -v docker >/dev/null 2>&1 && ok "Docker ready" || warn "Docker install failed. Check $LOG_FILE"
}

# ensure_mariadb_running — starts MariaDB, initializes if needed.
ensure_mariadb_running() {
  if ! mariadb -u root -e "SELECT 1" >/dev/null 2>&1; then
    start_service mariadb
    if ! mariadb -u root -e "SELECT 1" >/dev/null 2>&1; then
      mariadb-install-db --user=mysql >>"$LOG_FILE" 2>&1
      start_service mariadb
    fi
  fi
  mariadb -u root -e "SELECT 1" >/dev/null 2>&1 && ok "MariaDB running" || warn "MariaDB could not be started. Check $LOG_FILE"
}

ensure_redis_running()  { pgrep -f redis-server >/dev/null 2>&1 || start_service redis-server; pgrep -f redis-server >/dev/null 2>&1 && ok "Redis running" || warn "Redis not running"; }

ensure_phpfpm_running() {
  if ! dpkg -l php8.3-fpm 2>/dev/null | grep -q "^ii"; then
    msg "Installing php8.3-fpm..."
    apt-get install -y php8.3-fpm >>"$LOG_FILE" 2>&1
  fi
  if pgrep -f php-fpm >/dev/null 2>&1; then
    ok "PHP-FPM already running"
    return 0
  fi
  start_service php8.3-fpm
  sleep 1
  if pgrep -f php-fpm >/dev/null 2>&1; then
    ok "PHP-FPM running"
  else
    if [ -x /usr/sbin/php-fpm8.3 ]; then
      /usr/sbin/php-fpm8.3 --daemonize 2>>"$LOG_FILE" || { /usr/sbin/php-fpm8.3 2>>"$LOG_FILE" & }
      sleep 1
    fi
    pgrep -f php-fpm >/dev/null 2>&1 && ok "PHP-FPM running" || warn "PHP-FPM not running"
  fi
}

ensure_nginx_running()  { pgrep -x nginx >/dev/null 2>&1 || start_service nginx; pgrep -x nginx >/dev/null 2>&1 && ok "Nginx running" || warn "Nginx not running"; }

# ----------- Service management (non-systemd) --------------- #
prevent_service_start() {
  cat > /usr/sbin/policy-rc.d << 'EOF'
#!/bin/sh
exit 101
EOF
  chmod +x /usr/sbin/policy-rc.d
}

allow_service_start() { rm -f /usr/sbin/policy-rc.d; }

start_service() {
  local svc="$1"
  service "$svc" start 2>/dev/null && return 0
  case "$svc" in
    mariadb|mysql)
      mkdir -p /run/mysqld && chown mysql:mysql /run/mysqld 2>/dev/null
      mariadbd --user=mysql --daemonize 2>/dev/null || mysqld --user=mysql --daemonize 2>/dev/null || true
      for i in $(seq 1 15); do mariadb -u root -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done ;;
    redis-server|redis) redis-server --daemonize yes 2>/dev/null || true ;;
    nginx) nginx 2>/dev/null || true ;;
    php8.3-fpm|php-fpm) php-fpm8.3 --daemonize 2>/dev/null || php-fpm8.3 2>/dev/null || true ;;
  esac
}

stop_service() {
  local svc="$1"
  service "$svc" stop 2>/dev/null || true
  case "$svc" in
    redis-server|redis) pkill -f redis-server 2>/dev/null || true ;;
    mariadb|mysql) pkill -f mariadbd 2>/dev/null || true ;;
    nginx) nginx -s stop 2>/dev/null || pkill nginx 2>/dev/null || true ;;
    php8.3-fpm|php-fpm) pkill -f php-fpm 2>/dev/null || true ;;
    pteroq|queue) pkill -f "artisan queue:work" 2>/dev/null || true ;;
    wings) pkill -f "/usr/local/bin/wings" 2>/dev/null || true ;;
  esac
}

restart_service() { stop_service "$1"; sleep 1; start_service "$1"; }

# is_running <name> — true/false check used by health check & status display.
is_running() {
  case "$1" in
    mariadb) mariadb -u root -e "SELECT 1" >/dev/null 2>&1 ;;
    redis)   redis-cli ping >/dev/null 2>&1 || pgrep -f redis-server >/dev/null 2>&1 ;;
    nginx)   pgrep -x nginx >/dev/null 2>&1 ;;
    phpfpm)  pgrep -f php-fpm >/dev/null 2>&1 ;;
    queue)   pgrep -f "artisan queue:work" >/dev/null 2>&1 ;;
    wings)   pgrep -f "/usr/local/bin/wings" >/dev/null 2>&1 ;;
    docker)  docker info >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# ================================================================== #
#  RELIABILITY: cron-based watchdog (systemd alternative)             #
#  Audit #18/#19: Wings and the queue worker were started with nohup #
#  and never supervised — a crash or reboot meant they stayed down   #
#  forever. Since this installer explicitly supports environments    #
#  without systemd (Codespaces/Docker/chroot), we use a cron-based    #
#  watchdog instead: checks every minute, restarts if down.          #
# ================================================================== #
install_watchdog_cron() {
  local WATCHDOG="/usr/local/bin/pterodactyl-watchdog.sh"
  cat > "$WATCHDOG" << 'WDEOF'
#!/bin/bash
# Auto-generated by NextDev Pterodactyl Easy Installer. Restarts Wings
# and the panel queue worker if they've died. Runs every minute via cron.
LOG_FILE="/var/log/pterodactyl-easy-installer.log"

# Wings
if [ -f /etc/pterodactyl/config.yml ] && [ -x /usr/local/bin/wings ]; then
  if ! pgrep -f "/usr/local/bin/wings" >/dev/null 2>&1; then
    echo "[watchdog $(date)] Wings down — restarting" >> "$LOG_FILE"
    docker info >/dev/null 2>&1 || (dockerd >>"$LOG_FILE" 2>&1 &)
    sleep 2
    nohup /usr/local/bin/wings >>"$LOG_FILE" 2>&1 &
  fi
fi

# Panel queue worker
STATE_FILE="/etc/pterodactyl-easy-installer/state.conf"
if [ -f "$STATE_FILE" ]; then
  PANEL_DIR=$(grep "^PANEL_DIR=" "$STATE_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2-)
  if [ -n "$PANEL_DIR" ] && [ -f "$PANEL_DIR/artisan" ]; then
    if ! pgrep -f "artisan queue:work" >/dev/null 2>&1; then
      echo "[watchdog $(date)] Queue worker down — restarting" >> "$LOG_FILE"
      PHP_BIN="/usr/bin/php8.3"
      [ -x "$PHP_BIN" ] || PHP_BIN="php"
      nohup "$PHP_BIN" "$PANEL_DIR/artisan" queue:work --queue=high,standard,low --sleep=3 --tries=3 >>"$LOG_FILE" 2>&1 &
    fi
  fi
fi
WDEOF
  chmod +x "$WATCHDOG"
  # Idempotent cron install — remove any previous entry first
  (crontab -l 2>/dev/null | grep -vF "$WATCHDOG"; echo "* * * * * $WATCHDOG >/dev/null 2>&1") | crontab -
  ok "Watchdog cron installed — Wings/queue worker auto-restart every minute if they crash"
}

# ================================================================== #
#  VPS SPEC DETECTION — used by the auto Node/Location creation flow #
# ================================================================== #
detect_ram_mb() {
  free -m 2>/dev/null | awk '/^Mem:/{print $2}'
}

detect_disk_mb() {
  df -m / 2>/dev/null | awk 'NR==2{print $2}'
}

# ================================================================== #
#  BUILT-IN PRE-CHECK HELPERS                                         #
#  Called at the start of every action — check deps, install if      #
#  missing, skip if already there.                                   #
# ================================================================== #

panel_exists_or_die() {
  local PD; PD="$(get_panel_dir)"
  if [ -z "$PD" ] || [ ! -d "$PD" ] || [ ! -f "$PD/artisan" ]; then
    err "Pterodactyl panel is not installed."
    msg "Run [1] Install Panel first."
    pause; return 1
  fi
  return 0
}

ensure_installed() {
  local cmd="$1" pkg="$2" name="${3:-$1}"
  if command -v "$cmd" >/dev/null 2>&1 || [ -x "$cmd" ]; then
    ok "$name already installed"
    return 0
  fi
  msg "$name not found — installing..."
  apt-get update -y >>"$LOG_FILE" 2>&1
  apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1
  if command -v "$cmd" >/dev/null 2>&1 || [ -x "$cmd" ]; then
    ok "$name installed"
    return 0
  fi
  err "Failed to install $name (package: $pkg)"
  return 1
}

# Pre-check for Panel install: base tools, PHP 8.3 + extensions,
# MariaDB, Redis, Nginx, Composer, Certbot, UFW, cron.
pre_check_panel() {
  line; msg "Pre-install dependency check..."; line

  local ALL_OK=1
  check_os_supported

  echo -e "${C_BOLD}  Base Tools${C_NC}"
  for entry in "curl:curl" "wget:wget" "unzip:unzip" "zip:zip" "git:git" "tar:tar" "gpg:gnupg" "lsb_release:lsb-release" "tar:tar"; do
    cmd="${entry%%:*}"; pkg="${entry##*:}"
    ensure_installed "$cmd" "$pkg" "$cmd" || ALL_OK=0
  done

  echo ""; echo -e "${C_BOLD}  PHP 8.3${C_NC}"
  if command -v php >/dev/null 2>&1 && php -v 2>/dev/null | head -1 | grep -q "PHP 8.3"; then
    ok "PHP 8.3 already installed ($(php -v 2>/dev/null | head -1))"
  else
    msg "PHP 8.3 not found — installing..."
    ensure_php
  fi
  for ext in pdo_mysql zip bcmath sodium gd mbstring xml curl; do
    ensure_php_ext "$ext" || ALL_OK=0
  done

  echo ""; echo -e "${C_BOLD}  MariaDB${C_NC}"
  ensure_installed mariadb mariadb-server "MariaDB" || ALL_OK=0

  echo ""; echo -e "${C_BOLD}  Redis${C_NC}"
  ensure_installed redis-server redis-server "Redis" || ALL_OK=0

  echo ""; echo -e "${C_BOLD}  Nginx${C_NC}"
  ensure_installed nginx nginx "Nginx" || ALL_OK=0

  echo ""; echo -e "${C_BOLD}  Composer${C_NC}"
  if command -v composer >/dev/null 2>&1; then
    ok "Composer already installed"
  else
    msg "Composer not found — installing..."
    ensure_composer
    command -v composer >/dev/null 2>&1 && ok "Composer installed" || { err "Composer failed"; ALL_OK=0; }
  fi

  echo ""; echo -e "${C_BOLD}  Certbot${C_NC}"
  ensure_installed certbot certbot "Certbot" || ALL_OK=0

  echo ""; echo -e "${C_BOLD}  Firewall (UFW)${C_NC}"
  ensure_installed ufw ufw "UFW" || ALL_OK=0

  echo ""; echo -e "${C_BOLD}  Cron${C_NC}"
  ensure_installed cron cron "Cron" || ALL_OK=0

  line
  if [ "$ALL_OK" -eq 1 ]; then
    ok "All dependencies ready."
  else
    warn "Some dependencies failed — installation may have issues. Check $LOG_FILE"
  fi
  echo ""
  return 0
}

pre_check_wings() {
  line; msg "Pre-install dependency check..."; line
  check_os_supported

  echo -e "${C_BOLD}  Base Tools${C_NC}"
  for entry in "curl:curl" "wget:wget" "tar:tar"; do
    cmd="${entry%%:*}"; pkg="${entry##*:}"
    ensure_installed "$cmd" "$pkg" "$cmd" || true
  done

  echo ""; echo -e "${C_BOLD}  Docker${C_NC}"
  ensure_docker
  command -v docker >/dev/null 2>&1 && ok "Docker ready" || err "Docker failed to install"

  line
  ok "Dependencies checked."
  echo ""
  return 0
}

pre_check_blueprint() {
  line; msg "Pre-install dependency check..."; line

  echo -e "${C_BOLD}  Panel${C_NC}"
  if ! panel_exists_or_die; then return 1; fi
  ok "Panel found at $(get_panel_dir)"

  echo ""; echo -e "${C_BOLD}  PHP 8.3${C_NC}"
  ensure_php
  for ext in pdo_mysql zip bcmath sodium gd mbstring xml curl; do
    ensure_php_ext "$ext" || true
  done

  echo ""; echo -e "${C_BOLD}  Composer${C_NC}"
  if command -v composer >/dev/null 2>&1; then ok "Composer already installed"; else msg "Installing Composer..."; ensure_composer; fi

  echo ""; echo -e "${C_BOLD}  Node.js${C_NC}"
  ensure_node22

  echo ""; echo -e "${C_BOLD}  Yarn${C_NC}"
  ensure_yarn

  echo ""; echo -e "${C_BOLD}  Base Tools${C_NC}"
  for entry in "wget:wget" "unzip:unzip" "git:git"; do
    cmd="${entry%%:*}"; pkg="${entry##*:}"
    ensure_installed "$cmd" "$pkg" "$cmd" || true
  done

  line
  ok "Dependencies checked."
  echo ""
  return 0
}

ensure_wings_installed() {
  if [ -f /usr/local/bin/wings ] && [ -x /usr/local/bin/wings ]; then
    ok "Wings binary already installed"
    return 0
  fi
  warn "Wings is not installed — auto-installing now..."
  wings_install
  if [ -f /usr/local/bin/wings ] && [ -x /usr/local/bin/wings ]; then
    ok "Wings auto-installed successfully"
    return 0
  fi
  err "Wings auto-install failed."
  return 1
}

ensure_blueprint_or_install() {
  if command -v blueprint >/dev/null 2>&1; then
    ok "Blueprint already installed"
    return 0
  fi
  warn "Blueprint not installed — auto-installing now..."
  install_blueprint
  if command -v blueprint >/dev/null 2>&1; then
    ok "Blueprint auto-installed successfully"
    return 0
  fi
  err "Blueprint auto-install failed."
  return 1
}

ensure_docker_running() {
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon running"
    return 0
  fi
  msg "Starting Docker daemon..."
  service docker start 2>/dev/null || (dockerd >>"$LOG_FILE" 2>&1 &)
  sleep 2
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon started"
    return 0
  fi
  err "Docker daemon could not be started"
  return 1
}
