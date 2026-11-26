#!/usr/bin/env bash
# PLUGIN_ID: intel
# PLUGIN_NAME: intel
# PLUGIN_DESC: Intel GPU, RAPL, thermald, and P-core pinning tweaks

register_tweak --id "intel_gpu_perf" --stars 4 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported true --experimental-non-arch false
register_tweak --id "intel_rapl" --stars 4 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported false --experimental-non-arch false
register_tweak --id "intel_thermald" --stars 2 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported false --experimental-non-arch false
register_tweak --id "intel_compute_stack" --stars 4 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "intel_npu_stack" --stars 3 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported false --experimental-non-arch false
register_tweak --id "intel_pcore_pinning" --stars 3 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported false --experimental-non-arch false

applicable_intel_gpu_perf() {
  [[ "$HAS_INTEL_GPU" == true ]] || return 1
  compgen -G "/sys/class/drm/card*/gt_min_freq_mhz" >/dev/null 2>&1 || compgen -G "/sys/class/drm/card*/device/tile*/gt*/freq*/min_freq" >/dev/null 2>&1
}
title_intel_gpu_perf() { echo "Intel Arc / iGPU Maximum Base Frequency Lock (xe / i915 / SYCL)"; }
intel_gpu_perf_managed() { service_installed strata-intel-gpu-perf.service; }
status_intel_gpu_perf() { service_installed strata-intel-gpu-perf.service && unit_enabled strata-intel-gpu-perf.service; }
explain_intel_gpu_perf() { echo -e "Impact:\n  Raises Intel GPU minimum frequency to RP0/max (supports xe and i915) for SYCL."; }
apply_intel_gpu_perf() {
  install_service strata-intel-gpu-perf.service <<'EOF'
[Unit]
Description=Set Intel GPU Min Frequency to Max for Strata
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for d in /sys/class/drm/card*; do [ -w "$d/gt_min_freq_mhz" ] && [ -r "$d/gt_max_freq_mhz" ] && cat "$d/gt_max_freq_mhz" > "$d/gt_min_freq_mhz"; done; for f in /sys/class/drm/card*/device/tile*/gt*/freq*; do [ -w "$f/min_freq" ] && [ -r "$f/rp0_freq" ] && cat "$f/rp0_freq" > "$f/min_freq"; done; true'
ExecStop=/bin/sh -c 'for d in /sys/class/drm/card*; do [ -w "$d/gt_min_freq_mhz" ] && [ -r "$d/gt_RPn_freq_mhz" ] && cat "$d/gt_RPn_freq_mhz" > "$d/gt_min_freq_mhz"; done; for f in /sys/class/drm/card*/device/tile*/gt*/freq*; do [ -w "$f/min_freq" ] && [ -r "$f/rpn_freq" ] && cat "$f/rpn_freq" > "$f/min_freq"; done; true'

[Install]
WantedBy=multi-user.target
EOF
}
revert_intel_gpu_perf() {
  remove_service strata-intel-gpu-perf.service
  run_root sh -c 'for d in /sys/class/drm/card*; do [ -w "$d/gt_min_freq_mhz" ] && [ -r "$d/gt_RPn_freq_mhz" ] && cat "$d/gt_RPn_freq_mhz" > "$d/gt_min_freq_mhz"; done; for f in /sys/class/drm/card*/device/tile*/gt*/freq*; do [ -w "$f/min_freq" ] && [ -r "$f/rpn_freq" ] && cat "$f/rpn_freq" > "$f/min_freq"; done' 2>/dev/null || true
}


