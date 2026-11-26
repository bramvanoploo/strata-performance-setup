#!/usr/bin/env bash
# PLUGIN_ID: accelerators
# PLUGIN_NAME: accelerators
# PLUGIN_DESC: Non-GPU AI accelerators & edge NPU tweaks (Tenstorrent, Rockchip, Hailo, Ascend, Moore Threads)

register_tweak --id "tenstorrent_setup" --stars 5 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported false --experimental-non-arch false
register_tweak --id "rockchip_rk3588_npu" --stars 4 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported false --experimental-non-arch false
register_tweak --id "hailo_npu_setup" --stars 4 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported false --experimental-non-arch false
register_tweak --id "huawei_ascend_cann" --stars 4 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported true --experimental-non-arch false
register_tweak --id "moore_threads_musa" --stars 4 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported true --experimental-non-arch false

_accel_write_udev() {
  local rule_file="$1" rule_body="$2" grp="render"
  getent group render >/dev/null 2>&1 || grp="video"
  printf '%s\n' "${rule_body//__GRP__/$grp}" | run_root tee "$rule_file" >/dev/null
  run_root udevadm control --reload >/dev/null 2>&1 || true
  run_root udevadm trigger >/dev/null 2>&1 || true
  if [[ "${TARGET_USER:-root}" != "root" ]] && getent group "$grp" >/dev/null 2>&1; then
    run_root usermod -aG "$grp" "$TARGET_USER" 2>/dev/null || true
  fi
}

# 1. Tenstorrent Wormhole / Blackhole (tt-kmd, device permissions, hugepages)
TT_UDEV="/etc/udev/rules.d/66-strata-tenstorrent.rules"
TT_SYSCTL="/etc/sysctl.d/99-strata-tenstorrent.conf"

applicable_tenstorrent_setup() {
  [[ "$HAS_TENSTORRENT" == true ]] || [[ -f "$TT_SYSCTL" ]] || compgen -G "/dev/tenstorrent*" >/dev/null 2>&1
}
title_tenstorrent_setup() { echo "Tenstorrent NPU Hugepages, KMD & Device Permissions (tt-metal / vLLM)"; }
status_tenstorrent_setup() {
  local hp
  hp="$(sysctl -n vm.nr_hugepages 2>/dev/null || echo 0)"
  [[ -f "$TT_UDEV" && -f "$TT_SYSCTL" && "$hp" =~ ^[0-9]+$ ]] && (( hp >= 64 ))
}
explain_tenstorrent_setup() {
  cat <<'EOF'
Impact:
  Configures 2 MiB hugepages (vm.nr_hugepages=2048, ~4 GiB) required by
  Tenstorrent's tt-umd/tt-metal stack, loads tenstorrent KMD if present,
  and installs udev rules granting 'render' group access to /dev/tenstorrent*.
EOF
}
apply_tenstorrent_setup() {
  run_root modprobe tenstorrent 2>/dev/null || true
  write_sysctl_with_prev "$TT_SYSCTL" "vm.nr_hugepages=2048"
  _accel_write_udev "$TT_UDEV" 'SUBSYSTEM=="tenstorrent", KERNEL=="tenstorrent*", GROUP="__GRP__", MODE="0660"'
  if ! compgen -G "/dev/tenstorrent*" >/dev/null 2>&1; then
    echo -e "${C_YELLOW}Note: /dev/tenstorrent* not present yet; install tt-kmd (https://github.com/tenstorrent/tt-kmd) and tt-smi.${C_RESET}"
  fi
}
revert_tenstorrent_setup() {
  restore_sysctl_prev "$TT_SYSCTL"
  run_root rm -f "$TT_UDEV"
  run_root udevadm control --reload >/dev/null 2>&1 || true
}

# 2. Rockchip RK3588 NPU / DMC / CPU Performance Governor
RK_UDEV="/etc/udev/rules.d/66-strata-rknpu.rules"

applicable_rockchip_rk3588_npu() {
  [[ "$HAS_ROCKCHIP_NPU" == true ]] || service_installed strata-rk3588-perf.service || [[ -e /dev/rknpu ]]
}
title_rockchip_rk3588_npu() { echo "Rockchip RK3588 NPU/DMC/CPU Performance Governor & /dev/rknpu Access"; }
status_rockchip_rk3588_npu() {
  service_installed strata-rk3588-perf.service && unit_enabled strata-rk3588-perf.service && [[ -f "$RK_UDEV" ]]
}
explain_rockchip_rk3588_npu() {
  cat <<'EOF'
Impact:
  Locks Rockchip RK3588 NPU, DDR memory controller (DMC), and CPU governors
  to 'performance' via a persistent service and grants 'render' group access
  on /dev/rknpu for RKLLM / rkllama inference.
EOF
}
apply_rockchip_rk3588_npu() {
  _accel_write_udev "$RK_UDEV" 'KERNEL=="rknpu", GROUP="__GRP__", MODE="0660"'
  install_service strata-rk3588-perf.service <<'EOF'
[Unit]
Description=Lock Rockchip RK3588 NPU, DMC, and CPU Governors to Performance
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for g in /sys/class/devfreq/*npu*/governor /sys/class/devfreq/*dmc*/governor /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$g" ] && echo performance > "$g" 2>/dev/null; done; true'
ExecStop=/bin/sh -c 'for g in /sys/class/devfreq/*npu*/governor /sys/class/devfreq/*dmc*/governor; do [ -w "$g" ] && echo simple_ondemand > "$g" 2>/dev/null; done; for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$g" ] && echo schedutil > "$g" 2>/dev/null; done; true'

[Install]
WantedBy=multi-user.target
EOF
}
revert_rockchip_rk3588_npu() {
  remove_service strata-rk3588-perf.service
  run_root rm -f "$RK_UDEV"
  run_root udevadm control --reload >/dev/null 2>&1 || true
}

