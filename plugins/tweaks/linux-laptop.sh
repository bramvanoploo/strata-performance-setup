#!/usr/bin/env bash
# PLUGIN_ID: linux-laptop
# PLUGIN_NAME: linux-laptop
# PLUGIN_DESC: Linux laptop OEM thermal & fan profile tweaks

register_tweak --id "msi_cooling" --stars 4 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported false --experimental-non-arch false
register_tweak --id "acpi_platform_profile" --stars 3 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported false --experimental-non-arch false
register_tweak --id "asus_perf" --stars 3 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported false --experimental-non-arch false
register_tweak --id "dell_thermal" --stars 3 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported false --experimental-non-arch false
register_tweak --id "lenovo_legion" --stars 4 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported false --experimental-non-arch false
register_tweak --id "system76_perf" --stars 3 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported false --experimental-non-arch false
register_tweak --id "tuxedo_perf" --stars 3 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported false --experimental-non-arch false
register_tweak --id "apple_smc_cooling" --stars 3 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported false --experimental-non-arch false

# 3. MSI EC Cooling
applicable_msi_cooling() {
  [[ "$HAS_MSI_EC" == true ]] || return 1
  [[ -d /sys/devices/platform/msi-ec ]] && return 0
  [[ "$DISTRO_FAMILY" == "arch" ]] && (pkg_available repo msi-ec-dkms-git || pkg_available aur msi-ec-dkms-git)
}
title_msi_cooling() { echo "MSI EC Gaming/Turbo Mode & Aggressive Cooling (msi-ec / Cooler Boost)"; }
status_msi_cooling() { service_installed msi-gaming-cooling.service && unit_enabled msi-gaming-cooling.service; }
explain_msi_cooling() {
  cat <<'EOF'
Impact:
  Configures msi-ec + ec_sys and creates a persistent service setting
  shift_mode=turbo, fan_mode=advanced, and optionally cooler_boost=on
  to maximize thermal headroom under sustained GPU/CPU load.
EOF
}
apply_msi_cooling() {
  if [[ "$DISTRO_FAMILY" == "arch" ]]; then
    if [[ ! -d /sys/devices/platform/msi-ec ]]; then
      prompt_install_deps aur msi-ec-dkms-git mcontrolcenter-bin || true
    elif ! pkg_installed mcontrolcenter-bin; then
      prompt_install_deps aur mcontrolcenter-bin || true
    fi
  fi
  run_root mkdir -p /etc/modprobe.d
  echo "options ec_sys write_support=1" | run_root tee /etc/modprobe.d/strata-ec_sys.conf >/dev/null
  run_root modprobe ec_sys write_support=1 2>/dev/null || true
  run_root modprobe msi_ec 2>/dev/null || true

  local enable_cb="off"
  read -r -p "Also force Cooler Boost (max fan speed) at boot? [y/N]: " cb_ans
  [[ "$cb_ans" =~ ^[Yy]$ ]] && enable_cb="on"

  install_service msi-gaming-cooling.service <<EOF
[Unit]
Description=MSI EC Turbo / Gaming Cooling Profile for Strata
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '[ -w /sys/devices/platform/msi-ec/shift_mode ] && echo turbo > /sys/devices/platform/msi-ec/shift_mode; [ -w /sys/devices/platform/msi-ec/fan_mode ] && echo advanced > /sys/devices/platform/msi-ec/fan_mode; [ -w /sys/devices/platform/msi-ec/cooler_boost ] && echo ${enable_cb} > /sys/devices/platform/msi-ec/cooler_boost || true'
ExecStop=/bin/sh -c '[ -w /sys/devices/platform/msi-ec/cooler_boost ] && echo off > /sys/devices/platform/msi-ec/cooler_boost; [ -w /sys/devices/platform/msi-ec/shift_mode ] && echo comfort > /sys/devices/platform/msi-ec/shift_mode || true'

[Install]
WantedBy=multi-user.target
EOF
}
revert_msi_cooling() {
  remove_service msi-gaming-cooling.service
  run_root rm -f /etc/modprobe.d/strata-ec_sys.conf
  run_root sh -c '[ -w /sys/devices/platform/msi-ec/cooler_boost ] && echo off > /sys/devices/platform/msi-ec/cooler_boost; [ -w /sys/devices/platform/msi-ec/shift_mode ] && echo comfort > /sys/devices/platform/msi-ec/shift_mode' 2>/dev/null || true
}