# 12n. Intel RAPL Power Limits
RAPL_DIR="/sys/class/powercap/intel-rapl:0"
rapl_val() { local v; v="$(cat "$1" 2>/dev/null || true)"; [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }

applicable_intel_rapl() {
  service_installed strata-rapl.service && return 0
  grep -qi "GenuineIntel" /proc/cpuinfo 2>/dev/null || return 1
  [[ -r "$RAPL_DIR/constraint_0_power_limit_uw" ]] || return 1
  local max cur
  max="$(rapl_val "$RAPL_DIR/constraint_0_max_power_uw")"
  cur="$(rapl_val "$RAPL_DIR/constraint_0_power_limit_uw")"
  (( max > 0 && max > cur ))
}
title_intel_rapl() {
  echo "Intel CPU Power Limits to Platform Max (PL1 $(( $(rapl_val "$RAPL_DIR/constraint_0_power_limit_uw") / 1000000 ))W -> $(( $(rapl_val "$RAPL_DIR/constraint_0_max_power_uw") / 1000000 ))W)"
}
status_intel_rapl() { service_installed strata-rapl.service && unit_enabled strata-rapl.service; }
explain_intel_rapl() {
  cat <<'EOF'
Impact:
  Raises the Intel RAPL long-term (PL1) and short-term (PL2) package power limits
  to the platform maximum via a systemd service, removing power-limit throttling
  under sustained CPU load. Previous limits are saved and restored on revert.
  Combine with thermald on laptops so thermal limits still protect the CPU.
EOF
}
apply_intel_rapl() {
  local c0_max c1_max c0_cur c1_cur
  c0_max="$(rapl_val "$RAPL_DIR/constraint_0_max_power_uw")"
  c1_max="$(rapl_val "$RAPL_DIR/constraint_1_max_power_uw")"
  c0_cur="$(rapl_val "$RAPL_DIR/constraint_0_power_limit_uw")"
  c1_cur="$(rapl_val "$RAPL_DIR/constraint_1_power_limit_uw")"
  if [[ ! -f "$RAPL_MARKER" ]]; then
    echo "${c0_cur} ${c1_cur}" | run_root tee "$RAPL_MARKER" >/dev/null
  fi
  if ! echo "$c0_max" | run_root tee "$RAPL_DIR/constraint_0_power_limit_uw" >/dev/null 2>&1; then
    echo -e "${C_YELLOW}The firmware locks the RAPL power limits (BIOS setting); cannot change them.${C_RESET}"
    run_root rm -f "$RAPL_MARKER"
    return 1
  fi
  local c1_cmd=""
  (( c1_max > 0 )) && c1_cmd="[ -w ${RAPL_DIR}/constraint_1_power_limit_uw ] && echo ${c1_max} > ${RAPL_DIR}/constraint_1_power_limit_uw; "
  local p_c0=0 p_c1=0
  [[ -r "$RAPL_MARKER" ]] && read -r p_c0 p_c1 < "$RAPL_MARKER"
  install_service strata-rapl.service <<EOF
[Unit]
Description=Raise Intel RAPL Power Limits for Strata
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo ${c0_max} > ${RAPL_DIR}/constraint_0_power_limit_uw; ${c1_cmd}true'
ExecStop=-/bin/sh -c '[ ${p_c0:-0} -gt 0 ] && echo ${p_c0:-0} > ${RAPL_DIR}/constraint_0_power_limit_uw; [ ${p_c1:-0} -gt 0 ] && echo ${p_c1:-0} > ${RAPL_DIR}/constraint_1_power_limit_uw; true'

[Install]
WantedBy=multi-user.target
EOF
}
revert_intel_rapl() {
  remove_service strata-rapl.service
  if [[ -f "$RAPL_MARKER" ]]; then
    local p_c0 p_c1
    read -r p_c0 p_c1 < "$RAPL_MARKER"
    (( p_c0 > 0 )) && echo "$p_c0" | run_root tee "$RAPL_DIR/constraint_0_power_limit_uw" >/dev/null 2>&1
    (( p_c1 > 0 )) && echo "$p_c1" | run_root tee "$RAPL_DIR/constraint_1_power_limit_uw" >/dev/null 2>&1
    run_root rm -f "$RAPL_MARKER"
  fi
}

# 12o. Intel thermald
applicable_intel_thermald() {
  grep -qi "GenuineIntel" /proc/cpuinfo 2>/dev/null || return 1
  unit_exists thermald.service || command -v thermald >/dev/null 2>&1 || pkg_available repo thermald
}
title_intel_thermald() { echo "Intel Thermal Daemon (thermald, avoids hard thermal throttling)"; }
status_intel_thermald() { unit_enabled thermald.service && unit_active thermald.service; }
explain_intel_thermald() { echo -e "Impact:\n  Installs/enables thermald, which uses RAPL/P-state/powerclamp cooling to hold\n  Intel CPUs just below thermal limits instead of hitting abrupt hardware throttling."; }
apply_intel_thermald() {
  command -v thermald >/dev/null 2>&1 || prompt_install_deps repo thermald || return 0
  service_ctl enable-now thermald.service
}
revert_intel_thermald() { service_ctl disable-now thermald.service 2>/dev/null || true; }

# 12r. Intel compute stack
intel_compute_pkgs() {
  case "$DISTRO_FAMILY" in
    arch)   echo "intel-compute-runtime level-zero-loader" ;;
    fedora) echo "intel-compute-runtime oneapi-level-zero" ;;
    debian) echo "intel-opencl-icd libze-intel-gpu1 libze1" ;;
    suse)
      local pkgs=()
      if pkg_available repo intel-opencl; then pkgs+=(intel-opencl)
      elif pkg_available repo intel-compute-runtime; then pkgs+=(intel-compute-runtime)
      else return 0; fi
      pkg_available repo libze_intel_gpu1 && pkgs+=(libze_intel_gpu1)
      if pkg_available repo level-zero; then pkgs+=(level-zero)
      elif pkg_available repo libze1; then pkgs+=(libze1)
      else return 0; fi
      echo "${pkgs[*]}"
      ;;
    *)      echo "" ;;
  esac
}

