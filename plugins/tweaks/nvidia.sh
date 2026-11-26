#!/usr/bin/env bash
# PLUGIN_ID: nvidia
# PLUGIN_NAME: nvidia
# PLUGIN_DESC: NVIDIA GPU driver, power, clock, ECC, and datacenter tweaks

register_tweak --id "nvidia_persistenced" --stars 2 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported true --experimental-non-arch false
register_tweak --id "nvidia_fabricmanager" --stars 5 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported false --experimental-non-arch false
register_tweak --id "nvidia_powerd" --stars 2 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "nvidia_power_limit" --stars 2 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "nvidia_power_cap" --stars 3 --tier "opt_in" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "gpu_unlock" --stars 5 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch true
register_tweak --id "nvidia_sm70_table" --stars 4 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "nvidia_pstate" --stars 4 --tier "experimental" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "nvidia_clock_lock" --stars 1 --tier "high_idle" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "nvidia_ecc" --stars 4 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "nvidia_compute_mode" --stars 3 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "nvidia_mig_disable" --stars 4 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported true --experimental-non-arch false
register_tweak --id "nvidia_p2p_open" --stars 5 --tier "experimental" --os "linux" --laptop-recommended false --vm-supported false --experimental-non-arch false

# 7. NVIDIA Persistenced
applicable_nvidia_persistenced() {
  [[ "$HAS_NVIDIA" == true ]] && { unit_exists nvidia-persistenced.service || service_installed strata-nvidia-persistenced.service || command -v nvidia-persistenced >/dev/null 2>&1 || command -v nvidia-smi >/dev/null 2>&1; }
}
title_nvidia_persistenced() { echo "NVIDIA Persistence Mode (nvidia-persistenced)"; }
nvidia_persistenced_managed() { unit_exists nvidia-persistenced.service || service_installed strata-nvidia-persistenced.service; }
status_nvidia_persistenced() {
  if unit_exists nvidia-persistenced.service && unit_enabled nvidia-persistenced.service && unit_active nvidia-persistenced.service; then
    return 0
  fi
  if service_installed strata-nvidia-persistenced.service && unit_enabled strata-nvidia-persistenced.service; then
    return 0
  fi
  if command -v nvidia-smi >/dev/null 2>&1; then
    local pm_out
    pm_out="$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null || true)"
    if grep -qi "Enabled" <<<"$pm_out" && ! grep -qi "Disabled" <<<"$pm_out"; then
      return 0
    fi
  fi
  return 1
}
explain_nvidia_persistenced() { echo -e "Impact:\n  Keeps the NVIDIA driver initialized on headless hosts to avoid cold-start\n  delays and ensures persistent power/clock settings stay applied (no-op on\n  container/appliance hosts where the driver already stays resident)."; }
apply_nvidia_persistenced() {
  if unit_exists nvidia-persistenced.service; then
    service_ctl enable-now nvidia-persistenced.service
  elif [[ "$HAS_SYSTEMD" == true ]] && command -v nvidia-persistenced >/dev/null 2>&1; then
    local npd_bin
    npd_bin="$(command -v nvidia-persistenced)"
    install_service strata-nvidia-persistenced.service <<EOF
[Unit]
Description=NVIDIA Persistence Daemon (Strata)
Wants=syslog.target

[Service]
Type=forking
PIDFile=/var/run/nvidia-persistenced/nvidia-persistenced.pid
Restart=always
ExecStart=${npd_bin} --user root --persistence-mode
ExecStopPost=/bin/rm -rf /var/run/nvidia-persistenced

[Install]
WantedBy=multi-user.target
EOF
  else
    local smi_bin
    smi_bin="$(command -v nvidia-smi)" || return 1
    install_service strata-nvidia-persistenced.service <<EOF
[Unit]
Description=NVIDIA Persistence Mode (Strata)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${smi_bin} -pm 1
ExecStop=-${smi_bin} -pm 0

[Install]
WantedBy=multi-user.target
EOF
  fi
}
revert_nvidia_persistenced() {
  if service_installed strata-nvidia-persistenced.service; then
    remove_service strata-nvidia-persistenced.service
    run_root nvidia-smi -pm 0 >/dev/null 2>&1 || true
  fi
  if unit_exists nvidia-persistenced.service; then
    service_ctl disable-now nvidia-persistenced.service 2>/dev/null || true
  fi
}

# 7b. NVIDIA Fabric Manager (NVSwitch SXM Systems)
nvidia_fabricmanager_pkg() {
  if [[ "${NVIDIA_DRIVER_MAJOR:-0}" -gt 0 ]] && pkg_available repo "nvidia-fabricmanager-${NVIDIA_DRIVER_MAJOR}"; then
    echo "nvidia-fabricmanager-${NVIDIA_DRIVER_MAJOR}"
  elif pkg_available repo nvidia-fabricmanager; then
    echo "nvidia-fabricmanager"
  elif pkg_available repo nvidia-fabric-manager; then
    echo "nvidia-fabric-manager"
  else
    echo ""
  fi
}
applicable_nvidia_fabricmanager() {
  [[ "$HAS_NVIDIA" == true && "$HAS_NVIDIA_NVSWITCH" == true ]] || return 1
  unit_exists nvidia-fabricmanager.service || command -v nv-fabricmanager >/dev/null 2>&1 || [[ -n "$(nvidia_fabricmanager_pkg)" ]]
}
title_nvidia_fabricmanager() { echo "NVIDIA Fabric Manager (NVSwitch SXM Multi-GPU Fabric)"; }
status_nvidia_fabricmanager() { unit_enabled nvidia-fabricmanager.service && unit_active nvidia-fabricmanager.service; }
explain_nvidia_fabricmanager() {
  cat <<'EOF'
Impact:
  Installs/enables nvidia-fabricmanager.service on HGX / DGX NVSwitch SXM
  servers. Without Fabric Manager running, multi-GPU CUDA initialization fails
  with Error 802 ('system not yet initialized') across NVSwitch-linked GPUs.
EOF
}
apply_nvidia_fabricmanager() {
  if ! unit_exists nvidia-fabricmanager.service; then
    local pkg
    pkg="$(nvidia_fabricmanager_pkg)"
    if [[ -n "$pkg" ]]; then
      prompt_install_deps repo "$pkg" || return 0
      refresh_unit_files_cache
    fi
  fi
  if unit_exists nvidia-fabricmanager.service; then
    service_ctl enable-now nvidia-fabricmanager.service
  else
    echo -e "${C_YELLOW}nvidia-fabricmanager.service is not available; install the matching nvidia-fabricmanager package for driver ${NVIDIA_DRIVER_VER:-installed}.${C_RESET}"
    return 1
  fi
}
revert_nvidia_fabricmanager() { service_ctl disable-now nvidia-fabricmanager.service 2>/dev/null || true; }

# 8. NVIDIA Dynamic Boost
applicable_nvidia_powerd() {
  [[ "$HAS_NVIDIA" == true && "$HAS_NVIDIA_POWERD" == true ]] || return 1
  [[ "$IS_LAPTOP" == true ]] || grep -qiE "Laptop GPU|Mobile|Max-Q" <<<"${NVIDIA_GPU_NAMES[*]}"
}
title_nvidia_powerd() { echo "NVIDIA Dynamic Boost Daemon (nvidia-powerd)"; }
status_nvidia_powerd() { unit_enabled nvidia-powerd.service && unit_active nvidia-powerd.service; }
explain_nvidia_powerd() { echo -e "Impact:\n  Enables Dynamic Boost to shift power budget to mobile RTX GPUs under load."; }
apply_nvidia_powerd() { service_ctl enable-now nvidia-powerd.service; }
revert_nvidia_powerd() { service_ctl disable-now nvidia-powerd.service; }