# 3b. ACPI Platform Thermal Profile
applicable_acpi_platform_profile() {
  [[ -f /sys/firmware/acpi/platform_profile ]] && grep -qw "performance" /sys/firmware/acpi/platform_profile_choices 2>/dev/null
}
title_acpi_platform_profile() { echo "ACPI Platform Thermal Profile (performance)"; }
status_acpi_platform_profile() {
  [[ "$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)" == "performance" ]] && service_installed strata-acpi-profile.service
}
explain_acpi_platform_profile() {
  cat <<'EOF'
Impact:
  Sets /sys/firmware/acpi/platform_profile to 'performance' (supported on
  ThinkPad, IdeaPad, Legion, ASUS, HP, Dell, Acer, AMD PMF) via systemd.
EOF
}
apply_acpi_platform_profile() {
  install_service strata-acpi-profile.service <<'EOF'
[Unit]
Description=Set ACPI Platform Thermal Profile to Performance for Strata
After=multi-user.target power-profiles-daemon.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'if command -v powerprofilesctl >/dev/null 2>&1 && systemctl is-active --quiet power-profiles-daemon.service; then powerprofilesctl set performance; elif [ -w /sys/firmware/acpi/platform_profile ]; then echo performance > /sys/firmware/acpi/platform_profile; fi || true'
ExecStop=/bin/sh -c 'if command -v powerprofilesctl >/dev/null 2>&1 && systemctl is-active --quiet power-profiles-daemon.service; then powerprofilesctl set balanced; elif [ -w /sys/firmware/acpi/platform_profile ]; then echo balanced > /sys/firmware/acpi/platform_profile; fi || true'

[Install]
WantedBy=multi-user.target
EOF
}
revert_acpi_platform_profile() {
  remove_service strata-acpi-profile.service
  if command -v powerprofilesctl >/dev/null 2>&1 && unit_active power-profiles-daemon.service; then
    powerprofilesctl set balanced 2>/dev/null || true
  else
    run_root sh -c '[ -w /sys/firmware/acpi/platform_profile ] && echo balanced > /sys/firmware/acpi/platform_profile' 2>/dev/null || true
  fi
}

# 3c. ASUS
applicable_asus_perf() {
  grep -qi "ASUSTeK" <<< "$SYS_VENDOR" && [[ "$IS_LAPTOP" == true ]] || return 1
  command -v asusctl >/dev/null 2>&1 || pkg_available repo asusctl || pkg_available aur asusctl
}
title_asus_perf() { echo "ASUS ROG/TUF Performance Profile (asusctl / asusd)"; }
status_asus_perf() { command -v asusctl >/dev/null 2>&1 && unit_active asusd.service && grep -qi "Performance" <<< "$(asusctl profile -p 2>/dev/null || true)"; }
explain_asus_perf() { echo -e "Impact:\n  Enables asusd.service and switches asusctl profile to 'Performance'."; }
apply_asus_perf() {
  command -v asusctl >/dev/null 2>&1 || prompt_install_repo_or_aur asusctl || return 0
  service_ctl enable-now asusd.service 2>/dev/null || true
  asusctl profile -P Performance 2>/dev/null || true
}
revert_asus_perf() { command -v asusctl >/dev/null 2>&1 && asusctl profile -P Balanced 2>/dev/null || true; }

# 3d. Dell
applicable_dell_thermal() {
  grep -qi "Dell" <<< "$SYS_VENDOR" || return 1
  # Modern kernels (dell_pc) expose /sys/firmware/acpi/platform_profile and
  # filter legacy userspace smbios-thermal-ctl SMI calls; prefer acpi_platform_profile.
  applicable_acpi_platform_profile && return 1
  command -v smbios-thermal-ctl >/dev/null 2>&1 || pkg_available repo libsmbios || pkg_available repo smbios-utils
}
title_dell_thermal() { echo "Dell BIOS Ultra-Performance Thermal Mode (smbios-thermal-ctl)"; }
status_dell_thermal() { command -v smbios-thermal-ctl >/dev/null 2>&1 && grep -qi "performance" <<< "$(run_root smbios-thermal-ctl -g 2>/dev/null || true)"; }
explain_dell_thermal() { echo -e "Impact:\n  Sets Dell BIOS thermal management mode to 'performance' via smbios-thermal-ctl."; }
apply_dell_thermal() {
  if ! command -v smbios-thermal-ctl >/dev/null 2>&1; then
    case "$DISTRO_FAMILY" in
      arch)   prompt_install_deps repo libsmbios || return 0 ;;
      fedora) prompt_install_deps repo smbios-utils || prompt_install_deps repo libsmbios || return 0 ;;
      debian) prompt_install_deps repo smbios-utils || return 0 ;;
      suse)   prompt_install_deps repo smbios-utils-bin || prompt_install_deps repo libsmbios || return 0 ;;
    esac
  fi
  if ! run_root smbios-thermal-ctl --set-thermal-mode=performance; then
    echo -e "${C_YELLOW}smbios-thermal-ctl failed (kernel may filter SMI calls or SMM mitigations are enabled in BIOS).${C_RESET}"
  fi
}
revert_dell_thermal() { command -v smbios-thermal-ctl >/dev/null 2>&1 && run_root smbios-thermal-ctl --set-thermal-mode=balanced 2>/dev/null || true; }