# 3. Hailo-10H / Hailo-8 NPU Runtime & Device Access
HAILO_UDEV="/etc/udev/rules.d/66-strata-hailo.rules"

applicable_hailo_npu_setup() {
  [[ "$HAS_HAILO" == true ]] || [[ -f "$HAILO_UDEV" ]] || compgen -G "/dev/hailo*" >/dev/null 2>&1
}
title_hailo_npu_setup() { echo "Hailo-10H / Hailo-8 NPU Runtime & /dev/hailo Permissions"; }
status_hailo_npu_setup() {
  [[ -f "$HAILO_UDEV" ]] && (compgen -G "/dev/hailo*" >/dev/null 2>&1 || command -v hailortcli >/dev/null 2>&1)
}
explain_hailo_npu_setup() {
  cat <<'EOF'
Impact:
  Installs HailoRT / hailo-all packages when available (e.g. Raspberry Pi OS
  AI HAT+ 2) and grants 'render' group permissions on /dev/hailo*.
EOF
}
apply_hailo_npu_setup() {
  if [[ "$DISTRO_FAMILY" == "debian" ]]; then
    if pkg_available repo hailo-h10-all 2>/dev/null; then
      prompt_install_deps repo hailo-h10-all || true
    elif pkg_available repo hailo-all 2>/dev/null; then
      prompt_install_deps repo hailo-all || true
    fi
  fi
  run_root modprobe hailo_pci 2>/dev/null || run_root modprobe hailo1x_pci 2>/dev/null || true
  _accel_write_udev "$HAILO_UDEV" 'KERNEL=="hailo*", GROUP="__GRP__", MODE="0660"'
}
revert_hailo_npu_setup() {
  run_root rm -f "$HAILO_UDEV"
  run_root udevadm control --reload >/dev/null 2>&1 || true
}

# 4. Huawei Ascend NPU (CANN Environment & /dev/davinci* Permissions)
ASCEND_PROFILE="/etc/profile.d/strata-ascend.sh"
ASCEND_UDEV="/etc/udev/rules.d/66-strata-ascend.rules"

applicable_huawei_ascend_cann() {
  [[ "$HAS_ASCEND" == true ]] || [[ -f "$ASCEND_PROFILE" ]] || compgen -G "/dev/davinci*" >/dev/null 2>&1
}
title_huawei_ascend_cann() { echo "Huawei Ascend NPU CANN Environment & /dev/davinci Access"; }
status_huawei_ascend_cann() { [[ -f "$ASCEND_PROFILE" && -f "$ASCEND_UDEV" ]]; }
explain_huawei_ascend_cann() {
  cat <<'EOF'
Impact:
  Configures /etc/profile.d/strata-ascend.sh to source Ascend CANN set_env.sh
  and grants 'render' group access to /dev/davinci* and /dev/devmm_svm.
EOF
}
apply_huawei_ascend_cann() {
  run_root tee "$ASCEND_PROFILE" >/dev/null <<'EOF'
if [ -r /usr/local/Ascend/ascend-toolkit/set_env.sh ]; then
  . /usr/local/Ascend/ascend-toolkit/set_env.sh
fi
EOF
  run_root chmod 0644 "$ASCEND_PROFILE" 2>/dev/null || true
  _accel_write_udev "$ASCEND_UDEV" $'KERNEL=="davinci*", GROUP="__GRP__", MODE="0660"\nKERNEL=="devmm_svm", GROUP="__GRP__", MODE="0660"\nKERNEL=="hisi_hdc", GROUP="__GRP__", MODE="0660"'
}
revert_huawei_ascend_cann() {
  run_root rm -f "$ASCEND_PROFILE" "$ASCEND_UDEV"
  run_root udevadm control --reload >/dev/null 2>&1 || true
}

# 5. Moore Threads MUSA Runtime & /dev/musa* Access
MUSA_PROFILE="/etc/profile.d/strata-musa.sh"
MUSA_UDEV="/etc/udev/rules.d/66-strata-musa.rules"

applicable_moore_threads_musa() {
  [[ "$HAS_MTHREADS" == true ]] || [[ -f "$MUSA_PROFILE" ]] || compgen -G "/dev/musa*" >/dev/null 2>&1
}
title_moore_threads_musa() { echo "Moore Threads MUSA Toolkit Environment & /dev/musa Access"; }
status_moore_threads_musa() { [[ -f "$MUSA_PROFILE" && -f "$MUSA_UDEV" ]]; }
explain_moore_threads_musa() {
  cat <<'EOF'
Impact:
  Configures MUSA_HOME (/usr/local/musa) in /etc/profile.d/strata-musa.sh and
  grants 'render' group access to /dev/musa* devices.
EOF
}
apply_moore_threads_musa() {
  run_root tee "$MUSA_PROFILE" >/dev/null <<'EOF'
if [ -d /usr/local/musa ]; then
  export MUSA_HOME=/usr/local/musa
  export PATH="/usr/local/musa/bin:${PATH}"
  export LD_LIBRARY_PATH="/usr/local/musa/lib:${LD_LIBRARY_PATH:-}"
fi
EOF
  run_root chmod 0644 "$MUSA_PROFILE" 2>/dev/null || true
  _accel_write_udev "$MUSA_UDEV" 'KERNEL=="musa*", GROUP="__GRP__", MODE="0660"'
}
revert_moore_threads_musa() {
  run_root rm -f "$MUSA_PROFILE" "$MUSA_UDEV"
  run_root udevadm control --reload >/dev/null 2>&1 || true
}
