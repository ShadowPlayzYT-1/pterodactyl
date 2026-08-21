# ShadowPlayzYT-1 Pterodactyl Easy Installer

A custom, simplified Pterodactyl panel + Wings installer with Blueprint, Nebula theme, and 66 extensions built in. No dependency on the official pterodactyl-installer or systemd — works in Codespaces, Docker, WSL, chroot, and normal VPS.

**Every action auto-checks its own dependencies and installs anything missing before running.** You don't need to pre-install PHP, Node, Docker, Composer, etc. yourself. If something is missing, the installer installs it. If it's already there, it skips it and moves on.

## Quick Start

```bash
bash <(curl -s https://raw.githubusercontent.com/ShadowPlayzYT-1/pterodactyl/main/menu.sh)
```

## Menu Options

```
  [1]   Install Panel
  [2]   Install Wings
  [3]   Setup Wings
  [4]   Themes & Extensions
  [5]   Uninstall Panel
  [6]   Uninstall Wings
  [7]   Check Dependencies
  [8]   Add Admin User
  [9]   Manage Services
  [10]  Health Check
  [0]   Exit
```

### Themes & Extensions submenu (option [4])

```
  [1]  Install Blueprint
  [2]  Install Nebula Theme
  [3]  Install Extensions
  [4]  Uninstall Extension
  [5]  Uninstall Nebula
  [6]  Uninstall Blueprint
  [7]  Update Blueprint
  [0]  Back
```

| Option | What it does |
|--------|-------------|
| **[1] Install Panel** | Installs Pterodactyl panel — asks for domain + admin login, auto-configures timezone, MariaDB, Redis, Nginx, HTTPS, firewall |
| **[2] Install Wings** | Installs Docker + Wings binary on a node server, opens firewall ports 8080/2022 |
| **[3] Setup Wings** | Configures Wings using the auto-deploy token from your panel. If Wings isn't installed yet, auto-installs it first. Ensures Docker is running. Falls back to manual API config fetch + YAML conversion if `wings configure` fails |
| **[4] Themes & Extensions** | Submenu for Blueprint, Nebula, and 66 extensions |
| **[5] Uninstall Panel** | Removes panel files, database, nginx config, cron jobs, queue worker |
| **[6] Uninstall Wings** | Removes Wings binary, config, Docker containers |
| **[7] Check Dependencies** | Full scan of ALL dependencies — shows status table, installs anything missing |
| **[8] Add Admin User** | Creates a new admin user on an existing panel. Checks panel exists + PHP first |
| **[9] Manage Services** | Submenu to start/stop/restart Panel services (MariaDB, Redis, PHP-FPM, Nginx, Queue) and Wings (Wings + Docker) with live status |
| **[10] Health Check** | Full diagnostic: checks every service, permissions, .env, PHP version, does a live HTTP self-test, and auto-fixes what it can |
| **[0] Exit** | Quit |

### Themes & Extensions detail

| Option | What it does |
|--------|-------------|
| **[1] Install Blueprint** | Checks panel exists (tells you to install panel first if not), checks PHP/Node/Yarn/Composer, installs if missing. Auto-patches Blueprint's Docker-path bug |
| **[2] Install Nebula** | Checks panel exists. If Blueprint not installed, auto-installs Blueprint first, then installs Nebula theme |
| **[3] Install Extensions** | Browse 66 extensions by number or install all. Checks panel + auto-installs Blueprint if missing |
| **[4] Uninstall Extension** | Remove a tracked extension via Blueprint CLI |
| **[5] Uninstall Nebula** | Removes Nebula theme via Blueprint CLI |
| **[6] Uninstall Blueprint** | Backs up `.env`, wipes and re-downloads clean panel files, restores `.env`, runs migrations |
| **[7] Update Blueprint** | Runs `blueprint -upgrade` |

## Built-in Dependency Checking

Every operation runs a pre-check before doing any real work:

| Operation | What it checks (and installs if missing) |
|-----------|------------------------------------------|
| **Panel Install** | curl, wget, unzip, zip, git, tar, gpg, lsb_release, jq, python3, PHP 8.3 + 8 extensions (pdo_mysql, zip, bcmath, sodium, gd, mbstring, xml, curl), MariaDB, Redis, Nginx, Composer, Certbot, UFW, cron |
| **Wings Install** | curl, wget, tar, Docker (starts daemon if not running) |
| **Wings Setup** | Wings binary (auto-installs if missing), Docker daemon (starts if not running) |
| **Blueprint Install** | Panel exists (tells you to install first if not), PHP 8.3 + extensions, Composer, Node.js 22, Yarn, wget, unzip, git |
| **Nebula Install** | Panel exists, Blueprint (auto-installs if missing) |
| **Extensions Install** | Panel exists, Blueprint (auto-installs if missing) |
| **[8] Add Admin User** | Panel exists, PHP 8.3 + extensions |
| **Check Dependencies [7]** | Everything above in one scan — shows green ✔ for already installed, green + for newly installed, red ✘ for failures |

## Repo Structure

```
pterodactyl/
├── menu.sh                   # Entry point - run this
├── README.md                 # This file
├── installer/                # All installation logic
│   ├── common.sh              # Shared: UI, state, service mgmt, dependency helpers,
│   │                          #   pre-check functions (pre_check_panel, pre_check_wings,
│   │                          #   pre_check_blueprint, panel_exists_or_die,
│   │                          #   ensure_wings_installed, ensure_blueprint_or_install, etc.)
│   ├── deps.sh                 # Full dependency checker (option [7])
│   ├── panel.sh                # Panel install (custom, no official installer)
│   ├── wings.sh                # Wings/node install (Docker + binary)
│   ├── autosetup.sh            # Wings auto-setup with panel token
│   ├── admin.sh                # Add admin user to existing panel
│   ├── blueprint.sh            # Blueprint install/update/uninstall (Docker-path bug patched)
│   ├── nebula.sh               # Nebula theme install/uninstall
│   ├── extention.sh            # Extensions install/uninstall (66 extensions)
│   ├── service.sh              # Start/stop/restart Panel + Wings (programmatic)
│   ├── healthcheck.sh          # Diagnose + auto-repair common issues
│   └── uninstall.sh            # Panel + Wings uninstall
├── extensions/                # 66 .blueprint extension files
│   ├── activitypurges.blueprint
│   ├── adminauditlogs.blueprint
│   ├── ... (66 total)
└── themes/
    └── nebula.blueprint
```

## Bug Fixes in This Version

**False "success" on blueprint commands.** Without `set -o pipefail`, `blueprint -install | tee` checked tee's exit code (always 0) instead of blueprint's. The installer now uses `set -o pipefail` globally in menu.sh and `${PIPESTATUS[0]}` in every blueprint command invocation, so failed installs/removes/upgrades are reported as failures — not silently marked as success.

**Wings download not verified.** If the download URL 404'd or the network failed, curl could save an empty file or HTML error page as `/usr/local/bin/wings`, `chmod +x` it, and report "Wings downloaded" — leading to confusing "Wings didn't stay running" errors later. The installer now verifies the file is non-empty and not an HTML error page before proceeding.

**Database creation not idempotent.** Re-running panel install would silently fail on `CREATE USER` / `CREATE DATABASE` (duplicate name errors swallowed into the log) while printing "Database created". Now uses `IF NOT EXISTS` clauses and checks each command's exit code. Also removed `WITH GRANT OPTION` — the panel user doesn't need to manage other users' grants.

**Duplicate extension labels.** Both `mcp` and `mcplugins` were labeled "MC Plugins" in the extension list, making it impossible to tell them apart. Now `mcp` = "MCP Console" and `mcplugins` = "MC Plugins Manager".