# 3e. Lenovo Legion
applicable_lenovo_legion() {
  grep -qi "LENOVO" <<< "$SYS_VENDOR" && grep -qi "Legion" <<< "$PRODUCT_NAME" || return 1
  command -v legion_cli >/dev/null 2>&1 || pkg_available repo lenovo-legion || pkg_available aur lenovo-legion-dkms-git
}
title_lenovo_legion() { echo "Lenovo Legion Performance & Cooling (LenovoLegionLinux)"; }
status_lenovo_legion() { unit_enabled legiond.service && unit_active legiond.service; }
explain_lenovo_legion() { echo -e "Impact:\n  Enables legiond.service for Lenovo Legion custom fan curves and max TDP."; }
apply_lenovo_legion() {
  command -v legion_cli >/dev/null 2>&1 || prompt_install_repo_or_aur lenovo-legion || prompt_install_deps aur lenovo-legion-dkms-git || return 0
  service_ctl enable-now legiond.service 2>/dev/null || true
}
revert_lenovo_legion() { service_ctl disable-now legiond.service 2>/dev/null || true; }

# 3f. System76
applicable_system76_perf() {
  grep -qi "System76" <<< "$SYS_VENDOR" || return 1
  command -v system76-power >/dev/null 2>&1 || pkg_available repo system76-power || pkg_available aur system76-power
}
title_system76_perf() { echo "System76 High Performance Profile (system76-power)"; }
status_system76_perf() { command -v system76-power >/dev/null 2>&1 && unit_active system76-power.service && grep -qi "Performance" <<< "$(system76-power profile 2>/dev/null || true)"; }
explain_system76_perf() { echo -e "Impact:\n  Enables system76-power.service and sets the active profile to 'Performance'."; }
apply_system76_perf() {
  command -v system76-power >/dev/null 2>&1 || prompt_install_repo_or_aur system76-power || return 0
  service_ctl enable-now system76-power.service 2>/dev/null || true
  run_root system76-power profile performance 2>/dev/null || true
}
revert_system76_perf() { command -v system76-power >/dev/null 2>&1 && run_root system76-power profile balanced 2>/dev/null || true; }

# 3g. TUXEDO / Clevo / XMG / Schenker
applicable_tuxedo_perf() {
  grep -qiE "TUXEDO|XMG|SCHENKER|CLEVO|TONGFANG" <<< "${SYS_VENDOR} ${PRODUCT_NAME}" || return 1
  unit_exists tccd.service || pkg_available repo tuxedo-control-center || pkg_available aur tuxedo-control-center-bin
}
title_tuxedo_perf() { echo "TUXEDO Control Center Fan & TDP Daemon (tccd)"; }
status_tuxedo_perf() { unit_enabled tccd.service && unit_active tccd.service; }
explain_tuxedo_perf() { echo -e "Impact:\n  Enables tccd.service for high-TDP performance and fan profiles on TUXEDO laptops."; }
apply_tuxedo_perf() {
  unit_exists tccd.service || prompt_install_repo_or_aur tuxedo-control-center || prompt_install_deps aur tuxedo-control-center-bin || return 0
  service_ctl enable-now tccd.service 2>/dev/null || true
}
revert_tuxedo_perf() { service_ctl disable-now tccd.service 2>/dev/null || true; }

