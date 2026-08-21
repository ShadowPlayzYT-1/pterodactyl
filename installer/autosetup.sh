#!/bin/bash
# ================================================================== #
#  autosetup.sh — Wings configuration engine + interactive wrapper    #
#  Sourced by menu.sh. Provides: wings_configure_core(),              #
#  wings_setup_token()                                               #
#                                                                    #
#  wings_configure_core() is the reusable engine — it takes explicit  #
#  panel_url/token/node_id args and does the actual configure+start.  #
#  Both the manual paste-a-command flow (wings_setup_token) and the   #
#  fully-automatic flow (panelwings.sh) call into this same function, #
#  so fixes/hardening here apply to both paths.                      #
#                                                                    #
#  KEY FINDINGS from wings source code (cmd/configure.go):           #
#  1. The "Override existing configuration file?" prompt uses the    #
#     `survey` library which reads from the TTY directly, NOT       #
#     stdin. Piping "yes" does NOT work. --override skips it.       #
#  2. --allow-insecure disables TLS verification — this must ONLY be #
#     used when the panel URL is genuinely http:// or self-signed,   #
#     never just because "we're in Docker" (audit #14/#15 — being in #
#     a container says nothing about whether the panel needs it).    #
#  3. Token format is ptla_ (Application API key format).            #
# ================================================================== #