**Dead menu entries.** `add_admin_user`, `manage_panel_services`, `manage_wings_service`, and `health_check` were sourced but never wired into the menu — completely inaccessible. Now available as [8], [9], [10] respectively.

**IP address validation.** `is_ip_address()` accepted malformed IPs like `999.999.999.999`. Now validates each octet is 0-255.

## Known Issues This Installer Fixes

### 1. Blueprint's Docker-path bug
Blueprint's own `blueprint.sh` contains:
```bash
if [[ -f "/.dockerenv" ]]; then
  DOCKER="y"
  FOLDER="/app"
fi
```
Any Docker-based environment (GitHub Codespaces, Docker, devcontainers) has `/.dockerenv` present, so Blueprint force-overrides its working directory to `/app` — even when your panel actually lives at `/var/www/pterodactyl`. This breaks the install mid-way (`cd: /app: No such file or directory`) and can leave the panel half-rebuilt with a 500 error. Our `installer/blueprint.sh` automatically patches this one line right after downloading Blueprint, before running it, so it always points at your real panel directory.

### 2. Custom PHP shadowing apt's PHP
Some environments (Codespaces especially) preinstall a custom PHP build at a path like `/usr/local/php/8.4.x/` that takes priority in `$PATH` over the PHP 8.3 this installer sets up. That custom build is often missing extensions Pterodactyl needs (`pdo_mysql`, `zip`, `sodium`, `bcmath`), which makes `composer install` fail. `common.sh` re-symlinks `/usr/bin/php` to the apt-installed PHP 8.3 at the start of every action and verifies each extension is loaded.

### 3. No systemd in containers
Codespaces/Docker containers can't run `systemctl`. This installer uses `policy-rc.d` to stop apt from trying to auto-start services during install, then starts everything manually with `service` commands or `nohup` background processes instead. No `systemctl` call is ever made to a system that can't handle it.

### 4. Let's Encrypt hanging behind Cloudflare Tunnels / reverse proxies
If your domain routes through Cloudflare Tunnel (or any reverse proxy) before reaching your server, Let's Encrypt's HTTP-01 challenge can never reach your server directly — it just hangs. The installer times out after 30 seconds instead of hanging indefinitely, and explains that your tunnel/proxy already handles HTTPS so you don't need Let's Encrypt at all in that setup.

### 5. Wings token format (ptla_ not ptlc_)
Auto-deploy tokens from the Pterodactyl panel start with `ptla_`, not `ptlc_`. The installer accepts both formats and correctly parses the token from either a full `wings configure` auto-deploy command or a raw token paste.

### 6. Wings configure TTY prompt can't be piped
The `wings configure` command uses the `survey` library which reads from the TTY directly, not stdin. Piping `yes |` doesn't work. The installer uses `--override` to skip the prompt entirely.

### 7. Wings configure fallback — JSON to YAML conversion
If `wings configure` fails entirely, the installer falls back to fetching the node configuration from the panel API. The API returns JSON, but Wings expects YAML in `config.yml`. The installer converts JSON to proper YAML using PyYAML (with a manual YAML converter fallback if PyYAML isn't installed).

### 8. Fallback curl missing -k for insecure
When `--allow-insecure` is needed (Cloudflare/HTTP/tunnel setups), the fallback curl command now also passes `-k` to skip SSL verification, matching the behavior of `wings configure --allow-insecure`.

## How Panel Install Works

The installer does NOT use the official pterodactyl-installer. It runs custom code:

1. **Pre-check** — verifies all dependencies (base tools, PHP 8.3 + 8 extensions, MariaDB, Redis, Nginx, Composer, Certbot, UFW, cron). Installs whatever is missing, skips what's already there
2. **PHP sury repo** — ensures the sury PHP repository is configured
3. **Services started manually** — `service mariadb start`, `service redis-server start`, `service php8.3-fpm start` (no systemd needed)
4. **Composer** — downloaded and panel dependencies installed
5. **Panel files** — downloaded from GitHub releases
6. **Database** — `panel` database + `pterodactyl` user created
7. **Configuration** — `key:generate`, environment setup, migrations, admin user
8. **Nginx** — config generated inline, site enabled, nginx started
9. **Let's Encrypt** — `certbot --nginx` with a 30s timeout (won't hang behind tunnels/proxies)
10. **Queue worker** — started with `nohup` (no systemd needed)