# 3h. Apple Mac SMC Cooling (Linux on Intel Macs)
applicable_apple_smc_cooling() {
  [[ "$IS_MACOS" == false && "$IS_APPLE_LINUX" == true && "$IS_ASAHI_LINUX" == false ]] || return 1
  [[ "$HAS_APPLESMC" == true ]] && return 0
  service_installed strata-applesmc-cooling.service && return 0
  [[ -f "$APPLESMC_MBPFAN_MARKER" ]] && return 0
  command -v mbpfan >/dev/null 2>&1 || pkg_available repo mbpfan || pkg_available aur mbpfan-git || pkg_available aur mbpfan
}
title_apple_smc_cooling() { echo "Apple Mac SMC Cooling & Aggressive Fan Control (mbpfan / applesmc)"; }
status_apple_smc_cooling() {
  if service_installed strata-applesmc-cooling.service && unit_enabled strata-applesmc-cooling.service; then
    return 0
  fi
  [[ -f "$APPLESMC_MBPFAN_MARKER" ]] && unit_enabled mbpfan.service && unit_active mbpfan.service
}
explain_apple_smc_cooling() {
  cat <<'EOF'
Impact:
  Improves thermal headroom on Intel Macs running Linux (Mac Pro, Mac mini,
  iMac, MacBook Pro) by configuring either an aggressive mbpfan thermal curve
  (55C ramp -> 82C max) or direct applesmc manual fan floors via systemd.
  Reverts cleanly to your previous mbpfan configuration / automatic SMC control.
EOF
}
apply_apple_smc_cooling() {
  run_root modprobe applesmc 2>/dev/null || true
  local smc_dir="" has_sysfs_fan=false has_mbpfan=false mode=""
  smc_dir="$(_applesmc_dir || true)"
  if [[ -n "$smc_dir" ]] && compgen -G "${smc_dir}/fan*_manual" >/dev/null 2>&1; then
    has_sysfs_fan=true
  fi
  if command -v mbpfan >/dev/null 2>&1 || pkg_available repo mbpfan || pkg_available aur mbpfan-git || pkg_available aur mbpfan; then
    has_mbpfan=true
  fi
  if [[ "$has_mbpfan" == true && "$has_sysfs_fan" == true ]]; then
    echo "Select Apple Mac cooling control method:"
    echo "  1) mbpfan aggressive thermal curve (recommended, scales dynamically)"
    echo "  2) Direct applesmc sysfs fan floor / manual speed"
    local c_ans=""
    read -r -p "Choose [1-2, default 1]: " c_ans || true
    case "${c_ans:-1}" in
      2) mode="sysfs" ;;
      1|"") mode="mbpfan" ;;
      *) echo -e "${C_RED}Invalid selection '${c_ans}'. Cancelled.${C_RESET}"; return 1 ;;
    esac
  elif [[ "$has_mbpfan" == true ]]; then
    mode="mbpfan"
  elif [[ "$has_sysfs_fan" == true ]]; then
    mode="sysfs"
  else
    echo -e "${C_YELLOW}Neither mbpfan nor writable applesmc fan*_manual sysfs nodes were found.${C_RESET}"
    return 1
  fi

  if [[ "$mode" == "mbpfan" ]]; then
    if ! command -v mbpfan >/dev/null 2>&1; then
      if pkg_available repo mbpfan; then
        prompt_install_deps repo mbpfan || return 0
      elif ! prompt_install_repo_or_aur mbpfan-git && ! prompt_install_repo_or_aur mbpfan; then
        return 0
      fi
    fi
    service_installed strata-applesmc-cooling.service && remove_service strata-applesmc-cooling.service
    run_root sh -c 'for d in "$1" /sys/devices/platform/applesmc* /sys/devices/platform/applesmc*/hwmon/hwmon*; do [ -n "$d" ] && [ -d "$d" ] || continue; for m in "$d"/fan*_manual; do [ -w "$m" ] && echo 0 > "$m"; done; done; true' _ "${STRATA_APPLESMC_DIR:-}" 2>/dev/null || true
    local was_active=false
    unit_active mbpfan.service && was_active=true
    if [[ -f /etc/mbpfan.conf && ! -f /etc/mbpfan.conf.bak.strata-setup ]]; then
      run_root cp /etc/mbpfan.conf /etc/mbpfan.conf.bak.strata-setup
    fi
    echo "was_active=${was_active}" | run_root tee "$APPLESMC_MBPFAN_MARKER" >/dev/null
    run_root tee /etc/mbpfan.conf >/dev/null <<'EOF'
# Managed by strata-performance-setup
[general]
low_temp = 55
high_temp = 72
max_temp = 82
polling_interval = 1
EOF
    if [[ "$HAS_SYSTEMD" == true ]]; then
      service_ctl enable-now mbpfan.service
      service_ctl restart mbpfan.service
    else
      local mbp_bin
      mbp_bin="$(command -v mbpfan || true)"
      if [[ -n "$mbp_bin" ]]; then
        install_service strata-applesmc-cooling.service <<EOF
