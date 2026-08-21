#!/bin/bash
# ================================================================== #
#  wings.sh — Pterodactyl Wings (node daemon) installation            #
#  Sourced by menu.sh. Provides: wings_install()                     #
#                                                                    #
#  Pre-check: base tools + Docker. Installs if missing, skips if     #
#  already present. Verifies download size AND checksum.             #
# ================================================================== #

wings_install() {
  banner; echo "Node Install (Wings)"; line
  msg "Installing Docker + Wings automatically."; echo ""

  local ARCH
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
      # FIX (audit #13): an unrecognized architecture must NOT silently
      # fall back to amd64 — an amd64 binary simply cannot execute on,
      # say, riscv64/armv7, and would fail in a confusing way later.
      err "Unsupported/unknown CPU architecture: $(uname -m)"
      err "Wings only ships amd64 and arm64 builds. Aborting — do not proceed on this host."
      pause; return 1
      ;;
  esac

  # 1. Pre-check: verify dependencies, install if missing
  pre_check_wings

  # 2. Start Docker daemon
  ensure_docker_running

  # 3. Download Wings (skip if already installed)
  if [ -f /usr/local/bin/wings ] && [ -x /usr/local/bin/wings ] && [ -s /usr/local/bin/wings ]; then
    ok "Wings binary already installed — skipping download"
  else
    msg "Downloading Wings ($ARCH)..."
    mkdir -p /etc/pterodactyl
    curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH}" 2>>"$LOG_FILE"

    if [ ! -s /usr/local/bin/wings ]; then
      err "Wings download failed — file is empty. Check network connectivity."
      rm -f /usr/local/bin/wings 2>/dev/null
      pause; return 1
    fi

    if head -c 4 /usr/local/bin/wings | grep -q "<"; then
      err "Wings download failed — received HTML instead of binary (URL may be wrong or 404)."
      msg "First 200 bytes: $(head -c 200 /usr/local/bin/wings)"
      rm -f /usr/local/bin/wings 2>/dev/null
      pause; return 1
    fi

    # FIX (audit #10): verify integrity against the release's published
    # checksums.txt before executing it as root. Best-effort — if the
    # checksums file itself can't be fetched (older release format changed,
    # network hiccup), we warn loudly but don't hard-block, since Wings
    # doesn't guarantee this file exists on every release. A HASH MISMATCH,
    # however, is always a hard abort — that indicates tampering/corruption.
    msg "Verifying download integrity..."
    local CHECKSUMS_URL="https://github.com/pterodactyl/wings/releases/latest/download/checksums.txt"
    if curl -fsSL -o /tmp/wings-checksums.txt "$CHECKSUMS_URL" 2>>"$LOG_FILE" && [ -s /tmp/wings-checksums.txt ]; then
      local EXPECTED ACTUAL
      EXPECTED=$(grep "wings_linux_${ARCH}" /tmp/wings-checksums.txt 2>/dev/null | awk '{print $1}' | head -1)
      ACTUAL=$(sha256sum /usr/local/bin/wings 2>/dev/null | awk '{print $1}')
      rm -f /tmp/wings-checksums.txt
      if [ -n "$EXPECTED" ]; then
        if [ "$EXPECTED" == "$ACTUAL" ]; then
          ok "Checksum verified (sha256 matches published release)"
        else
          err "CHECKSUM MISMATCH! Expected $EXPECTED, got $ACTUAL"
          err "The downloaded binary does not match the official release. Aborting for safety."
          rm -f /usr/local/bin/wings
          pause; return 1
        fi
      else
        warn "Could not find a checksum entry for wings_linux_${ARCH} in checksums.txt — skipping verification"
      fi
    else
      warn "Could not fetch checksums.txt from the release — skipping integrity verification"
      warn "(This can happen if the release format changed; the binary itself downloaded fine.)"
    fi

    chmod +x /usr/local/bin/wings
    ok "Wings downloaded ($(du -h /usr/local/bin/wings | cut -f1))"
  fi

  # 4. Firewall
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 8080 >>"$LOG_FILE" 2>&1
    ufw allow 2022 >>"$LOG_FILE" 2>&1
    ok "Firewall: opened 8080 (wings) + 2022 (SFTP)"
  fi

  line; ok "Wings installed!"
  msg "Next: use [3] Setup Wings (paste a deploy command) or [4] Auto Node Setup (fully automatic)."
  pause
}
