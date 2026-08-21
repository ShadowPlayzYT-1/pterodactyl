#!/bin/bash
# ================================================================== #
#  deps.sh — Full dependency checker + auto-installer                #
#  Sourced by menu.sh. Provides: check_dependencies()               #
#                                                                    #
#  Checks ALL dependencies the installer needs across every option:  #
#  base tools, PHP 8.3 + extensions, Composer, Node.js 22, Yarn,    #
#  Docker, MariaDB, Redis, Nginx, Certbot.                           #
#  Shows a status table, then installs whatever is missing.         #
# ================================================================== #

check_dependencies() {
  banner; echo "Dependency Check"; line
  msg "Scanning all required dependencies..."
  echo ""

  local MISSING=0
  local INSTALLED=0
  local ALREADY=0

  # Helper: print status line
  dep_ok()    { echo -e "  ${C_GREEN}✔${C_NC} $1 — found ($2)";          ALREADY=$((ALREADY+1)); }
  dep_fixed() { echo -e "  ${C_GREEN}+${C_NC} $1 — installed";           INSTALLED=$((INSTALLED+1)); }
  dep_fail()  { echo -e "  ${C_RED}✘${C_NC} $1 — FAILED to install";     MISSING=$((MISSING+1)); }
  dep_skip()  { echo -e "  ${C_YELLOW}-${C_NC} $1 — skipped ($2)";      ALREADY=$((ALREADY+1)); }

  # ─── Base tools ────────────────────────────────────────────── #
  echo -e "${C_BOLD}  Base Tools${C_NC}"
  for entry in "curl:curl" "wget:wget" "unzip:unzip" "zip:zip" "git:git" "tar:tar" "gpg:gnupg" "lsb_release:lsb-release" "jq:jq" "python3:python3"; do
    cmd="${entry%%:*}"; pkg="${entry##*:}"
    if command -v "$cmd" >/dev/null 2>&1; then
      ver=$("$cmd" --version 2>&1 | head -1 | tr -d '\n' | cut -c1-40)
      dep_ok "$cmd" "$ver"
    else
      msg "Installing $pkg..."
      apt-get update -y >>"$LOG_FILE" 2>&1
      apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1
      command -v "$cmd" >/dev/null 2>&1 && dep_fixed "$cmd" || dep_fail "$cmd"
    fi
  done
  echo ""

  # ─── PHP 8.3 + Extensions ──────────────────────────────────── #
  echo -e "${C_BOLD}  PHP 8.3 + Extensions${C_NC}"
  if command -v php >/dev/null 2>&1; then
    PHPVER=$(php -v 2>/dev/null | head -1)
    if [[ "$PHPVER" == *"PHP 8.3"* ]]; then
      dep_ok "PHP" "$PHPVER"
    elif [[ "$PHPVER" == *"PHP 8.2"* ]]; then
      dep_skip "PHP" "8.2 found, 8.3 preferred — panel should still work"
    else
      echo -e "  ${C_YELLOW}!${C_NC} PHP — wrong version ($PHPVER), installing 8.3..."
      ensure_php
      command -v php8.3 >/dev/null 2>&1 && dep_fixed "PHP 8.3" || dep_fail "PHP 8.3"
    fi
  else
    msg "PHP not found — installing 8.3..."
    ensure_php
    command -v php >/dev/null 2>&1 && dep_fixed "PHP 8.3" || dep_fail "PHP 8.3"
  fi

  # Check each required PHP extension
  if command -v php >/dev/null 2>&1; then
    for ext in pdo_mysql zip bcmath sodium gd mbstring xml curl; do
      if php -m 2>/dev/null | grep -qi "^$ext$"; then
        dep_ok "php-$ext" "loaded"
      else
        msg "Installing php8.3-$ext..."
        apt-get install -y "php8.3-$ext" >>"$LOG_FILE" 2>&1
        php -m 2>/dev/null | grep -qi "^$ext$" && dep_fixed "php-$ext" || dep_fail "php-$ext"
      fi
    done
  else
    err "PHP not available — cannot check extensions"
    MISSING=$((MISSING+1))
  fi
  echo ""

  # ─── Composer ──────────────────────────────────────────────── #
  echo -e "${C_BOLD}  Composer${C_NC}"
  if command -v composer >/dev/null 2>&1; then
    dep_ok "Composer" "$(composer --version 2>/dev/null | head -1 | tr -d '\n' | cut -c1-40)"
  else
    msg "Installing Composer..."
    ensure_composer
    command -v composer >/dev/null 2>&1 && dep_fixed "Composer" || dep_fail "Composer"
  fi
  echo ""

  # ─── Node.js 22 + Yarn ──────────────────────────────────────── #
  echo -e "${C_BOLD}  Node.js & Yarn${C_NC}"
  if command -v node >/dev/null 2>&1; then
    NODEVER=$(node -v 2>/dev/null)
    if [[ "$NODEVER" == v22* ]]; then
      dep_ok "Node.js" "$NODEVER"
    else
      echo -e "  ${C_YELLOW}!${C_NC} Node.js — wrong version ($NODEVER), installing 22..."
      ensure_node22
      [[ "$(node -v 2>/dev/null)" == v22* ]] && dep_fixed "Node.js 22" || dep_fail "Node.js 22"
    fi
  else
    msg "Installing Node.js 22..."
    ensure_node22
    command -v node >/dev/null 2>&1 && dep_fixed "Node.js 22" || dep_fail "Node.js 22"
  fi

  if command -v yarn >/dev/null 2>&1; then
    dep_ok "Yarn" "$(yarn --version 2>/dev/null)"
  else
    msg "Installing Yarn..."
    ensure_yarn
    command -v yarn >/dev/null 2>&1 && dep_fixed "Yarn" || dep_fail "Yarn"
  fi
  echo ""

  # ─── Docker ────────────────────────────────────────────────── #
  echo -e "${C_BOLD}  Docker${C_NC}"
  if command -v docker >/dev/null 2>&1; then
    dep_ok "Docker" "$(docker --version 2>/dev/null | tr -d '\n' | cut -c1-40)"
    if docker info >/dev/null 2>&1; then
      dep_ok "Docker daemon" "running"
    else
      warn "Docker installed but daemon not running — starting..."
      service docker start 2>/dev/null || (dockerd >>"$LOG_FILE" 2>&1 &)
      sleep 2
      docker info >/dev/null 2>&1 && dep_fixed "Docker daemon" || dep_fail "Docker daemon"
    fi
  else
    msg "Installing Docker..."
    ensure_docker
    command -v docker >/dev/null 2>&1 && dep_fixed "Docker" || dep_fail "Docker"
    # Try starting the daemon
    service docker start 2>/dev/null || (dockerd >>"$LOG_FILE" 2>&1 &)
    sleep 2
    docker info >/dev/null 2>&1 && dep_fixed "Docker daemon" || dep_fail "Docker daemon"
  fi
  echo ""

  # ─── MariaDB ───────────────────────────────────────────────── #
  echo -e "${C_BOLD}  MariaDB${C_NC}"
  if command -v mariadb >/dev/null 2>&1; then
    dep_ok "MariaDB client" "$(mariadb --version 2>/dev/null | tr -d '\n' | cut -c1-40)"
    if mariadb -u root -e "SELECT 1" >/dev/null 2>&1; then
      dep_ok "MariaDB server" "running"
    else
      warn "MariaDB installed but not running — starting..."
      ensure_mariadb_running
      mariadb -u root -e "SELECT 1" >/dev/null 2>&1 && dep_fixed "MariaDB server" || dep_fail "MariaDB server"
    fi
  else
    msg "Installing MariaDB..."
    apt-get update -y >>"$LOG_FILE" 2>&1
    apt-get install -y mariadb-common mariadb-server mariadb-client >>"$LOG_FILE" 2>&1
    ensure_mariadb_running
    command -v mariadb >/dev/null 2>&1 && dep_fixed "MariaDB" || dep_fail "MariaDB"
  fi
  echo ""

  # ─── Redis ─────────────────────────────────────────────────── #
  echo -e "${C_BOLD}  Redis${C_NC}"
  if command -v redis-server >/dev/null 2>&1 || command -v redis-cli >/dev/null 2>&1; then
    dep_ok "Redis" "$(redis-server --version 2>/dev/null | tr -d '\n' | cut -c1-40)"
    if redis-cli ping >/dev/null 2>&1 || pgrep -f redis-server >/dev/null 2>&1; then
      dep_ok "Redis server" "running"
    else
      warn "Redis installed but not running — starting..."
      ensure_redis_running
      is_running redis && dep_fixed "Redis server" || dep_fail "Redis server"
    fi
  else
    msg "Installing Redis..."
    apt-get update -y >>"$LOG_FILE" 2>&1
    apt-get install -y redis-server >>"$LOG_FILE" 2>&1
    ensure_redis_running
    command -v redis-server >/dev/null 2>&1 && dep_fixed "Redis" || dep_fail "Redis"
  fi
  echo ""

  # ─── Nginx ─────────────────────────────────────────────────── #
  echo -e "${C_BOLD}  Nginx${C_NC}"
  if command -v nginx >/dev/null 2>&1; then
    dep_ok "Nginx" "$(nginx -v 2>&1 | tr -d '\n' | cut -c1-40)"
    if pgrep -x nginx >/dev/null 2>&1; then
      dep_ok "Nginx server" "running"
    else
      warn "Nginx installed but not running — starting..."
      start_service nginx
      pgrep -x nginx >/dev/null 2>&1 && dep_fixed "Nginx server" || dep_fail "Nginx server"
    fi
  else
    msg "Installing Nginx..."
    apt-get update -y >>"$LOG_FILE" 2>&1
    apt-get install -y nginx >>"$LOG_FILE" 2>&1
    start_service nginx
    command -v nginx >/dev/null 2>&1 && dep_fixed "Nginx" || dep_fail "Nginx"
  fi
  echo ""

  # ─── Certbot (Let's Encrypt) ────────────────────────────────── #
  echo -e "${C_BOLD}  Certbot (Let's Encrypt)${C_NC}"
  if command -v certbot >/dev/null 2>&1; then
    dep_ok "Certbot" "$(certbot --version 2>&1 | tr -d '\n')"
  else
    msg "Installing Certbot..."
    apt-get update -y >>"$LOG_FILE" 2>&1
    apt-get install -y certbot python3-certbot-nginx >>"$LOG_FILE" 2>&1
    command -v certbot >/dev/null 2>&1 && dep_fixed "Certbot" || dep_fail "Certbot"
  fi
  echo ""

  # ─── PHP-FPM 8.3 ───────────────────────────────────────────── #
  echo -e "${C_BOLD}  PHP-FPM${C_NC}"
  if pgrep -f php-fpm >/dev/null 2>&1; then
    dep_ok "PHP-FPM" "running"
  elif command -v php-fpm8.3 >/dev/null 2>&1 || [ -f /usr/sbin/php-fpm8.3 ]; then
    warn "PHP-FPM installed but not running — starting..."
    start_service php8.3-fpm
    pgrep -f php-fpm >/dev/null 2>&1 && dep_fixed "PHP-FPM" || dep_fail "PHP-FPM"
  else
    msg "Installing PHP-FPM 8.3..."
    apt-get update -y >>"$LOG_FILE" 2>&1
    apt-get install -y php8.3-fpm >>"$LOG_FILE" 2>&1
    start_service php8.3-fpm
    pgrep -f php-fpm >/dev/null 2>&1 && dep_fixed "PHP-FPM" || dep_fail "PHP-FPM"
  fi
  echo ""

  # ─── Wings binary ───────────────────────────────────────────── #
  echo -e "${C_BOLD}  Wings${C_NC}"
  if [ -f /usr/local/bin/wings ] && [ -x /usr/local/bin/wings ]; then
    dep_ok "Wings" "binary present"
  else
    dep_skip "Wings" "not installed — use [2] Install Wings"
  fi
  echo ""

  # ─── Summary ───────────────────────────────────────────────── #
  line
  echo -e "  ${C_BOLD}Summary${C_NC}"
  echo -e "  ${C_GREEN}Already installed${C_NC} : $ALREADY"
  echo -e "  ${C_GREEN}Newly installed${C_NC}   : $INSTALLED"
  echo -e "  ${C_RED}Failed${C_NC}               : $MISSING"
  echo ""

  if [ "$MISSING" -eq 0 ] && [ "$INSTALLED" -eq 0 ]; then
    ok "All dependencies are already installed. Nothing to do."
  elif [ "$MISSING" -eq 0 ]; then
    ok "All dependencies installed successfully ($INSTALLED newly installed)."
  else
    err "$MISSING dependency(ies) failed to install."
    msg "Check $LOG_FILE for details."
    msg "You can also try installing them manually and re-running this check."
  fi
  pause
}