[Unit]
Description=Apple Mac mbpfan Cooling Service for Strata
After=multi-user.target

[Service]
Type=simple
ExecStart=${mbp_bin} -f

[Install]
WantedBy=multi-user.target
EOF
      fi
    fi
    echo -e "${C_GREEN}Configured aggressive mbpfan cooling profile.${C_RESET}"
    return 0
  fi

  local pct=""
  read -r -p "Target minimum manual fan speed percentage [50-100, default 85]: " pct || true
  pct="${pct:-85}"
  if ! [[ "$pct" =~ ^[0-9]+$ ]] || (( pct < 50 || pct > 100 )); then
    echo -e "${C_RED}Invalid percentage '${pct}' (must be 50-100). Cancelled.${C_RESET}"
    return 1
  fi
  unit_active mbpfan.service && service_ctl disable-now mbpfan.service 2>/dev/null || true
  local smc_dir_safe=""
  if [[ -n "${STRATA_APPLESMC_DIR:-}" && "${STRATA_APPLESMC_DIR}" =~ ^[A-Za-z0-9/_.-]+$ ]]; then
    smc_dir_safe="${STRATA_APPLESMC_DIR}"
  fi
  install_service strata-applesmc-cooling.service <<EOF
[Unit]
Description=Apple Mac applesmc Fan Speed Control for Strata (${pct}%)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'modprobe applesmc 2>/dev/null || true; for d in "${smc_dir_safe}" /sys/devices/platform/applesmc* /sys/devices/platform/applesmc*/hwmon/hwmon*; do [ -n "\$d" ] && [ -d "\$d" ] || continue; for m in "\$d"/fan*_manual; do [ -w "\$m" ] || continue; b="\${m%_manual}"; [ -r "\${b}_min" ] && [ -r "\${b}_max" ] && [ -w "\${b}_output" ] || continue; mn=\$(tr -d "[:space:]" < "\${b}_min" 2>/dev/null || echo 0); mx=\$(tr -d "[:space:]" < "\${b}_max" 2>/dev/null || echo 0); case "\$mn:\$mx" in *[!0-9:]*|:|*:|:* ) continue ;; esac; [ "\$mx" -gt "\$mn" ] 2>/dev/null || continue; tgt=\$(( mn + (mx - mn) * ${pct} / 100 )); echo 1 > "\$m"; echo "\$tgt" > "\${b}_output"; done; done; true'
ExecStop=/bin/sh -c 'for d in "${smc_dir_safe}" /sys/devices/platform/applesmc* /sys/devices/platform/applesmc*/hwmon/hwmon*; do [ -n "\$d" ] && [ -d "\$d" ] || continue; for m in "\$d"/fan*_manual; do [ -w "\$m" ] && echo 0 > "\$m"; done; done; true'

[Install]
WantedBy=multi-user.target
EOF
}
revert_apple_smc_cooling() {
  service_installed strata-applesmc-cooling.service && remove_service strata-applesmc-cooling.service
  run_root sh -c 'for d in "$1" /sys/devices/platform/applesmc* /sys/devices/platform/applesmc*/hwmon/hwmon*; do [ -n "$d" ] && [ -d "$d" ] || continue; for m in "$d"/fan*_manual; do [ -w "$m" ] && echo 0 > "$m"; done; done; true' _ "${STRATA_APPLESMC_DIR:-}" 2>/dev/null || true
  if [[ -f "$APPLESMC_MBPFAN_MARKER" ]]; then
    local was_active="false"
    was_active="$(sed -n 's/^was_active=//p' "$APPLESMC_MBPFAN_MARKER" 2>/dev/null | head -n1)"
    if [[ -f /etc/mbpfan.conf.bak.strata-setup ]]; then
      run_root mv -f /etc/mbpfan.conf.bak.strata-setup /etc/mbpfan.conf
    else
      run_root rm -f /etc/mbpfan.conf
    fi
    if [[ "$HAS_SYSTEMD" == true ]]; then
      if [[ "$was_active" == "true" ]]; then
        service_ctl restart mbpfan.service 2>/dev/null || true
      else
        service_ctl disable-now mbpfan.service 2>/dev/null || true
      fi
    fi
    run_root rm -f "$APPLESMC_MBPFAN_MARKER"
  fi
}

