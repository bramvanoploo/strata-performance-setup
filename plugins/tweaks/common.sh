#!/usr/bin/env bash
# PLUGIN_ID: common
# PLUGIN_NAME: common
# PLUGIN_DESC: Cross-platform host tweaks (Linux & macOS)

register_tweak --id "prevent_sleep" --stars 1 --tier "recommended" --os "both" --laptop-recommended false --vm-supported true --experimental-non-arch false

# 1. Prevent Sleep
applicable_prevent_sleep() {
  [[ "$HAS_SYSTEMD" == true ]] || { [[ "$IS_MACOS" == true ]] && command -v pmset >/dev/null 2>&1; }
}
title_prevent_sleep() {
  if [[ "$IS_MACOS" == true ]]; then
    echo "Disable System Sleep & Idle Suspend (pmset Server Uptime)"
  else
    echo "Disable System Sleep & Lid-Close Suspend (Server Uptime)"
  fi
}
status_prevent_sleep() {
  if [[ "$IS_MACOS" == true ]]; then
    [[ -f "$MACOS_NOSLEEP_MARKER" ]] || return 1
    local _slp _sd
    _slp="$(_pmset_ac_val sleep || true)"
    _sd="$(pmset -g 2>/dev/null | awk '$1 == "SleepDisabled" {print $2; exit}')"
    [[ "$_slp" == "0" || "$_sd" == "1" ]]
    return $?
  fi
  [[ "$(systemctl is-enabled sleep.target 2>/dev/null || true)" == "masked" ]]
}
explain_prevent_sleep() {
  if [[ "$IS_MACOS" == true ]]; then
    cat <<'EOF'
Impact:
  Configures pmset so the Mac does not enter idle sleep, standby, autopoweroff,
  or Power Nap while serving Strata (on MacBooks, scoped to AC power; optionally
  disables sleep completely for closed-clamshell server operation).
  Previous pmset values are saved and restored cleanly on revert.
EOF
  else
    cat <<'EOF'
Impact:
  Masks systemd sleep/suspend/hibernate targets and ignores lid-close events
  on laptops so long-running Strata inference is never interrupted.
EOF
  fi
}
apply_prevent_sleep() {
  if [[ "$IS_MACOS" == true ]]; then
    local scope="-a" k v prev_lines=""
    [[ "$IS_LAPTOP" == true ]] && scope="-c"
    if [[ -r "$MACOS_NOSLEEP_MARKER" ]]; then
      prev_lines="$(grep -v '^disablesleep_set=' "$MACOS_NOSLEEP_MARKER" 2>/dev/null || true)"
      [[ -n "$prev_lines" ]] && prev_lines+=$'\n'
    fi
    if [[ -z "$prev_lines" ]]; then
      prev_lines+="scope=${scope}"$'\n'
      for k in sleep standby autopoweroff powernap; do
        v="$(_pmset_ac_val "$k" || true)"
        [[ "$v" =~ ^[0-9]+$ ]] && prev_lines+="${k}=${v}"$'\n'
      done
      local sd_prev=""
      sd_prev="$(pmset -g 2>/dev/null | awk '$1 == "SleepDisabled" {print $2; exit}')"
      [[ "$sd_prev" =~ ^[0-9]+$ ]] && prev_lines+="SleepDisabled=${sd_prev}"$'\n'
    fi
    if ! run_root pmset "$scope" sleep 0 standby 0 autopoweroff 0 powernap 0; then
      echo -e "${C_RED}Failed to update pmset sleep settings.${C_RESET}"
      return 1
    fi
    run_root mkdir -p "$MACOS_SUPPORT_DIR"
    printf '%s' "$prev_lines" | run_root tee "$MACOS_NOSLEEP_MARKER" >/dev/null
    if [[ "$IS_LAPTOP" == true ]] && confirm_yn "Also disable sleep completely when closed/on lid-close (pmset -a disablesleep 1)? [y/N]: " "N"; then
      run_root pmset -a disablesleep 1
      echo "disablesleep_set=1" | run_root tee -a "$MACOS_NOSLEEP_MARKER" >/dev/null
    fi
    return 0
  fi
  run_root systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
  if [[ "$IS_LAPTOP" == true ]]; then
    run_root mkdir -p /etc/systemd/logind.conf.d
    run_root tee /etc/systemd/logind.conf.d/99-strata-nosleep.conf >/dev/null <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF
    run_root systemctl reload-or-restart systemd-logind || true
  fi
}
revert_prevent_sleep() {
  if [[ "$IS_MACOS" == true ]]; then
    local scope="-a" line k v had_disablesleep=false
    [[ "$IS_LAPTOP" == true ]] && scope="-c"
    if [[ -r "$MACOS_NOSLEEP_MARKER" ]]; then
      while IFS='=' read -r k v; do
        case "$k" in
          scope) [[ -n "$v" ]] && scope="$v" ;;
          sleep|standby|autopoweroff|powernap)
            [[ "$v" =~ ^[0-9]+$ ]] && run_root pmset "$scope" "$k" "$v" 2>/dev/null || true
            ;;
          SleepDisabled)
            [[ "$v" =~ ^[0-9]+$ ]] && run_root pmset -a disablesleep "$v" 2>/dev/null || true
            ;;
          disablesleep_set) [[ "$v" == "1" ]] && had_disablesleep=true ;;
        esac
      done < "$MACOS_NOSLEEP_MARKER"
      [[ "$had_disablesleep" == true ]] && run_root pmset -a disablesleep 0 2>/dev/null || true
      run_root rm -f "$MACOS_NOSLEEP_MARKER"
    else
      run_root pmset -a disablesleep 0 2>/dev/null || true
      run_root pmset "$scope" sleep 10 standby 1 autopoweroff 1 powernap 1 2>/dev/null || true
    fi
    return 0
  fi
  run_root systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
  if [[ -f /etc/systemd/logind.conf.d/99-strata-nosleep.conf ]]; then
    run_root rm -f /etc/systemd/logind.conf.d/99-strata-nosleep.conf
    run_root systemctl reload-or-restart systemd-logind || true
  fi
}