# wings_configure_core <panel_url> <token> <node_id>
# Does NOT prompt for anything. Returns 0 on success, 1 on failure.
wings_configure_core() {
  local PANEL_URL="$1" TOKEN="$2" NODE_ID="$3"

  if [ -z "$PANEL_URL" ] || [ -z "$TOKEN" ] || [ -z "$NODE_ID" ]; then
    err "wings_configure_core: missing panel_url/token/node_id"
    return 1
  fi

  line
  msg "Configuring Wings..."
  msg "  Panel URL : $PANEL_URL"
  msg "  Node ID   : $NODE_ID"
  msg "  Token     : ${TOKEN:0:12}..."
  line

  ensure_wings_installed || { err "Wings is not available. Aborting."; return 1; }
  ensure_docker_running

  mkdir -p /etc/pterodactyl
  if [ -f /etc/pterodactyl/config.yml ]; then
    cp /etc/pterodactyl/config.yml "/etc/pterodactyl/config.yml.bak-$(date +%s)" 2>/dev/null
    chmod 600 "/etc/pterodactyl/config.yml.bak-$(date +%s)" 2>/dev/null || true
    warn "Existing config.yml backed up."
  fi

  # FIX (audit #14): --allow-insecure is ONLY added when the panel URL is
  # explicitly http:// (i.e. actually unencrypted / self-signed). Being
  # inside a Docker container says nothing about the panel's own TLS setup
  # — the old blanket "if docker, disable cert verification" rule was wrong
  # and dangerous by default.
  local INSECURE_FLAG="" CURL_INSECURE=""
  if [[ "$PANEL_URL" == http://* ]]; then
    INSECURE_FLAG="--allow-insecure"
    CURL_INSECURE="-k"
    msg "Panel URL is http:// — adding --allow-insecure (expected behind a tunnel/proxy that terminates TLS)"
  fi

  msg "Running: wings configure --panel-url ... --token ... --node ... --override $INSECURE_FLAG"
  wings configure \
    --panel-url "$PANEL_URL" \
    --token "$TOKEN" \
    --node "$NODE_ID" \
    --override \
    $INSECURE_FLAG 2>&1 | tee -a "$LOG_FILE"

  local WINGS_EXIT=${PIPESTATUS[0]}

  # --- FALLBACK: manual config fetch if wings configure failed --- #
  if [ "$WINGS_EXIT" -ne 0 ] || [ ! -f /etc/pterodactyl/config.yml ]; then
    warn "wings configure failed (exit $WINGS_EXIT). Trying manual config fetch..."
    local API_URL="${PANEL_URL%/}/api/application/nodes/${NODE_ID}/configuration"
    msg "Fetching: $API_URL"

    local HTTP_CODE
    HTTP_CODE=$(curl -sS $CURL_INSECURE -o /tmp/wings-config-response.json -w "%{http_code}" \
      -H "Accept: application/vnd.pterodactyl.v1+json" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      "$API_URL" 2>>"$LOG_FILE")

    if [ "$HTTP_CODE" == "200" ] && [ -s /tmp/wings-config-response.json ]; then
      # FIX (audit #16): prefer PyYAML for a correct, spec-compliant YAML
      # dump. If it's missing, try to install it before falling back to
      # the hand-rolled converter (which can mangle special characters).
      command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null || {
        msg "Installing PyYAML for safe config generation..."
        pip3 install --quiet pyyaml 2>>"$LOG_FILE" || apt-get install -y python3-yaml >>"$LOG_FILE" 2>&1
      }

      python3 -c "
import json

with open('/tmp/wings-config-response.json') as f:
    cfg = json.load(f)
cfg['panel_location'] = '$PANEL_URL'

try:
    import yaml
    with open('/etc/pterodactyl/config.yml', 'w') as f:
        yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
    print('YAML written via PyYAML (safe)')
except ImportError:
    print('WARNING: PyYAML unavailable, using manual converter — review config.yml for correctness')
    def to_yaml(obj, indent=0):
        lines = []
        sp = '  ' * indent
        if isinstance(obj, dict):
            for k, v in obj.items():
                if isinstance(v, (dict, list)):
                    lines.append(f'{sp}{k}:')
                    lines.extend(to_yaml(v, indent + 1))
                elif v is None:
                    lines.append(f'{sp}{k}: null')
                elif isinstance(v, bool):
                    lines.append(f'{sp}{k}: {str(v).lower()}')
                elif isinstance(v, (int, float)):
                    lines.append(f'{sp}{k}: {v}')
                else:
                    sval = str(v).replace('\\\\', '\\\\\\\\').replace('\"', '\\\\\"')
                    lines.append(f'{sp}{k}: \"{sval}\"')
        elif isinstance(obj, list):
            for item in obj:
                if isinstance(item, (dict, list)):
                    lines.append(f'{sp}-')
                    lines.extend(to_yaml(item, indent + 1))
                else:
                    lines.append(f'{sp}- {item}')
        return lines
    yaml_lines = to_yaml(cfg)
    with open('/etc/pterodactyl/config.yml', 'w') as f:
        f.write('\n'.join(yaml_lines) + '\n')
" 2>>"$LOG_FILE"

      # Always remove the raw API response — it's no longer needed and
      # shouldn't linger in /tmp (audit #3).
      rm -f /tmp/wings-config-response.json

      if [ ! -f /etc/pterodactyl/config.yml ] || [ ! -s /etc/pterodactyl/config.yml ]; then
        err "Failed to write config.yml. Check $LOG_FILE"
        return 1
      fi
      ok "Config manually fetched and written to /etc/pterodactyl/config.yml"
    else
      rm -f /tmp/wings-config-response.json
      err "Manual fetch also failed (HTTP $HTTP_CODE)."
      msg "Common causes: panel unreachable from this node, expired/invalid token, wrong Node ID."
      return 1
    fi
  fi

  # FIX (audit #3): config.yml holds the node's daemon secret — a
  # credential. Lock it down to root-only, regardless of which path wrote it.
  chown root:root /etc/pterodactyl/config.yml 2>/dev/null || true
  chmod 600 /etc/pterodactyl/config.yml 2>/dev/null || true
  ok "Wings configured (config.yml secured — 600, root:root)."

  # --- Start Wings --- #
  pkill -f "/usr/local/bin/wings" 2>/dev/null || true
  sleep 1

  msg "Ensuring Docker is running..."
  ensure_docker
  docker info >/dev/null 2>&1 || (dockerd >>"$LOG_FILE" 2>&1 &)
  sleep 2

  if docker info >/dev/null 2>&1; then
    ok "Docker is running"
  else
    err "Docker is not running — Wings needs Docker."
    msg "Try: service docker start  or  dockerd &"
    return 1
  fi

  msg "Starting Wings..."
  : > "$LOG_FILE.wings-start-marker" 2>/dev/null || true
  nohup /usr/local/bin/wings >>"$LOG_FILE" 2>&1 &

  # FIX (audit #17): "config.yml exists" isn't proof Wings is healthy.
  # Poll for up to 8s and specifically look for a fatal error in the log
  # tail, not just whether the process is technically still alive.
  local ALIVE=0
  for i in $(seq 1 8); do
    sleep 1
    if pgrep -f "/usr/local/bin/wings" >/dev/null 2>&1; then
      ALIVE=1
    else
      ALIVE=0
      break
    fi
  done

  line
  if [ "$ALIVE" -eq 1 ] && ! tail -30 "$LOG_FILE" 2>/dev/null | grep -qi "level=fatal\|panic:"; then
    ok "Wings is configured and running!"
    msg "Check the Panel -> Nodes page — the node should turn green within 30 seconds."
    # Reliability fix (audit #18): install the cron watchdog so a future
    # crash/reboot doesn't leave Wings down forever (no systemd here).
    install_watchdog_cron
    return 0
  else
    err "Wings didn't stay running or logged a fatal error. Last 20 log lines:"
    tail -20 "$LOG_FILE" 2>/dev/null
    msg ""
    msg "Run wings without nohup to see the live error:  /usr/local/bin/wings"
    return 1
  fi
}

wings_setup_token() {
  banner; echo "Node Setup"; line
  msg "On your Panel: Admin -> Nodes -> your node -> Configuration tab."
  msg "Copy the auto-deploy command shown there."
  echo ""

  local PASTE=""
  ask_nonempty PASTE "Paste the auto-deploy command (or just the token, starting with ptla_): "
  PASTE="${PASTE#sudo }"

  local PANEL_URL="" TOKEN="" NODE_ID=""

  if [[ "$PASTE" == *"wings configure"* ]]; then
    PANEL_URL=$(echo "$PASTE" | grep -oP '(?<=--panel-url[= ])[^ ]+' | tr -d '"')
    TOKEN=$(echo "$PASTE" | grep -oP '(?<=--token[= ])[^ ]+' | tr -d '"')
    NODE_ID=$(echo "$PASTE" | grep -oP '(?<=--node[= ])[^ ]+' | tr -d '"')
  elif [[ "$PASTE" == ptla_* ]] || [[ "$PASTE" == ptlc_* ]]; then
    TOKEN="$PASTE"
  fi

  if [ -z "$TOKEN" ]; then
    err "Could not find a token in what you pasted."
    msg "Expected: a 'wings configure' command or a token starting with ptla_"
    pause; return
  fi

  if [ -z "$PANEL_URL" ]; then
    local saved_fqdn saved_ssl
    saved_fqdn="$(load_state FQDN)"
    saved_ssl="$(load_state USE_SSL)"
    if [ -n "$saved_fqdn" ]; then
      PANEL_URL="$([ "$saved_ssl" == "no" ] && echo "http://$saved_fqdn" || echo "https://$saved_fqdn")"
      msg "Auto-detected panel URL: $PANEL_URL"
    else
      ask_nonempty PANEL_URL "Panel URL (e.g. https://panel.yourdomain.com): "
    fi
  fi

  # FIX (audit #15): removed the old "if docker env, force https" rewrite.
  # That assumption ("Docker => must be https") is not generally true and
  # could silently turn a working http:// URL into a broken https:// one.
  # If the scheme looks wrong, just warn — don't guess and rewrite it.
  if [[ "$PANEL_URL" == http://* ]]; then
    warn "Panel URL is http:// — make sure that's actually correct for your setup"
    warn "(expected if you're behind a tunnel/proxy that terminates TLS for you)."
  fi

  if [ -z "$NODE_ID" ]; then
    ask_nonempty NODE_ID "Node ID (the number shown on the panel for this node): "
  fi

  wings_configure_core "$PANEL_URL" "$TOKEN" "$NODE_ID"
  pause
}