# 9. NVIDIA Power Limit
nvidia_tunable_pl_indices() {
  local i
  for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
    [[ "${NVIDIA_GPU_PL_SUPPORTED[$i]}" == true ]] && echo "$i"
  done
}
batch_skip_nvidia_power_limit() {
  local revert_out_of_scope="${1:-false}"
  if status_nvidia_power_cap && [[ "$revert_out_of_scope" == false ]]; then
    echo -e "\n${C_YELLOW}Skipping NVIDIA Persistent Max GPU Power Limit because NVIDIA Thermal Power Cap ([OPT]) was kept active.${C_RESET}"
    return 0
  fi
  return 1
}
check_note_nvidia_power_limit() { echo " (no measured speedup at default PL)"; }
applicable_nvidia_power_limit() {
  [[ "$HAS_NVIDIA" == true && -n "$(nvidia_tunable_pl_indices)" ]]
}
title_nvidia_power_limit() {
  local idxs=()
  mapfile -t idxs < <(nvidia_tunable_pl_indices)
  if (( ${#idxs[@]} == 1 )); then
    local i="${idxs[0]}" from_w="${NVIDIA_GPU_DEF_PL[$i]}"
    [[ -n "${NVIDIA_GPU_CUR_PL[$i]}" && "${NVIDIA_GPU_CUR_PL[$i]}" -lt "${NVIDIA_GPU_DEF_PL[$i]}" ]] && from_w="${NVIDIA_GPU_CUR_PL[$i]}"
    echo "NVIDIA Persistent Max GPU Power Limit (${from_w}W -> ${NVIDIA_GPU_MAX_PL[$i]}W, headroom only)"
  else
    echo "NVIDIA Persistent Max GPU Power Limit (${#idxs[@]} GPUs, headroom only)"
  fi
}
status_nvidia_power_limit() {
  service_installed nvidia-power-limit.service && unit_enabled nvidia-power-limit.service || return 1
  local i cur mx any=false
  for i in $(nvidia_tunable_pl_indices); do
    any=true
    cur="${NVIDIA_GPU_CUR_PL[$i]}"
    mx="${NVIDIA_GPU_MAX_PL[$i]}"
    [[ -n "$cur" && "$cur" -ge "$mx" ]] || return 1
  done
  [[ "$any" == true ]]
}
explain_nvidia_power_limit() {
  local idxs=() i from_w svc_desc="systemd service"
  [[ "$HAS_SYSTEMD" == true ]] || svc_desc="boot service"
  mapfile -t idxs < <(nvidia_tunable_pl_indices)
  if (( ${#idxs[@]} == 1 )); then
    i="${idxs[0]}"
    from_w="${NVIDIA_GPU_DEF_PL[$i]}"
    [[ -n "${NVIDIA_GPU_CUR_PL[$i]}" && "${NVIDIA_GPU_CUR_PL[$i]}" -lt "${NVIDIA_GPU_DEF_PL[$i]}" ]] && from_w="${NVIDIA_GPU_CUR_PL[$i]}"
    echo -e "Impact:\n  Raises GPU power ceiling from ${from_w}W to ${NVIDIA_GPU_MAX_PL[$i]}W via persistent ${svc_desc}.\n  Prevents artificial throttling if the card hits its current/default cap (no speedup\n  if your workload draws below the default limit)."
  else
    echo -e "Impact:\n  Raises GPU power ceilings to maximum per GPU via persistent ${svc_desc}\n  (prevents throttling when power-limited; no effect below default cap):"
    for i in "${idxs[@]}"; do
      from_w="${NVIDIA_GPU_DEF_PL[$i]}"
      [[ -n "${NVIDIA_GPU_CUR_PL[$i]}" && "${NVIDIA_GPU_CUR_PL[$i]}" -lt "${NVIDIA_GPU_DEF_PL[$i]}" ]] && from_w="${NVIDIA_GPU_CUR_PL[$i]}"
      echo -e "  - GPU ${NVIDIA_GPU_INDICES[$i]} (${NVIDIA_GPU_NAMES[$i]}): ${from_w}W -> ${NVIDIA_GPU_MAX_PL[$i]}W"
    done
  fi
}
apply_nvidia_power_limit() {
  if service_installed strata-nvidia-power-cap.service; then
    remove_service strata-nvidia-power-cap.service
    run_root rm -f "$NVIDIA_POWER_CAP_MARKER"
  fi
  local smi_bin out i idx def mx exec_start="" exec_stop="" applied=0
  smi_bin="$(command -v nvidia-smi)"
  for i in $(nvidia_tunable_pl_indices); do
    idx="${NVIDIA_GPU_INDICES[$i]}"
    def="${NVIDIA_GPU_DEF_PL[$i]}"
    mx="${NVIDIA_GPU_MAX_PL[$i]}"
    if ! out="$(run_root "$smi_bin" -i "$idx" -pl "$mx" 2>&1)" || grep -qiE "not supported|failed|error|invalid|insufficient|unable" <<< "$out"; then
      echo -e "${C_YELLOW}nvidia-smi -i ${idx} -pl ${mx} failed on ${NVIDIA_GPU_NAMES[$i]}: ${out}${C_RESET}"
      continue
    fi
    exec_start+="ExecStart=${smi_bin} -i ${idx} -pl ${mx}"$'\n'
    exec_stop+="ExecStop=${smi_bin} -i ${idx} -pl ${def}"$'\n'
    applied=$((applied + 1))
  done
  if (( applied == 0 )); then
    return 1
  fi
  install_service nvidia-power-limit.service <<EOF
[Unit]
Description=Set NVIDIA GPU Power Limit to Maximum
After=nvidia-persistenced.service nvidia-powerd.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
${exec_start%$'\n'}
${exec_stop%$'\n'}

[Install]
WantedBy=multi-user.target
EOF
  refresh_nvidia_power_limits
}
revert_nvidia_power_limit() {
  remove_service nvidia-power-limit.service
  local i idx def
  for i in $(nvidia_tunable_pl_indices); do
    idx="${NVIDIA_GPU_INDICES[$i]}"
    def="${NVIDIA_GPU_DEF_PL[$i]}"
    run_root nvidia-smi -i "$idx" -pl "$def" >/dev/null 2>&1 || true
  done
  refresh_nvidia_power_limits
}

# 9b. NVIDIA Passive/Datacenter Thermal Power Cap
nvidia_cappable_pl_indices() {
  local i mn mx
  for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
    [[ "${NVIDIA_GPU_IS_DATACENTER[$i]}" == true || "${NVIDIA_GPU_IS_PASSIVE[$i]}" == true ]] || continue
    mn="${NVIDIA_GPU_MIN_PL[$i]}"
    mx="${NVIDIA_GPU_MAX_PL[$i]:-${NVIDIA_GPU_DEF_PL[$i]}}"
    [[ "$mn" =~ ^[0-9]+$ && "$mx" =~ ^[0-9]+$ ]] && (( mn > 0 && mx > mn )) && echo "$i"
  done
}
applicable_nvidia_power_cap() {
  [[ "$HAS_NVIDIA" == true && ( "$HAS_NVIDIA_DATACENTER" == true || "$HAS_NVIDIA_PASSIVE" == true ) ]] || { [[ -f "$NVIDIA_POWER_CAP_MARKER" ]]; return $?; }
  [[ -n "$(nvidia_cappable_pl_indices)" || -f "$NVIDIA_POWER_CAP_MARKER" ]]
}
title_nvidia_power_cap() { echo "NVIDIA Passive/Datacenter Thermal Power Cap (nvidia-smi -pl)"; }
note_nvidia_power_cap() { echo -e "${C_BLUE}[OPT]${C_RESET}"; }
status_nvidia_power_cap() { service_installed strata-nvidia-power-cap.service && unit_enabled strata-nvidia-power-cap.service; }
explain_nvidia_power_cap() {
  cat <<'EOF'
Impact:
  Applies a custom power cap (e.g. ~70% of default TDP, such as 175W on a 250W
  Tesla P40/P100/V100/A40/A100) via a persistent service. LLM token decode is
  memory-bandwidth bound rather than TDP-bound, so moderate capping typically
  retains ~95%+ decode throughput while preventing passive thermal throttling,
  cutting chassis fan noise, and lowering power draw.
  Trade-off: Lowers peak compute power ceiling under heavy prefill or batching.
EOF
  local i
  for i in $(nvidia_cappable_pl_indices); do
    echo -e "  - GPU ${NVIDIA_GPU_INDICES[$i]} (${NVIDIA_GPU_NAMES[$i]}): cur ${NVIDIA_GPU_CUR_PL[$i]:-?}W, range ${NVIDIA_GPU_MIN_PL[$i]}-${NVIDIA_GPU_MAX_PL[$i]:-${NVIDIA_GPU_DEF_PL[$i]}}W (default ${NVIDIA_GPU_DEF_PL[$i]:-?}W)"
  done
}
apply_nvidia_power_cap() {
  local -a idxs=()
  mapfile -t idxs < <(nvidia_cappable_pl_indices)
  if (( ${#idxs[@]} == 0 )); then
    echo -e "${C_YELLOW}No NVIDIA GPUs report adjustable min/max power limits via nvidia-smi.${C_RESET}"
    return 1
  fi
  local smi_bin first_i def_w min_w max_w rec_w target_w in_w
  smi_bin="$(command -v nvidia-smi)"
  first_i="${idxs[0]}"
  def_w="${NVIDIA_GPU_DEF_PL[$first_i]:-${NVIDIA_GPU_MAX_PL[$first_i]}}"
  min_w="${NVIDIA_GPU_MIN_PL[$first_i]}"
  max_w="${NVIDIA_GPU_MAX_PL[$first_i]:-$def_w}"
  rec_w="$(awk -v d="$def_w" -v mn="$min_w" 'BEGIN {v=int(d*0.7 + 0.5); if (v < mn) v=mn; print v}')"
  read -r -p "Target GPU power cap in watts (range ${min_w}-${max_w}W) [default: ${rec_w}]: " in_w
  target_w="${in_w:-$rec_w}"
  if ! [[ "$target_w" =~ ^[0-9]+$ ]] || (( target_w < min_w || target_w > max_w )); then
    echo -e "${C_RED}Power cap must be an integer between ${min_w} and ${max_w} W.${C_RESET}"
    return 1
  fi
  service_installed nvidia-power-limit.service && remove_service nvidia-power-limit.service
  local i idx g_min g_max g_def g_cap out exec_start="" exec_stop="" marker_lines="" applied=0
  for i in "${idxs[@]}"; do
    idx="${NVIDIA_GPU_INDICES[$i]}"
    g_min="${NVIDIA_GPU_MIN_PL[$i]}"
    g_max="${NVIDIA_GPU_MAX_PL[$i]:-${NVIDIA_GPU_DEF_PL[$i]}}"
    g_def="${NVIDIA_GPU_DEF_PL[$i]:-$g_max}"
    g_cap="$target_w"
    (( g_cap < g_min )) && g_cap="$g_min"
    (( g_cap > g_max )) && g_cap="$g_max"
    local smi_rc=0
    out="$(run_root "$smi_bin" -i "$idx" -pl "$g_cap" 2>&1)" || smi_rc=$?
    if (( smi_rc != 0 )) || grep -qiE "not supported|failed|error|invalid|insufficient|unable" <<<"$out"; then
      echo -e "${C_YELLOW}Could not set -pl ${g_cap} on GPU ${idx} (${NVIDIA_GPU_NAMES[$i]}): ${out}${C_RESET}"
      continue
    fi
    exec_start+="ExecStart=${smi_bin} -i ${idx} -pl ${g_cap}"$'\n'
    exec_stop+="ExecStop=-${smi_bin} -i ${idx} -pl ${g_def}"$'\n'
    marker_lines+="${idx}:${g_cap}:${g_def}"$'\n'
    applied=$((applied + 1))
  done
  (( applied > 0 )) || return 1
  printf "%s" "$marker_lines" | run_root tee "$NVIDIA_POWER_CAP_MARKER" >/dev/null
  install_service strata-nvidia-power-cap.service <<EOF
[Unit]
Description=Set NVIDIA Passive/Datacenter Thermal Power Cap for Strata
After=nvidia-persistenced.service strata-nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
${exec_start%$'\n'}
${exec_stop%$'\n'}

[Install]
WantedBy=multi-user.target
EOF
  refresh_nvidia_power_limits
}
revert_nvidia_power_cap() {
  remove_service strata-nvidia-power-cap.service
  if [[ -f "$NVIDIA_POWER_CAP_MARKER" ]]; then
    local idx _cap def
    while IFS=: read -r idx _cap def; do
      [[ "$idx" =~ ^[0-9]+$ && "$def" =~ ^[0-9]+$ ]] || continue
      run_root nvidia-smi -i "$idx" -pl "$def" >/dev/null 2>&1 || true
    done < "$NVIDIA_POWER_CAP_MARKER"
    run_root rm -f "$NVIDIA_POWER_CAP_MARKER"
  fi
  refresh_nvidia_power_limits
}


# 11. GPU Unlock
secure_boot_enabled() {
  local sb_var="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  if [[ -r "$sb_var" ]]; then
    local val
    val="$(od -An -t u1 -j 4 -N 1 "$sb_var" 2>/dev/null | tr -d '[:space:]')"
    [[ "$val" == "1" ]] && return 0
    [[ "$val" == "0" ]] && return 1
  fi
  if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled" && return 0
  fi
  return 1
}

gpu_unlock_installed() {
  pkg_installed gpu-unlock-dkms || pkg_installed gpu-unlock || [[ -d /sys/module/gpu_unlock ]] ||
    (command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -qi "gpu[_-]unlock")
}

gpu_unlock_build_deps() {
  local kver
  kver="$(uname -r)"
  case "$DISTRO_FAMILY" in
    debian)
      local hdr="linux-headers-${kver}"
      if ! pkg_installed "$hdr" && ! pkg_available repo "$hdr"; then
        if pkg_available repo "linux-headers-generic"; then
          hdr="linux-headers-generic"
        elif pkg_available repo "linux-headers-amd64"; then
          hdr="linux-headers-amd64"
        fi
      fi
      echo "git make dkms build-essential debhelper dh-dkms python3 zstd xz-utils curl ${hdr}"
      ;;
    fedora)
      echo "git make dkms gcc python3 zstd xz curl rpm-build kernel-devel"
      ;;
    suse)
      local kdev="kernel-default-devel"
      if ! pkg_installed "$kdev" && ! pkg_available repo "$kdev"; then
        kdev="kernel-devel"
      fi
      echo "git make dkms gcc python3 zstd xz curl rpm-build ${kdev}"
      ;;
  esac
}

applicable_gpu_unlock() {
  [[ "$HAS_NVIDIA" == true ]] || return 1
  secure_boot_enabled && return 1
  [[ "$HAS_NVIDIA_NON_TESLA" == true ]] || return 1
  local found_consumer=false n
  if (( ${#NVIDIA_GPU_NAMES[@]} > 0 )); then
    for n in "${NVIDIA_GPU_NAMES[@]}"; do
      _is_nvidia_consumer_unlock_name "$n" && { found_consumer=true; break; }
    done
  else
    while IFS= read -r n; do
      grep -qi "nvidia" <<<"$n" || continue
      _is_nvidia_consumer_unlock_name "$n" && { found_consumer=true; break; }
    done <<<"${GPU_RAW:-$GPU_SUMMARY}"
  fi
  [[ "$found_consumer" == true ]] || return 1
  if [[ "$DISTRO_FAMILY" == "arch" ]]; then
    pkg_installed gpu-unlock-dkms || pkg_available repo gpu-unlock-dkms || pkg_available aur gpu-unlock-dkms
  else
    [[ "$DISTRO_FAMILY" =~ ^(debian|fedora|suse)$ ]]
  fi
}

title_gpu_unlock() { echo "NVIDIA GPU Unlock Module & Kernel Param (gpu-unlock-dkms)"; }
note_gpu_unlock() {
  if [[ "$DISTRO_FAMILY" != "arch" ]]; then
    echo -e "${C_MAGENTA}[EXP]${C_RESET}"
  else
    echo -e "${C_DIM}-${C_RESET}"
  fi
}
status_gpu_unlock() {
  has_kernel_param "gpu_unlock.targets=all" && ([[ -d /sys/module/gpu_unlock ]] || lsmod 2>/dev/null | grep -qE "gpu_unlock" || gpu_unlock_installed)
}
explain_gpu_unlock() {
  if [[ "$DISTRO_FAMILY" == "arch" ]]; then
    cat <<'EOF'
Impact:
  Installs gpu-unlock-dkms + gpu-unlock-firmware and adds
  'gpu_unlock.targets=all' to the bootloader kernel command line.
EOF
  else
    cat <<'EOF'
Impact:
  Installs build dependencies, compiles and installs gpu-unlock from source
  (https://github.com/Zagitta/gpu-unlock) via DKMS, and adds
  'gpu_unlock.targets=all' to the bootloader kernel command line.
EOF
    echo -e "\n${C_MAGENTA}[EXPERIMENTAL] This option is experimental for your distribution (${OS_PRETTY:-$DISTRO_ID})${C_RESET}"
    echo -e "${C_MAGENTA}               and might not work properly.${C_RESET}"
  fi
  echo -e "\n${C_BGREEN}[HIGH IMPACT] Big performance gains can be achieved with gpu-unlock on${C_RESET}"
  echo -e "${C_BGREEN}              supported consumer Turing/Ampere/Ada GPUs (RTX 20/30/40 series),${C_RESET}"
  echo -e "${C_BGREEN}              unlocking hardware compute, clock, and power capabilities.${C_RESET}"
}
apply_gpu_unlock() {
  if ! gpu_unlock_installed; then
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
      prompt_install_repo_or_aur gpu-unlock-dkms gpu-unlock-firmware || return 0
    else
      local -a deps=()
      read -r -a deps <<< "$(gpu_unlock_build_deps)"
      if [[ ${#deps[@]} -gt 0 ]]; then
        prompt_install_deps repo "${deps[@]}" || return 0
      fi
      local build_dir build_ok=false
      build_dir="$(mktemp -d /tmp/gpu-unlock.XXXXXX)"
      [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]] && chown "$TARGET_USER" "$build_dir" 2>/dev/null || true
      echo -e "${C_CYAN}Cloning and building gpu-unlock from source...${C_RESET}"
      if ! run_as_user_exec git clone --depth 1 https://github.com/Zagitta/gpu-unlock.git "$build_dir/src"; then
        echo -e "${C_RED}Failed to clone https://github.com/Zagitta/gpu-unlock.git.${C_RESET}"
        rm -rf "$build_dir"
        return 0
      fi
      case "$DISTRO_FAMILY" in
        debian)
          if run_as_user_exec make -C "$build_dir/src" CACHE="$build_dir/cache" deb &&
             compgen -G "$build_dir/src/build/deb/gpu-unlock-*.deb" >/dev/null 2>&1 &&
             run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$build_dir"/src/build/deb/gpu-unlock-*.deb; then
            build_ok=true
          fi
          ;;
        fedora)
          if run_as_user_exec make -C "$build_dir/src" CACHE="$build_dir/cache" rpm &&
             compgen -G "$build_dir/src/build/rpm/RPMS/noarch/gpu-unlock-*.noarch.rpm" >/dev/null 2>&1 &&
             run_root dnf install -y "$build_dir"/src/build/rpm/RPMS/noarch/gpu-unlock-*.noarch.rpm; then
            build_ok=true
          fi
          ;;
        suse)
          if run_as_user_exec make -C "$build_dir/src" CACHE="$build_dir/cache" rpm &&
             compgen -G "$build_dir/src/build/rpm/RPMS/noarch/gpu-unlock-*.noarch.rpm" >/dev/null 2>&1 &&
             run_root zypper --non-interactive --no-gpg-checks install "$build_dir"/src/build/rpm/RPMS/noarch/gpu-unlock-*.noarch.rpm; then
            build_ok=true
          fi
          ;;
      esac
      rm -rf "$build_dir"
      PKG_INST_CACHE=()
      if [[ "$build_ok" != true ]]; then
        echo -e "${C_RED}Failed to build/install gpu-unlock from source.${C_RESET}"
        return 0
      fi
    fi
  fi
  add_kernel_param "gpu_unlock.targets=all"
}
revert_gpu_unlock() { remove_kernel_param "gpu_unlock.targets=all"; }

applicable_nvidia_sm70_table() {
  [[ "$HAS_NVIDIA" == true && "$HAS_NVIDIA_VOLTA_SM70" == true ]] || [[ -f "$NVIDIA_SM70_MARKER" ]]
}
title_nvidia_sm70_table() { echo "NVIDIA Volta (V100 / sm_70) Strata Decode Table (STRATA_SM70_TABLE=1)"; }
status_nvidia_sm70_table() { [[ -f "$NVIDIA_SM70_MARKER" ]]; }
explain_nvidia_sm70_table() {
  cat <<'EOF'
Impact:
  Enables Strata's opt-in Volta (sm_70 / Tesla V100) decode table via
  STRATA_SM70_TABLE=1 across wizard CLI calls, /etc/profile.d/strata-sm70.sh,
  and a strata.service systemd drop-in. Improves token decode speed on V100
  with zero idle power impact (remember to run Strata CUDA 12 builds on sm_70).
EOF
}
apply_nvidia_sm70_table() {
  echo "1" | run_root tee "$NVIDIA_SM70_MARKER" >/dev/null
  run_root tee /etc/profile.d/strata-sm70.sh >/dev/null <<'EOF'
export STRATA_SM70_TABLE=1
EOF
  run_root chmod 0644 /etc/profile.d/strata-sm70.sh 2>/dev/null || true
  if [[ "$HAS_SYSTEMD" == true && -f /etc/systemd/system/strata.service ]]; then
    run_root mkdir -p /etc/systemd/system/strata.service.d
    run_root tee /etc/systemd/system/strata.service.d/20-sm70-table.conf >/dev/null <<'EOF'
[Service]
Environment=STRATA_SM70_TABLE=1
EOF
    service_ctl daemon-reload
    unit_active strata.service && echo -e "${C_YELLOW}Restart strata.service for STRATA_SM70_TABLE=1 to take effect.${C_RESET}" || true
  fi
}
revert_nvidia_sm70_table() {
  run_root rm -f "$NVIDIA_SM70_MARKER" /etc/profile.d/strata-sm70.sh
  if [[ -f /etc/systemd/system/strata.service.d/20-sm70-table.conf ]]; then
    run_root rm -f /etc/systemd/system/strata.service.d/20-sm70-table.conf
    run_root rmdir /etc/systemd/system/strata.service.d 2>/dev/null || true
    service_ctl daemon-reload 2>/dev/null || true
  fi
}

# 11e. NVIDIA Tesla Idle P-State Daemon (nvidia-pstated / nvidia-pstate)
nvidia_pstate_target_indices() {
  local idxs=() i cc g_name
  for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
    [[ "${NVIDIA_GPU_IS_DATACENTER[$i]}" == true ]] || continue
    cc="${NVIDIA_GPU_COMPUTE_CAP[$i]}"
    g_name="${NVIDIA_GPU_NAMES[$i]}"
    if [[ "$cc" =~ ^(5\.|6\.|7\.0$) ]] || grep -qiE "\b(M40|M60|M10|P4|P40|P100|V100)\b|CMP [0-9]+HX|P10[246]-100" <<<"$g_name"; then
      idxs+=("${NVIDIA_GPU_INDICES[$i]}")
    fi
  done
  local IFS=,
  echo "${idxs[*]}"
}
_find_nvml_include_dir() {
  local d
  for d in /usr/include /usr/local/cuda/include /opt/cuda/include /usr/include/x86_64-linux-gnu; do
    [[ -f "${d}/nvml.h" ]] && { echo "$d"; return 0; }
  done
  return 1
}
applicable_nvidia_pstate() {
  [[ "$HAS_NVIDIA" == true && "$HAS_NVIDIA_LEGACY_PSTATE_CARD" == true ]] ||
    service_installed nvidia-pstated.service || service_installed strata-nvidia-pstate.service
}
title_nvidia_pstate() { echo "NVIDIA Tesla Idle P-State Daemon (P0 -> P8 idle power fix, nvidia-pstated)"; }
note_nvidia_pstate() { echo -e "${C_MAGENTA}[EXP]${C_RESET}"; }
status_nvidia_pstate() {
  { service_installed nvidia-pstated.service && unit_enabled nvidia-pstated.service && unit_active nvidia-pstated.service; } ||
    { service_installed strata-nvidia-pstate.service && unit_enabled strata-nvidia-pstate.service && unit_active strata-nvidia-pstate.service; }
}
explain_nvidia_pstate() {
  cat <<'EOF'
Impact:
  Installs and runs sasha0552/nvidia-pstated (or Python nvidia-pstate polling
  fallback if CUDA/NVML headers are absent) to drop legacy Tesla/CMP GPUs
  (P40, P100, P4, M40, M60, V100) from stuck P0 (~30-50W idle) into P8 (~9-10W)
  when no inference workload is running, cutting heat and fan noise.
EOF
  echo -e "\n${C_MAGENTA}[EXPERIMENTAL] Relies on undocumented NvAPI calls (requires libnvidia-api.so.1${C_RESET}"
  echo -e "${C_MAGENTA}               from nvidia-utils / libnvidia-api1) and third-party code.${C_RESET}"
}
apply_nvidia_pstate() {
  if ! ldconfig -p 2>/dev/null | grep -q "libnvidia-api\.so\.1" && ! compgen -G "/usr/lib*/libnvidia-api.so*" >/dev/null 2>&1 && ! compgen -G "/usr/lib/*/libnvidia-api.so*" >/dev/null 2>&1; then
    echo -e "${C_YELLOW}libnvidia-api.so.1 was not found on this host.${C_RESET}"
    echo -e "Install it first (Arch: nvidia-utils, Debian/Ubuntu: libnvidia-api1 or libnvidia-tesla-api1, Fedora: nvidia-driver-libs)."
    return 1
  fi
  local target_idxs="" idx_args=""
  target_idxs="$(nvidia_pstate_target_indices)"

  local daemon_bin=""
  command -v nvidia-pstated >/dev/null 2>&1 && daemon_bin="$(command -v nvidia-pstated)"
  [[ -z "$daemon_bin" && -x /usr/local/bin/nvidia-pstated ]] && daemon_bin="/usr/local/bin/nvidia-pstated"

  if [[ -z "$daemon_bin" ]] && _find_nvml_include_dir >/dev/null 2>&1; then
    local -a bdeps=()
    command -v git >/dev/null 2>&1 || bdeps+=(git)
    command -v cmake >/dev/null 2>&1 || bdeps+=(cmake)
    command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || bdeps+=(gcc)
    if (( ${#bdeps[@]} == 0 )) || prompt_install_deps repo "${bdeps[@]}"; then
      local bdir nvml_inc
      nvml_inc="$(_find_nvml_include_dir)"
      bdir="$(mktemp -d /tmp/nvidia-pstated.XXXXXX)"
      trap "rm -rf $(printf '%q' "$bdir")" RETURN
      [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]] && chown "$TARGET_USER" "$bdir" 2>/dev/null || true
      echo -e "${C_CYAN}Building sasha0552/nvidia-pstated from source...${C_RESET}"
      if run_as_user_exec git clone --depth 1 https://github.com/sasha0552/nvidia-pstated.git "$bdir/src" &&
         run_as_user_exec cmake -S "$bdir/src" -B "$bdir/build" "-DCMAKE_C_FLAGS=-I${nvml_inc}" &&
         run_as_user_exec cmake --build "$bdir/build" &&
         [[ -x "$bdir/build/nvidia-pstated" ]]; then
        run_root install -m 0755 "$bdir/build/nvidia-pstated" /usr/local/bin/nvidia-pstated
        daemon_bin="/usr/local/bin/nvidia-pstated"
      else
        echo -e "${C_YELLOW}C build of nvidia-pstated failed; falling back to Python nvidia-pstate daemon.${C_RESET}"
      fi
      rm -rf "$bdir"
    fi
  fi

  if [[ -n "$daemon_bin" ]]; then
    if [[ -n "$target_idxs" ]] && "$daemon_bin" --help 2>&1 | grep -q -- "-i"; then
      idx_args=" -i ${target_idxs}"
    fi
    service_installed strata-nvidia-pstate.service && remove_service strata-nvidia-pstate.service
    echo "daemon" | run_root tee "$NVIDIA_PSTATE_MARKER" >/dev/null
    if [[ "$HAS_SYSTEMD" == true ]]; then
      install_service nvidia-pstated.service <<EOF
[Unit]
Description=NVIDIA GPU Idle P-State Daemon (nvidia-pstated)
After=nvidia-persistenced.service strata-nvidia-persistenced.service
StartLimitIntervalSec=0

[Service]
DynamicUser=yes
ExecStart=${daemon_bin}${idx_args}
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
    else
      install_service nvidia-pstated.service <<EOF
[Unit]
Description=NVIDIA GPU Idle P-State Daemon (nvidia-pstated)

[Service]
ExecStart=/bin/sh -c 'nohup ${daemon_bin}${idx_args} >/dev/null 2>&1 &'
ExecStop=/bin/sh -c 'pkill -x nvidia-pstated >/dev/null 2>&1 || true'

[Install]
WantedBy=multi-user.target
EOF
    fi
    return $?
  fi

  # Fallback: Python nvidia-pstate polling daemon in isolated venv
  if ! command -v python3 >/dev/null 2>&1; then
    echo -e "${C_RED}python3 is required for the nvidia-pstate fallback.${C_RESET}"
    return 1
  fi
  echo -e "${C_CYAN}Setting up Python nvidia-pstate idle daemon in /opt/strata-nvidia-pstate...${C_RESET}"
  run_root mkdir -p /opt/strata-nvidia-pstate /usr/local/libexec
  if [[ ! -x /opt/strata-nvidia-pstate/venv/bin/python ]]; then
    if ! run_root python3 -m venv /opt/strata-nvidia-pstate/venv; then
      echo -e "${C_RED}Could not create Python venv (install python3-venv / python-virtualenv).${C_RESET}"
      return 1
    fi
  fi
  if ! run_root /opt/strata-nvidia-pstate/venv/bin/pip install --upgrade nvidia-pstate; then
    echo -e "${C_RED}Failed to install nvidia-pstate from PyPI.${C_RESET}"
    return 1
  fi
  run_root tee /usr/local/libexec/strata-nvidia-pstated.py >/dev/null <<'PY'
#!/usr/bin/env python3
import inspect, signal, subprocess, sys, time
from nvidia_pstate import set_pstate_high, set_pstate_low

IDLE_DELAY_S = 30.0
POLL_S = 2.0

def call_pstate(fn, idxs):
    try:
        sig = inspect.signature(fn)
        if not sig.parameters:
            fn()
            return
        pname = next(iter(sig.parameters))
        if idxs is None:
            fn()
        else:
            for idx in idxs:
                fn(**{pname: idx})
    except Exception:
        fn()

def is_busy(idxs):
    cmd = ["nvidia-smi", "--query-gpu=index,utilization.gpu", "--format=csv,noheader,nounits"]
    if idxs:
        cmd.extend(["-i", ",".join(str(i) for i in idxs)])
    try:
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
        for line in out.splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 2 and parts[1].isdigit() and int(parts[1]) > 3:
                return True
        apps_cmd = ["nvidia-smi", "--query-compute-apps=pid", "--format=csv,noheader"]
        if idxs:
            apps_cmd.extend(["-i", ",".join(str(i) for i in idxs)])
        apps = subprocess.check_output(apps_cmd, text=True, stderr=subprocess.DEVNULL).strip()
        if apps:
            return True
    except Exception:
        return True
    return False

def main():
    idxs = None
    if len(sys.argv) > 1 and sys.argv[1]:
        idxs = [int(x) for x in sys.argv[1].split(",") if x.strip().isdigit()]
    def handle_stop(_signum, _frame):
        try:
            call_pstate(set_pstate_high, idxs)
        except Exception:
            pass
        sys.exit(0)
    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)
    state = "high"
    last_active = time.monotonic()
    while True:
        now = time.monotonic()
        if is_busy(idxs):
            last_active = now
            if state != "high":
                call_pstate(set_pstate_high, idxs)
                state = "high"
        elif now - last_active >= IDLE_DELAY_S and state != "low":
            call_pstate(set_pstate_low, idxs)
            state = "low"
        time.sleep(POLL_S)

if __name__ == "__main__":
    main()
PY
  run_root chmod 0755 /usr/local/libexec/strata-nvidia-pstated.py
  echo "python" | run_root tee "$NVIDIA_PSTATE_MARKER" >/dev/null
  if [[ "$HAS_SYSTEMD" == true ]]; then
    install_service strata-nvidia-pstate.service <<EOF
[Unit]
Description=NVIDIA GPU Idle P-State Polling Service (Strata)
After=nvidia-persistenced.service strata-nvidia-persistenced.service

[Service]
Type=simple
ExecStart=/opt/strata-nvidia-pstate/venv/bin/python /usr/local/libexec/strata-nvidia-pstated.py ${target_idxs}
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
  else
    install_service strata-nvidia-pstate.service <<EOF
[Unit]
Description=NVIDIA GPU Idle P-State Polling Service (Strata)

[Service]
ExecStart=/bin/sh -c 'nohup /opt/strata-nvidia-pstate/venv/bin/python /usr/local/libexec/strata-nvidia-pstated.py ${target_idxs} >/dev/null 2>&1 &'
ExecStop=/bin/sh -c 'pkill -f strata-nvidia-pstated.py >/dev/null 2>&1 || true'

[Install]
WantedBy=multi-user.target
EOF
  fi
}
revert_nvidia_pstate() {
  service_installed nvidia-pstated.service && remove_service nvidia-pstated.service
  service_installed strata-nvidia-pstate.service && remove_service strata-nvidia-pstate.service
  if [[ -x /opt/strata-nvidia-pstate/venv/bin/python ]]; then
    local _tidxs=""
    _tidxs="$(nvidia_pstate_target_indices)"
    run_root /opt/strata-nvidia-pstate/venv/bin/python - "$_tidxs" <<'PY' >/dev/null 2>&1 || true
import inspect, sys
from nvidia_pstate import set_pstate_high
idxs = [int(x) for x in sys.argv[1].split(",") if x.strip().isdigit()] if len(sys.argv) > 1 and sys.argv[1] else None
sig = inspect.signature(set_pstate_high)
if not sig.parameters or idxs is None:
    set_pstate_high()
else:
    p = next(iter(sig.parameters))
    for i in idxs:
        set_pstate_high(**{p: i})
PY
  fi
  run_root rm -f /usr/local/libexec/strata-nvidia-pstated.py "$NVIDIA_PSTATE_MARKER"
}

applicable_nvidia_clock_lock() { [[ "$HAS_NVIDIA" == true && -n "$NVIDIA_MAX_GFX_CLK" ]]; }
title_nvidia_clock_lock() {
  if (( ${#NVIDIA_GPU_INDICES[@]} > 1 )); then
    echo "NVIDIA Lock GPU Clocks at Maximum (up to ${NVIDIA_MAX_GFX_CLK} MHz core)"
  else
    echo "NVIDIA Lock GPU Clocks at Maximum (${NVIDIA_MAX_GFX_CLK} MHz core)"
  fi
}
note_nvidia_clock_lock() { echo -e "${C_YELLOW}[!]${C_RESET}"; }
status_nvidia_clock_lock() { service_installed nvidia-clock-lock.service && unit_enabled nvidia-clock-lock.service; }
explain_nvidia_clock_lock() {
  cat <<EOF
Impact:
  Locks GPU core clocks at ${NVIDIA_MAX_GFX_CLK} MHz (and VRAM clocks at ${NVIDIA_MAX_MEM_CLK:-max} MHz when
  supported) via 'nvidia-smi -lgc/-lmc' (or '-ac' application clocks with
  Auto Boost disabled on older Kepler/Maxwell/Pascal Tesla GPUs) and a persistent
  service. Removes clock ramp-up delay for stable, lowest-latency token decode.
EOF
  echo -e "\n${C_YELLOW}[WARNING] Locked clocks keep the GPU at high power even when idle${C_RESET}"
  echo -e "${C_YELLOW}          and hardly provide gains for sustained, GPU-bound generation.${C_RESET}"
}
nvidia_best_ac_pair() {
  local idx="$1" max_mem="${2:-}" max_gfx="${3:-}" raw best=""
  raw="$(nvidia-smi -i "$idx" --query-supported-clocks=mem,gr --format=csv,noheader,nounits 2>/dev/null || true)"
  best="$(awk -F', *' '$1~/^[0-9]+$/ && $2~/^[0-9]+$/ {m=$1+0; g=$2+0; if (m > bm || (m == bm && g > bg)) {bm=m; bg=g}} END {if (bm > 0 && bg > 0) printf "%d,%d", bm, bg}' <<<"$raw")"
  if [[ -n "$best" ]]; then
    echo "$best"
  elif [[ -n "$max_mem" && -n "$max_gfx" ]]; then
    echo "${max_mem},${max_gfx}"
  fi
}
apply_nvidia_clock_lock() {
  local smi_bin out i idx max_gfx max_mem cc g_name ac_pair exec_start="" exec_stop="" applied=0 lgc_ok ac_ok
  smi_bin="$(command -v nvidia-smi)"
  for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
    idx="${NVIDIA_GPU_INDICES[$i]}"
    max_gfx="${NVIDIA_GPU_MAX_GFX_CLK[$i]}"
    max_mem="${NVIDIA_GPU_MAX_MEM_CLK[$i]}"
    cc="${NVIDIA_GPU_COMPUTE_CAP[$i]:-}"
    g_name="${NVIDIA_GPU_NAMES[$i]}"
    [[ -n "$max_gfx" ]] || continue
    lgc_ok=false
    if out="$(run_root "$smi_bin" -i "$idx" -lgc "${max_gfx},${max_gfx}" 2>&1)" && ! grep -qiE "not supported|not a valid|failed|error" <<<"$out"; then
      lgc_ok=true
      exec_start+="ExecStart=${smi_bin} -i ${idx} -lgc ${max_gfx},${max_gfx}"$'\n'
      exec_stop+="ExecStop=-${smi_bin} -i ${idx} -rgc"$'\n'
      if [[ -n "$max_mem" ]]; then
        run_root "$smi_bin" -i "$idx" -lmc "${max_mem},${max_mem}" >/dev/null 2>&1 || true
        exec_start+="ExecStart=-${smi_bin} -i ${idx} -lmc ${max_mem},${max_mem}"$'\n'
        exec_stop+="ExecStop=-${smi_bin} -i ${idx} -rmc"$'\n'
      fi
      applied=$((applied + 1))
    fi
    if [[ "$lgc_ok" == false ]]; then
      ac_pair="$(nvidia_best_ac_pair "$idx" "$max_mem" "$max_gfx")"
      if [[ "$cc" =~ ^(3\.|5\.) ]] || grep -qiE "\b(K80|K40|K20|K10|M40|M60|M10)\b" <<<"$g_name"; then
        run_root "$smi_bin" -i "$idx" --auto-boost-default=0 >/dev/null 2>&1 || true
        exec_start+="ExecStart=-${smi_bin} -i ${idx} --auto-boost-default=0"$'\n'
        exec_stop+="ExecStop=-${smi_bin} -i ${idx} --auto-boost-default=1"$'\n'
      fi
      ac_ok=false
      if [[ -n "$ac_pair" ]] && out="$(run_root "$smi_bin" -i "$idx" -ac "$ac_pair" 2>&1)" && ! grep -qiE "not supported|not a valid|failed|error" <<<"$out"; then
        ac_ok=true
        exec_start+="ExecStart=${smi_bin} -i ${idx} -ac ${ac_pair}"$'\n'
        exec_stop+="ExecStop=-${smi_bin} -i ${idx} -rac"$'\n'
        applied=$((applied + 1))
      else
        echo -e "${C_YELLOW}nvidia-smi clock lock (-lgc/-ac) is not supported on GPU ${idx} (${g_name}): ${out}${C_RESET}"
      fi
    fi
  done
  if (( applied == 0 )); then
    return 1
  fi
  install_service nvidia-clock-lock.service <<EOF
[Unit]
Description=Lock NVIDIA GPU Clocks at Maximum for Strata
After=nvidia-persistenced.service strata-nvidia-persistenced.service nvidia-powerd.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
${exec_start%$'\n'}
${exec_stop%$'\n'}

[Install]
WantedBy=multi-user.target
EOF
}
revert_nvidia_clock_lock() {
  remove_service nvidia-clock-lock.service
  local idx
  for idx in "${NVIDIA_GPU_INDICES[@]}"; do
    run_root nvidia-smi -i "$idx" -rgc >/dev/null 2>&1 || true
    run_root nvidia-smi -i "$idx" -rmc >/dev/null 2>&1 || true
    run_root nvidia-smi -i "$idx" -rac >/dev/null 2>&1 || true
    run_root nvidia-smi -i "$idx" --auto-boost-default=1 >/dev/null 2>&1 || true
  done
}

# 12i. NVIDIA ECC
applicable_nvidia_ecc() { [[ "$HAS_NVIDIA" == true && ${#NVIDIA_ECC_INDICES[@]} -gt 0 ]]; }
title_nvidia_ecc() { echo "NVIDIA ECC Memory Off (reclaim ~6-12% VRAM & bandwidth, reboot)"; }
status_nvidia_ecc() { [[ "$NVIDIA_ECC_PEND" == "Disabled" ]]; }
explain_nvidia_ecc() {
  cat <<'EOF'
Impact:
  Disables ECC on workstation/datacenter NVIDIA GPUs ('nvidia-smi -e 0'). ECC
  consumes roughly 6-12% of VRAM and some memory bandwidth; turning it off gives
  models more room and slightly higher decode speed. Requires a reboot.
  Trade-off: GPU memory errors are no longer corrected (fine for inference).
EOF
}
apply_nvidia_ecc() {
  local idx any_ok=false
  for idx in "${NVIDIA_ECC_INDICES[@]}"; do
    if run_root nvidia-smi -i "$idx" -e 0; then
      any_ok=true
    else
      echo -e "${C_YELLOW}Could not disable ECC mode on GPU ${idx}.${C_RESET}"
    fi
  done
  if [[ "$any_ok" == true ]]; then
    refresh_nvidia_ecc
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
  else
    return 1
  fi
}
revert_nvidia_ecc() {
  local idx any_ok=false
  for idx in "${NVIDIA_ECC_INDICES[@]}"; do
    run_root nvidia-smi -i "$idx" -e 1 && any_ok=true
  done
  if [[ "$any_ok" == true ]]; then
    refresh_nvidia_ecc
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
  fi
}

# 12i2. NVIDIA Compute Mode
applicable_nvidia_compute_mode() {
  [[ "$HAS_NVIDIA" == true ]] && ([[ "$NVIDIA_COMPUTE_MODE_NON_DEFAULT" == true ]] || [[ -f "$NVIDIA_COMPUTE_PREV_MARKER" ]])
}
title_nvidia_compute_mode() { echo "NVIDIA Compute Mode Default (Shared GPU Access)"; }
status_nvidia_compute_mode() { [[ "$NVIDIA_COMPUTE_MODE_NON_DEFAULT" == false ]]; }
explain_nvidia_compute_mode() {
  cat <<'EOF'
Impact:
  Sets NVIDIA GPU compute mode to Default ('nvidia-smi -c 0') on GPUs currently
  in Exclusive_Process, Exclusive_Thread, or Prohibited mode (common on Tesla
  datacenter/cloud hosts). Allows multiple processes/workers to share the GPU.
EOF
}
apply_nvidia_compute_mode() {
  local i idx cmode mnum prev_lines="" any_ok=false
  for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
    idx="${NVIDIA_GPU_INDICES[$i]}"
    cmode="${NVIDIA_GPU_COMPUTE_MODE[$i]}"
    [[ -n "$cmode" && "$cmode" != "Default" ]] || continue
    case "$cmode" in
      Exclusive_Thread)  mnum=1 ;;
      Prohibited)        mnum=2 ;;
      Exclusive_Process) mnum=3 ;;
      *)                 mnum="" ;;
    esac
    [[ -n "$mnum" ]] && prev_lines+="${idx}:${mnum}"$'\n'
    if run_root nvidia-smi -i "$idx" -c 0; then
      any_ok=true
    else
      echo -e "${C_YELLOW}Could not set compute mode on GPU ${idx} (${NVIDIA_GPU_NAMES[$i]}).${C_RESET}"
    fi
  done
  if [[ -n "$prev_lines" && "$any_ok" == true ]]; then
    printf "%s" "$prev_lines" | run_root tee "$NVIDIA_COMPUTE_PREV_MARKER" >/dev/null
  fi
  refresh_nvidia_compute_mode
  [[ "$any_ok" == true ]]
}
revert_nvidia_compute_mode() {
  if [[ -f "$NVIDIA_COMPUTE_PREV_MARKER" ]]; then
    local line idx mnum
    while IFS=: read -r idx mnum; do
      [[ "$idx" =~ ^[0-9]+$ && "$mnum" =~ ^[0-3]$ ]] || continue
      run_root nvidia-smi -i "$idx" -c "$mnum" >/dev/null 2>&1 || true
    done < "$NVIDIA_COMPUTE_PREV_MARKER"
    run_root rm -f "$NVIDIA_COMPUTE_PREV_MARKER"
    refresh_nvidia_compute_mode
  else
    echo -e "${C_YELLOW}Previous compute modes were not recorded by this script; leaving as Default.${C_RESET}"
  fi
}

# 12i3. NVIDIA Disable MIG Mode
applicable_nvidia_mig_disable() {
  [[ "$HAS_NVIDIA" == true ]] || { [[ -f "$NVIDIA_MIG_PREV_MARKER" ]]; return $?; }
  { (( ${#NVIDIA_MIG_INDICES[@]} > 0 )) && [[ "$NVIDIA_MIG_ANY_ENABLED" == true || "$NVIDIA_MIG_ANY_PEND_ENABLED" == true ]]; } || [[ -f "$NVIDIA_MIG_PREV_MARKER" ]]
}
title_nvidia_mig_disable() { echo "NVIDIA Disable MIG Mode (Full VRAM & Multi-GPU Tensor Parallelism)"; }
status_nvidia_mig_disable() {
  [[ "$NVIDIA_MIG_ANY_ENABLED" == false && "$NVIDIA_MIG_ANY_PEND_ENABLED" == false ]]
}
explain_nvidia_mig_disable() {
  cat <<'EOF'
Impact:
  Disables NVIDIA Multi-Instance GPU partitioning ('nvidia-smi -mig 0') on
  A100/A30/H100/H200/B200 GPUs that have MIG enabled (often left on by cloud or
  used-server images). Reclaims full unpartitioned VRAM and enables multi-GPU
  NVLink / tensor parallelism. May require GPU reset or reboot to apply.
EOF
}
apply_nvidia_mig_disable() {
  local i idx cur pend out prev_lines="" any_ok=false
  for (( i = 0; i < ${#NVIDIA_MIG_INDICES[@]}; i++ )); do
    idx="${NVIDIA_MIG_INDICES[$i]}"
    cur="${NVIDIA_GPU_MIG_CUR[$i]}"
    pend="${NVIDIA_GPU_MIG_PEND[$i]}"
    [[ "$cur" == "Enabled" || "$pend" == "Enabled" ]] || continue
    prev_lines+="${idx}"$'\n'
    if out="$(run_root nvidia-smi -i "$idx" -mig 0 2>&1)" && ! grep -qiE "not supported|failed|error|unable" <<<"$out"; then
      any_ok=true
      if [[ "$cur" == "Enabled" ]]; then
        if [[ -z "$(nvidia-smi -i "$idx" --query-compute-apps=pid --format=csv,noheader 2>/dev/null | tr -d '[:space:]')" ]]; then
          run_root nvidia-smi --gpu-reset -i "$idx" >/dev/null 2>&1 || true
        fi
      fi
    else
      echo -e "${C_YELLOW}Could not disable MIG mode on GPU ${idx}: ${out}${C_RESET}"
    fi
  done
  if [[ -n "$prev_lines" && "$any_ok" == true ]]; then
    printf "%s" "$prev_lines" | run_root tee "$NVIDIA_MIG_PREV_MARKER" >/dev/null
  fi
  refresh_nvidia_mig
  if [[ "$NVIDIA_MIG_ANY_ENABLED" == true ]]; then
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
  fi
  [[ "$any_ok" == true ]]
}
revert_nvidia_mig_disable() {
  if [[ -f "$NVIDIA_MIG_PREV_MARKER" ]]; then
    local idx any_ok=false
    while IFS= read -r idx; do
      [[ "$idx" =~ ^[0-9]+$ ]] || continue
      if run_root nvidia-smi -i "$idx" -mig 1; then
        any_ok=true
        if [[ -z "$(nvidia-smi -i "$idx" --query-compute-apps=pid --format=csv,noheader 2>/dev/null | tr -d '[:space:]')" ]]; then
          run_root nvidia-smi --gpu-reset -i "$idx" >/dev/null 2>&1 || true
        fi
      fi
    done < "$NVIDIA_MIG_PREV_MARKER"
    run_root rm -f "$NVIDIA_MIG_PREV_MARKER"
    refresh_nvidia_mig
    if [[ "$any_ok" == true && "$NVIDIA_MIG_ANY_ENABLED" == false ]]; then
      REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    fi
  else
    echo -e "${C_YELLOW}Previous MIG state was not recorded by this script; leaving MIG disabled.${C_RESET}"
  fi
}

# 11f. NVIDIA Multi-GPU P2P Open Kernel Module
NVIDIA_P2P_MARKER="/etc/strata-nvidia-p2p-open.enabled"

applicable_nvidia_p2p_open() {
  [[ -f "$NVIDIA_P2P_MARKER" ]] && return 0
  [[ "$HAS_NVIDIA" == true && "$HAS_NVIDIA_NON_TESLA" == true && "$HAS_NVIDIA_NVSWITCH" == false ]] || return 1
  secure_boot_enabled && return 1
  (( ${#NVIDIA_GPU_INDICES[@]} >= 2 || ${DISCRETE_GPU_COUNT:-0} >= 2 ))
}
title_nvidia_p2p_open() { echo "NVIDIA Multi-GPU P2P Open Kernel Module (tinygrad / aikitoria)"; }
note_nvidia_p2p_open() { echo -e "${C_MAGENTA}[EXP]${C_RESET}"; }
status_nvidia_p2p_open() {
  [[ -f "$NVIDIA_P2P_MARKER" ]] && return 0
  command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -qiE 'nvidia.*p2p'
}
explain_nvidia_p2p_open() {
  cat <<EOF
Impact:
  Installs the P2P-patched NVIDIA open kernel modules (tinygrad or aikitoria
  fork) so consumer RTX 3090 / 4090 / 5090 GPUs can perform direct PCIe P2P
  transfers instead of bouncing through host RAM (major speedup for tensor-
  parallel vLLM, SGLang, and ExLlama). Driver detected: ${NVIDIA_DRIVER_VER:-unknown}.
EOF
  echo -e "\n${C_MAGENTA}[EXPERIMENTAL] Replaces the kernel's nvidia modules from a third-party fork${C_RESET}"
  echo -e "${C_MAGENTA}               and requires Secure Boot disabled + kernel headers.${C_RESET}"
}
apply_nvidia_p2p_open() {
  if [[ "$DISTRO_FAMILY" == "arch" ]] && { pkg_available aur nvidia-open-p2p-dkms 2>/dev/null || pkg_available repo nvidia-open-p2p-dkms 2>/dev/null; }; then
    prompt_install_repo_or_aur nvidia-open-p2p-dkms || return 1
  else
    local repo_choice="" repo_url="https://github.com/tinygrad/open-gpu-kernel-modules.git"
    echo -e "\n${C_BOLD}Select P2P-patched NVIDIA open-gpu-kernel-modules fork:${C_RESET}"
    echo "  1) tinygrad/open-gpu-kernel-modules (recommended, broad driver branch tags)"
    echo "  2) aikitoria/open-gpu-kernel-modules"
    read -r -p "Choose [1-2, default 1]: " repo_choice
    [[ "$repo_choice" == "2" ]] && repo_url="https://github.com/aikitoria/open-gpu-kernel-modules.git"

    local -a deps=()
    read -r -a deps <<< "$(gpu_unlock_build_deps)"
    (( ${#deps[@]} > 0 )) && { prompt_install_deps repo "${deps[@]}" || return 1; }

    local build_dir branch_arg="" build_rc=0 drv_esc=""
    build_dir="$(mktemp -d /tmp/nvidia-p2p-open.XXXXXX)"
    [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]] && chown "$TARGET_USER" "$build_dir" 2>/dev/null || true
    echo -e "${C_CYAN}Checking ${repo_url} for driver tag ${NVIDIA_DRIVER_VER:-unknown}...${C_RESET}"
    drv_esc="${NVIDIA_DRIVER_VER//./\\.}"
    if [[ -n "${NVIDIA_DRIVER_VER:-}" ]] && git ls-remote --tags "$repo_url" 2>/dev/null | grep -qE "refs/tags/${drv_esc}(\^{})?$"; then
      branch_arg="--branch ${NVIDIA_DRIVER_VER}"
    else
      echo -e "${C_RED}No matching tag for installed NVIDIA driver '${NVIDIA_DRIVER_VER:-unknown}' in ${repo_url}; aborting to prevent NVRM API mismatch.${C_RESET}"
      rm -rf "$build_dir"
      return 1
    fi
    if ! run_as_user_exec git clone --depth 1 ${branch_arg} "$repo_url" "$build_dir/src"; then
      echo -e "${C_RED}Failed to clone ${repo_url}.${C_RESET}"
      rm -rf "$build_dir"
      return 1
    fi
    echo -e "${C_CYAN}Building NVIDIA open kernel modules (this may take a few minutes)...${C_RESET}"
    if ! run_as_user_exec make -C "$build_dir/src" modules -j"$(nproc 2>/dev/null || echo 4)"; then
      echo -e "${C_RED}Build failed. Ensure your installed NVIDIA userspace version (${NVIDIA_DRIVER_VER:-unknown}) matches a supported branch/tag.${C_RESET}"
      rm -rf "$build_dir"
      return 1
    fi
    run_root make -C "$build_dir/src" modules_install || build_rc=$?
    rm -rf "$build_dir"
    (( build_rc == 0 )) || return 1
    run_root depmod -a || true
  fi
  run_root mkdir -p /etc/modprobe.d
  echo "options nvidia NVreg_OpenRmEnableUnsupportedGpus=1" | run_root tee /etc/modprobe.d/strata-nvidia-p2p.conf >/dev/null
  echo "1" | run_root tee "$NVIDIA_P2P_MARKER" >/dev/null
  REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
  echo -e "${C_GREEN}Installed P2P-enabled NVIDIA open kernel module (reboot required).${C_RESET}"
}
revert_nvidia_p2p_open() {
  local restored=false
  run_root rm -f /etc/modprobe.d/strata-nvidia-p2p.conf
  if [[ "$DISTRO_FAMILY" == "arch" ]]; then
    local pkg
    for pkg in nvidia-open nvidia-open-dkms nvidia-dkms nvidia; do
      if pkg_available repo "$pkg" 2>/dev/null && pkg_installed "$pkg" 2>/dev/null; then
        pkg_install "$pkg" && restored=true
        break
      fi
    done
    if [[ "$restored" == false ]] && pkg_installed nvidia-open-p2p-dkms 2>/dev/null && pkg_available repo nvidia-open-dkms 2>/dev/null; then
      run_root pacman -Rdd --noconfirm nvidia-open-p2p-dkms 2>/dev/null || true
      pkg_install nvidia-open-dkms && restored=true
    fi
  elif command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -qiE '^nvidia'; then
    run_root dkms autoinstall && restored=true || true
  fi
  if [[ "$restored" == true ]]; then
    run_root depmod -a || true
    run_root rm -f "$NVIDIA_P2P_MARKER"
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Restored stock NVIDIA kernel modules (reboot required).${C_RESET}"
    return 0
  fi
  echo -e "${C_YELLOW}Could not automatically reinstall stock NVIDIA modules; reinstall your distro's nvidia-open / nvidia-dkms package and remove ${NVIDIA_P2P_MARKER}, then reboot.${C_RESET}"
  return 1
}
