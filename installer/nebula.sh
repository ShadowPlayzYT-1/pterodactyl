#!/bin/bash
# ================================================================== #
#  nebula.sh — DISABLED (security audit, 2026-08-20)                  #
#                                                                    #
#  Nebula's private/install.sh does:                                 #
#    source "{root/public}/editor/assets/tests/prototype"           #
#  which is executed AS SHELL CODE during install. That file         #
#  overrides the `pwd` builtin, extracts your panel's real domain    #
#  via grabAppUrl(), and sends it via plain HTTP to a hostname        #
#  obfuscated via string-splitting (LOCAL_PROTOTYPE="post" +         #
#  LOCAL_FINDR="van.pi" -> "post.minivan.pics:40000") — and can       #
#  overwrite your theme.css based on the remote response.            #
#                                                                    #
#  That is a supply-chain / phone-home risk this installer will NOT  #
#  ship. Nebula has been removed from the repo (themes/) and these   #
#  functions now just explain why and refuse to run.                #
#                                                                    #
#  If you still want Nebula, get it directly from the Blueprint      #
#  store yourself and audit private/install.sh line-by-line first.   #
# ================================================================== #

install_nebula() {
  banner; echo "Install Nebula Theme"; line
  err "Nebula has been REMOVED from this installer."
  echo ""
  msg "A security review found its install.sh sources a shell script that:"
  msg "  - overrides the 'pwd' shell builtin"
  msg "  - extracts your panel's real domain"
  msg "  - sends it via plain HTTP to an obfuscated external host"
  msg "  - can silently overwrite your theme.css based on the response"
  echo ""
  msg "This is not something we're willing to install on your panel automatically."
  msg "If you still want it, get it from the Blueprint store yourself and read"
  msg "private/install.sh in full before running it."
  pause
}

uninstall_nebula() {
  banner; echo "Uninstall Nebula"; line
  if command -v blueprint >/dev/null 2>&1; then
    local PD; PD="$(get_panel_dir)"; cd "$PD" 2>/dev/null || true
    if blueprint -list 2>/dev/null | grep -qi nebula; then
      warn "Nebula appears to be installed from a previous version of this installer."
      blueprint -remove nebula 2>&1 | tee -a "$LOG_FILE"
      local BP_EXIT=${PIPESTATUS[0]}
      if [ "$BP_EXIT" -eq 0 ]; then
        untrack_extension "nebula"; ok "Nebula removed."
      else
        err "Failed to remove Nebula (exit code $BP_EXIT). You may need to remove it manually via blueprint -remove nebula."
      fi
      pause; return
    fi
  fi
  msg "Nebula is not installed (or Blueprint isn't installed)."
  pause
}