## How Wings Install + Setup Works

### Install (option [2])
1. Pre-check: base tools + Docker (installs if missing)
2. Ensure Docker daemon is running (starts if not)
3. Download Wings binary (skips if already installed)
4. Open firewall ports 8080 (Wings API) + 2022 (SFTP)

### Setup (option [3])
1. **Pre-check: auto-install Wings if not present** — if the Wings binary doesn't exist, runs `wings_install` automatically
2. **Pre-check: ensure Docker is running** — starts daemon if needed
3. Parse the auto-deploy command or raw `ptla_` token
4. Auto-detect panel URL from saved state (asks if not available)
5. Force `https://` if in Docker env and auto-deploy gave `http://` (common Pterodactyl bug)
6. Run `wings configure --override --allow-insecure` (skips TTY prompt, handles Cloudflare)
7. **Fallback**: if `wings configure` fails, fetch config from panel API, convert JSON → YAML, write to `/etc/pterodactyl/config.yml`
8. Start Wings with `nohup`

## How Blueprint Install Works

1. **Pre-check**: verify panel exists — if not, tells you to run [1] Install Panel first
2. **Pre-check**: verify PHP 8.3 + extensions, Composer, Node.js 22, Yarn — install if missing
3. Download Blueprint release
4. **Patch the Docker-path bug** — replace `FOLDER="/app"` with your actual panel directory
5. Install Yarn deps, create `.blueprintrc` config
6. Run `blueprint.sh`
7. Verify installation succeeded

## How Nebula + Extensions Work

### Nebula (option [4] → [2])
1. **Pre-check**: panel must exist
2. **Pre-check**: if Blueprint is not installed, auto-install it first
3. Download `nebula.blueprint`
4. Run `blueprint -install nebula`

### Extensions (option [4] → [3])
1. **Pre-check**: panel must exist
2. **Pre-check**: if Blueprint is not installed, auto-install it first
3. Show all 66 extensions in a numbered list
4. User picks by number (e.g. `3 12 40`), `all`, or `0` to cancel
5. Each selected extension is downloaded and installed via `blueprint -install`

## If Something Breaks

1. Run **[10] Health Check** — checks every service, permissions, does a live HTTP test, auto-fixes what it can
2. Run **[7] Check Dependencies** — scans everything, installs what's missing
2. Check the log: `/var/log/pterodactyl-easy-installer.log`
3. If Blueprint left the panel in a bad state, run **[4] → [6] Uninstall Blueprint** — it backs up `.env`, wipes and re-downloads clean panel files, then restores your `.env`. Then retry **[4] → [1] Install Blueprint**.
4. If Wings won't start, run it without `nohup` to see the live error: `/usr/local/bin/wings`
5. If services are down, use **[9] Manage Services** to restart them, or do it manually:
   ```bash
   service nginx restart && service php8.3-fpm restart
   service mariadb restart && service redis-server restart
   nohup php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 &
   ```

## Requirements

- Root access (`sudo`)
- Ubuntu 20.04/22.04/24.04 or Debian 11/12
- For Let's Encrypt: a domain pointing directly to your server (DNS A record, no tunnel/proxy in front)
- For Wings: Docker must be able to run (some containers need `--privileged`)

## Not Affiliated

This is NOT associated with the official Pterodactyl Project or Blueprint Framework. It's a custom installer that installs the same software through custom code.
