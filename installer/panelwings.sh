#!/bin/bash
# ================================================================== #
#  panelwings.sh — Auto Panel+Wings: create Location + Node on the    #
#  panel's API, then auto-configure Wings on THIS server.             #
#  Sourced by menu.sh. Provides: panel_wings_auto()                  #
#                                                                    #
#  Flow:                                                              #
#  1. Verify panel is installed and reachable locally                #
#  2. Ask for FQDN only (everything else auto-detected from VPS spec) #
#  3. Create or reuse a Location (code: IN, name: India)            #
#  4. Create a Node (name: NODE-1, auto RAM/disk from VPS specs)      #
#  5. Generate an Application API key (auto-deploy token)           #
#  6. Auto-configure Wings using wings_configure_core()             #
#                                                                    #
#  All API calls use the panel's local HTTP endpoint (no SSL needed  #
#  for localhost). The panel's .env provides the DB + APP_KEY, and   #
#  we generate a fresh Application API key via the artisan CLI.      #
# ================================================================== #

panel_wings_auto() {
  banner; echo "Panel + Wings (Auto Node Setup)"; line

  # 1. Panel must exist
  panel_exists_or_die || return

  # 2. PHP must work
  ensure_php
  local PHP_BIN; PHP_BIN="$(get_php_bin)"
  if [ -z "$PHP_BIN" ] || ! "$PHP_BIN" -v 2>/dev/null | head -1 | grep -q "PHP 8.3"; then
    err "PHP 8.3 not available. Cannot proceed."
    pause; return
  fi

  local PANEL_DIR; PANEL_DIR="$(get_panel_dir)"
  cd "$PANEL_DIR" || { err "Cannot cd to $PANEL_DIR"; pause; return; }

  # 3. Ensure Wings is installed + Docker running
  ensure_wings_installed || { err "Wings installation failed. Try [2] Install Wings first."; pause; return; }
  ensure_docker_running

  # 4. Ask ONLY for the FQDN (everything else auto-detected)
  local FQDN
  ask_nonempty FQDN "Node FQDN (the domain/IP this node will be reached on, e.g. node1.yourdomain.com): "

  # 5. Auto-detect VPS specs
  local RAM_MB DISK_MB RAM_OVERHEAD DISK_OVERHEAD
  RAM_MB=$(detect_ram_mb)
  DISK_MB=$(detect_disk_mb)

  if [ -z "$RAM_MB" ] || [ "$RAM_MB" -lt 512 ]; then
    warn "Could not detect RAM (or very low). Defaulting to 4096 MB."
    RAM_MB=4096
  fi
  if [ -z "$DISK_MB" ] || [ "$DISK_MB" -lt 1024 ]; then
    warn "Could not detect disk (or very low). Defaulting to 51200 MB (50 GB)."
    DISK_MB=51200
  fi

  # Reserve ~20% for OS + panel overhead
  RAM_OVERHEAD=$((RAM_MB / 5))
  local USABLE_RAM=$((RAM_MB - RAM_OVERHEAD))
  DISK_OVERHEAD=$((DISK_MB / 10))
  local USABLE_DISK=$((DISK_MB - DISK_OVERHEAD))

  line
  msg "Detected VPS specs:"
  echo "  Total RAM  : ${RAM_MB} MB"
  echo "  Total Disk : ${DISK_MB} MB"
  echo "  Allocated  : ${USABLE_RAM} MB RAM, ${USABLE_DISK} MB disk (10-20% reserved for OS)"
  echo "  Node FQDN  : $FQDN"
  line

  # 6. Get panel URL from .env or saved state
  local PANEL_URL SAVED_FQDN SAVED_SSL
  SAVED_FQDN="$(load_state FQDN)"
  SAVED_SSL="$(load_state USE_SSL)"
  if [ -n "$SAVED_FQDN" ]; then
    PANEL_URL="$([ "$SAVED_SSL" == "no" ] && echo "http://$SAVED_FQDN" || echo "https://$SAVED_FQDN")"
    msg "Panel URL: $PANEL_URL"
  else
    # Try reading from .env
    local ENV_URL
    ENV_URL=$(grep "^APP_URL=" "$PANEL_DIR/.env" 2>/dev/null | cut -d'=' -f2-)
    if [ -n "$ENV_URL" ]; then
      PANEL_URL="$ENV_URL"
      msg "Panel URL (from .env): $PANEL_URL"
    else
      ask_nonempty PANEL_URL "Panel URL (e.g. https://panel.yourdomain.com): "
    fi
  fi

  # For API calls, we use localhost:80 (bypasses SSL/tunnel issues)
  local API_BASE="http://127.0.0.1:80"

  # 7. Create or reuse Location
  msg "Creating Location 'IN' (India)..."
  local LOC_RESPONSE LOC_ID

  # First check if location already exists
  LOC_RESPONSE=$(curl -sS -o /tmp/loc-response.json -w "%{http_code}" \
    "$API_BASE/api/application/locations" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_TOKEN" 2>>"$LOG_FILE")

  # We need an API token first — generate one via artisan
  msg "Generating Application API key..."
  local API_TOKEN
  API_TOKEN=$("$PHP_BIN" artisan p:apikey:make --description="NextDev-AutoNode-$(date +%s)" --admin 2>>"$LOG_FILE" | grep -oP 'ptla_[A-Za-z0-9]+' | head -1)

  if [ -z "$API_TOKEN" ]; then
    err "Failed to generate API key via artisan. You may need to create one manually in the panel."
    msg "Admin -> API Keys -> Create, then use [3] Setup Wings manually."
    pause; return
  fi
  ok "API key generated: ${API_TOKEN:0:12}..."

  # Now check for existing location
  LOC_RESPONSE=$(curl -sS -o /tmp/loc-response.json -w "%{http_code}" \
    "$API_BASE/api/application/locations" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_TOKEN" 2>>"$LOG_FILE")

  if [ "$LOC_RESPONSE" == "200" ]; then
    # Check if location with code "IN" already exists
    LOC_ID=$(python3 -c "
import json
with open('/tmp/loc-response.json') as f:
    data = json.load(f)
for loc in data.get('data', []):
    if loc.get('attributes', {}).get('code') == 'IN':
        print(loc['attributes']['id'])
        break
" 2>/dev/null)

    if [ -n "$LOC_ID" ]; then
      ok "Location 'IN' already exists (ID: $LOC_ID) — reusing"
    else
      # Create it
      LOC_RESPONSE=$(curl -sS -X POST -o /tmp/loc-create.json -w "%{http_code}" \
        "$API_BASE/api/application/locations" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_TOKEN" \
        -d '{"short":"IN","long":"India"}' 2>>"$LOG_FILE")

      if [ "$LOC_RESPONSE" == "201" ]; then
        LOC_ID=$(python3 -c "
import json
with open('/tmp/loc-create.json') as f:
    data = json.load(f)
print(data.get('attributes', {}).get('id', ''))
" 2>/dev/null)
        ok "Location 'IN' created (ID: $LOC_ID)"
      else
        err "Failed to create Location (HTTP $LOC_RESPONSE)"
        msg "Response: $(cat /tmp/loc-create.json 2>/dev/null | head -c 500)"
        rm -f /tmp/loc-response.json /tmp/loc-create.json
        pause; return
      fi
    fi
  else
    err "Failed to query locations (HTTP $LOC_RESPONSE)"
    rm -f /tmp/loc-response.json
    pause; return
  fi
  rm -f /tmp/loc-response.json /tmp/loc-create.json

  # 8. Create Node
  msg "Creating Node 'NODE-1'..."
  local NODE_RESPONSE NODE_ID

  # Check if NODE-1 already exists
  NODE_RESPONSE=$(curl -sS -o /tmp/node-check.json -w "%{http_code}" \
    "$API_BASE/api/application/nodes" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_TOKEN" 2>>"$LOG_FILE")

  local EXISTING_NODE_ID=""
  if [ "$NODE_RESPONSE" == "200" ]; then
    EXISTING_NODE_ID=$(python3 -c "
import json
with open('/tmp/node-check.json') as f:
    data = json.load(f)
for node in data.get('data', []):
    if node.get('attributes', {}).get('name') == 'NODE-1':
        print(node['attributes']['id'])
        break
" 2>/dev/null)
  fi

  if [ -n "$EXISTING_NODE_ID" ]; then
    NODE_ID="$EXISTING_NODE_ID"
    ok "Node 'NODE-1' already exists (ID: $NODE_ID) — reusing"
  else
    # Determine scheme: http (behind tunnel/no SSL) or https
    local USE_SSL="false"
    [ "$SAVED_SSL" == "yes" ] && USE_SSL="true"

    NODE_RESPONSE=$(curl -sS -X POST -o /tmp/node-create.json -w "%{http_code}" \
      "$API_BASE/api/application/nodes" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $API_TOKEN" \
      -d "{
        \"name\": \"NODE-1\",
        \"location_id\": $LOC_ID,
        \"fqdn\": \"$FQDN\",
        \"scheme\": \"http\",
        \"memory\": $USABLE_RAM,
        \"memory_overallocate\": 0,
        \"disk\": $USABLE_DISK,
        \"disk_overallocate\": 0,
        \"upload_size\": 100,
        \"daemon_sftp\": 2022,
        \"daemon_listen\": 8080,
        \"behind_proxy\": true
      }" 2>>"$LOG_FILE")

    if [ "$NODE_RESPONSE" == "201" ] || [ "$NODE_RESPONSE" == "200" ]; then
      NODE_ID=$(python3 -c "
import json
with open('/tmp/node-create.json') as f:
    data = json.load(f)
print(data.get('attributes', {}).get('id', ''))
" 2>/dev/null)
      ok "Node 'NODE-1' created (ID: $NODE_ID)"
      msg "  RAM: ${USABLE_RAM} MB | Disk: ${USABLE_DISK} MB | FQDN: $FQDN"
      msg "  Scheme: http | behind_proxy: true (Cloudflare/tunnel friendly)"
    else
      err "Failed to create Node (HTTP $NODE_RESPONSE)"
      msg "Response: $(cat /tmp/node-create.json 2>/dev/null | head -c 500)"
      rm -f /tmp/node-check.json /tmp/node-create.json
      pause; return
    fi
  fi
  rm -f /tmp/node-check.json /tmp/node-create.json

  if [ -z "$NODE_ID" ]; then
    err "Could not determine Node ID. Aborting."
    pause; return
  fi

  # 9. Get the auto-deploy token for this node
  msg "Fetching auto-deploy token for Node $NODE_ID..."
  local CONFIG_RESPONSE
  CONFIG_RESPONSE=$(curl -sS -o /tmp/node-config.json -w "%{http_code}" \
    "$API_BASE/api/application/nodes/$NODE_ID/configuration" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_TOKEN" 2>>"$LOG_FILE")

  if [ "$CONFIG_RESPONSE" != "200" ] || [ ! -s /tmp/node-config.json ]; then
    err "Failed to fetch node configuration (HTTP $CONFIG_RESPONSE)"
    rm -f /tmp/node-config.json
    pause; return
  fi

  # The config response IS the token — extract it
  # The API returns the full config which includes the token
  # But for wings configure, we need the auto-deploy token
  # The node's daemon_token is what we need — let's get it from the node object
  local NODE_TOKEN
  NODE_TOKEN=$(curl -sS \
    "$API_BASE/api/application/nodes/$NODE_ID" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer $API_TOKEN" 2>>"$LOG_FILE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
attrs = data.get('attributes', {})
print(attrs.get('daemon_token', ''))
" 2>/dev/null)

  rm -f /tmp/node-config.json

  if [ -z "$NODE_TOKEN" ]; then
    err "Could not extract daemon token for Node $NODE_ID."
    msg "You can set up Wings manually via [3] Setup Wings."
    pause; return
  fi
  ok "Daemon token obtained: ${NODE_TOKEN:0:12}..."

  # 10. Auto-configure Wings using the core engine
  # Use the PANEL_URL (not localhost) so Wings talks to the panel through
  # the proper URL (Cloudflare tunnel, etc.)
  msg "Auto-configuring Wings..."
  wings_configure_core "$PANEL_URL" "$NODE_TOKEN" "$NODE_ID"

  local WINGS_RESULT=$?

  line
  if [ "$WINGS_RESULT" -eq 0 ]; then
    ok "Panel + Wings auto-setup complete!"
    msg "Location: IN (India) | Node: NODE-1 (ID: $NODE_ID)"
    msg "Check Panel -> Nodes — NODE-1 should turn green within 30 seconds."
  else
    err "Wings configuration had issues. Node was created on the panel (ID: $NODE_ID)."
    msg "Try [3] Setup Wings manually with the token: $NODE_TOKEN"
  fi

  # Clean up the API key (optional — user can revoke it in panel later)
  msg "Note: API key ${API_TOKEN:0:12}... was created for this operation."
  msg "You can revoke it in Panel -> API Keys if you don't need it."

  pause
}