applicable_intel_compute_stack() {
  [[ "$HAS_INTEL_GPU" == true ]] || return 1
  local pkgs p
  pkgs="$(intel_compute_pkgs)"
  [[ -n "$pkgs" ]] || return 1
  for p in $pkgs; do pkg_available repo "$p" || return 1; done
}
title_intel_compute_stack() { echo "Intel GPU Compute Runtime (OpenCL / Level Zero for SYCL inference)"; }
status_intel_compute_stack() {
  local p
  for p in $(intel_compute_pkgs); do pkg_installed "$p" || return 1; done
}
explain_intel_compute_stack() { echo -e "Impact:\n  Installs the Intel compute runtime and Level Zero loader ($(intel_compute_pkgs)).\n  Without them SYCL/OpenCL inference cannot use the Intel GPU and silently falls back to the CPU."; }
apply_intel_compute_stack() { prompt_install_deps repo $(intel_compute_pkgs) || return 0; }
revert_intel_compute_stack() { echo -e "${C_YELLOW}Compute runtime packages are shared libraries and are kept installed.${C_RESET}"; }

applicable_intel_pcore_pinning() {
  [[ "$HAS_SYSTEMD" == true ]] || return 1
  [[ -f /etc/systemd/system/strata.service.d/10-pcore-affinity.conf ]] && return 0
  [[ -r /sys/devices/cpu_core/cpus && -r /sys/devices/cpu_atom/cpus ]]
}
title_intel_pcore_pinning() {
  local pcpus=""
  [[ -r /sys/devices/cpu_core/cpus ]] && pcpus="$(cat /sys/devices/cpu_core/cpus 2>/dev/null || true)"
  echo "Intel Hybrid P-Core Pinning for strata.service (CPUs ${pcpus:-P-cores})"
}
status_intel_pcore_pinning() { [[ -f /etc/systemd/system/strata.service.d/10-pcore-affinity.conf ]]; }
explain_intel_pcore_pinning() {
  echo -e "Impact:\n  Adds a systemd drop-in for strata.service (CPUAffinity=<P-cores>) so Strata\n  runs on Performance cores instead of getting scheduled onto Efficiency cores."
}
apply_intel_pcore_pinning() {
  local pcpus
  pcpus="$(cat /sys/devices/cpu_core/cpus 2>/dev/null || true)"
  if [[ -z "$pcpus" ]]; then
    echo -e "${C_YELLOW}Could not read P-core list from /sys/devices/cpu_core/cpus.${C_RESET}"
    return 1
  fi
  run_root mkdir -p /etc/systemd/system/strata.service.d
  run_root tee /etc/systemd/system/strata.service.d/10-pcore-affinity.conf >/dev/null <<EOF
[Service]
CPUAffinity=${pcpus}
EOF
  service_ctl daemon-reload
  unit_active strata.service && echo -e "${C_YELLOW}Restart strata.service for P-core affinity to take effect.${C_RESET}" || true
}
revert_intel_pcore_pinning() {
  run_root rm -f /etc/systemd/system/strata.service.d/10-pcore-affinity.conf
  run_root rmdir /etc/systemd/system/strata.service.d 2>/dev/null || true
  service_ctl daemon-reload
}

