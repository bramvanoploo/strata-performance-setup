#!/usr/bin/env bash
# PLUGIN_ID: jetson
# PLUGIN_NAME: jetson
# PLUGIN_DESC: NVIDIA Jetson nvpmodel and fan tweaks

register_tweak --id "jetson_perf" --stars 4 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported false --experimental-non-arch false
register_tweak --id "jetson_fan" --stars 3 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported false --experimental-non-arch false

# 12s. NVIDIA Jetson
is_jetson() {
  [[ "$IS_JETSON" == true ]] && return 0
  [[ -f /etc/nv_tegra_release ]] && return 0
  [[ -r /proc/device-tree/model ]] && tr -d '\0' < /proc/device-tree/model | grep -qi "jetson"
}
jetson_maxn_id() {
  local id
  id="$(grep -oE 'POWER_MODEL ID=[0-9]+ NAME=MAXN[A-Za-z_]*' /etc/nvpmodel.conf 2>/dev/null | head -n1 | sed -E 's/POWER_MODEL ID=([0-9]+).*/\1/')"
  echo "${id:-0}"
}

applicable_jetson_perf() { is_jetson && command -v nvpmodel >/dev/null 2>&1; }
title_jetson_perf() { echo "NVIDIA Jetson MAXN Power Mode & Max Clocks (nvpmodel / jetson_clocks)"; }
status_jetson_perf() { service_installed strata-jetson-perf.service && unit_enabled strata-jetson-perf.service; }
explain_jetson_perf() {
  echo -e "Impact:\n  Switches the Jetson to its MAXN power model (nvpmodel -m $(jetson_maxn_id)) and pins CPU/GPU/EMC\n  clocks to maximum (jetson_clocks) at every boot. Clocks are restored on revert."
  if [[ "$IS_JETSON_TX2" == true ]]; then
    echo -e "  On Jetson TX2 (L4T R32), MAXN also enables both Denver 2 cores alongside\n  the 4 Cortex-A57 cores (default boot mode leaves Denver 2 cores offline)."
  fi
}
apply_jetson_perf() {
  local nv jc id
  nv="$(command -v nvpmodel)"; jc="$(command -v jetson_clocks || echo /usr/bin/jetson_clocks)"; id="$(jetson_maxn_id)"
  install_service strata-jetson-perf.service <<EOF
[Unit]
Description=Set Jetson MAXN Power Mode and Maximum Clocks for Strata
After=nvpmodel.service multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-${jc} --store
ExecStart=${nv} -m ${id}
ExecStart=-${jc}
ExecStop=-${jc} --restore

[Install]
WantedBy=multi-user.target
EOF
}
revert_jetson_perf() { remove_service strata-jetson-perf.service; }

# 12s2. NVIDIA Jetson PWM Fan Maximum Cooling
jetson_fan_pwm_path() {
  if [[ -e /sys/devices/pwm-fan/target_pwm ]]; then
    echo "/sys/devices/pwm-fan/target_pwm"
    return 0
  fi
  local hm
  for hm in /sys/class/hwmon/hwmon*; do
    [[ -r "$hm/name" ]] || continue
    if grep -qiE "pwm-?fan|tegra_pwmfan" "$hm/name" 2>/dev/null && [[ -e "$hm/pwm1" ]]; then
      echo "$hm/pwm1"
      return 0
    fi
  done
  return 1
}
applicable_jetson_fan() { is_jetson && jetson_fan_pwm_path >/dev/null 2>&1; }
title_jetson_fan() { echo "NVIDIA Jetson PWM Fan Maximum Cooling (target_pwm=255)"; }
status_jetson_fan() { service_installed strata-jetson-fan.service && unit_enabled strata-jetson-fan.service; }
explain_jetson_fan() {
  echo -e "Impact:\n  Locks the Jetson carrier board PWM fan to 100% (255) via systemd so the\n  SoC stays below thermal throttling thresholds during sustained MAXN inference."
}
apply_jetson_fan() {
  local pwm_path tc_path=""
  pwm_path="$(jetson_fan_pwm_path)" || return 1
  [[ -e /sys/devices/pwm-fan/temp_control ]] && tc_path="/sys/devices/pwm-fan/temp_control"
  install_service strata-jetson-fan.service <<EOF
[Unit]
Description=Set Jetson PWM Fan to Maximum Cooling for Strata
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '${tc_path:+[ -w ${tc_path} ] && echo 0 > ${tc_path}; }[ -w ${pwm_path} ] && echo 255 > ${pwm_path} || true'
ExecStop=/bin/sh -c '[ -w ${pwm_path} ] && echo 0 > ${pwm_path}; ${tc_path:+[ -w ${tc_path} ] && echo 1 > ${tc_path}; }true'

[Install]
WantedBy=multi-user.target
EOF
}
revert_jetson_fan() { remove_service strata-jetson-fan.service; }

# 12t. numactl interleave