# 12r2. Intel Core Ultra NPU (intel_vpu) Stack & Device Access
INTEL_NPU_UDEV="/etc/udev/rules.d/66-strata-intel-vpu.rules"

applicable_intel_npu_stack() {
  [[ "$HAS_INTEL_NPU" == true ]] || [[ -f "$INTEL_NPU_UDEV" ]] || [[ -d /sys/bus/pci/drivers/intel_vpu ]]
}
title_intel_npu_stack() { echo "Intel Core Ultra NPU Driver & /dev/accel Permissions (OpenVINO)"; }
status_intel_npu_stack() {
  [[ -f "$INTEL_NPU_UDEV" ]] && (lsmod 2>/dev/null | grep -qw intel_vpu || [[ -d /sys/bus/pci/drivers/intel_vpu ]])
}
explain_intel_npu_stack() {
  cat <<'EOF'
Impact:
  Loads the intel_vpu kernel driver, installs Level Zero / Intel NPU user-
  space driver packages when available, and grants 'render' group access to
  /dev/accel/accel* for OpenVINO Model Server (OVMS) NPU inference.
EOF
}
apply_intel_npu_stack() {
  run_root modprobe intel_vpu 2>/dev/null || true
  case "$DISTRO_FAMILY" in
    arch)
      pkg_available repo level-zero-loader 2>/dev/null && prompt_install_deps repo level-zero-loader || true
      pkg_available aur intel-npu-driver 2>/dev/null && prompt_install_deps aur intel-npu-driver || true
      ;;
    fedora)
      pkg_available repo oneapi-level-zero 2>/dev/null && prompt_install_deps repo oneapi-level-zero || true
      ;;
    debian)
      pkg_available repo libze1 2>/dev/null && prompt_install_deps repo libze1 || true
      ;;
  esac
  run_root tee "$INTEL_NPU_UDEV" >/dev/null <<'EOF'
SUBSYSTEM=="accel", KERNEL=="accel*", GROUP="render", MODE="0660"
EOF
  run_root udevadm control --reload >/dev/null 2>&1 || true
  run_root udevadm trigger --subsystem-match=accel >/dev/null 2>&1 || true
  if [[ "${TARGET_USER:-root}" != "root" ]] && getent group render >/dev/null 2>&1; then
    run_root usermod -aG render "$TARGET_USER" 2>/dev/null || true
  fi
  if [[ ! -d /sys/bus/pci/drivers/intel_vpu ]]; then
    echo -e "${C_YELLOW}Note: intel_vpu kernel driver is not active; ensure Linux 6.8+ and linux-firmware are installed.${C_RESET}"
  fi
}
revert_intel_npu_stack() {
  run_root rm -f "$INTEL_NPU_UDEV"
  run_root udevadm control --reload >/dev/null 2>&1 || true
}
