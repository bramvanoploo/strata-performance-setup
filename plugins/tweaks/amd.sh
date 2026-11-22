#!/usr/bin/env bash
# PLUGIN_ID: amd
# PLUGIN_NAME: amd
# PLUGIN_DESC: AMD GPU/APU, Instinct, Ryzen TDP, and X3D tweaks

register_tweak --id "amd_gpu_perf" --stars 4 --tier "recommended" --os "linux" --laptop-recommended false --vm-supported true --experimental-non-arch false
register_tweak --id "amd_apu_memory" --stars 5 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "amd_cwsr_disable" --stars 4 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "ryzenadj_tdp" --stars 4 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported false --experimental-non-arch false
register_tweak --id "amd_instinct_partition" --stars 3 --tier "opt_in" --os "linux" --laptop-recommended true --vm-supported false --experimental-non-arch false
register_tweak --id "amd_x3d_mode" --stars 4 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported false --experimental-non-arch false

applicable_amd_gpu_perf() {
  [[ "$HAS_AMD" == true ]] || return 1
  local drm_dir="${STRATA_DRM_DIR:-/sys/class/drm}"
  compgen -G "${drm_dir}/card*/device/power_dpm_force_performance_level" >/dev/null 2>&1 && return 0
  [[ "$HAS_AMD_INSTINCT" == true ]] && { command -v amd-smi >/dev/null 2>&1 || command -v rocm-smi >/dev/null 2>&1; }
}
title_amd_gpu_perf() { echo "AMD Radeon / Instinct High Performance DPM Level (amdgpu)"; }
status_amd_gpu_perf() {
  local drm_dir="${STRATA_DRM_DIR:-/sys/class/drm}" f
  for f in "${drm_dir}"/card*/device/power_dpm_force_performance_level; do
    [[ -f "$f" ]] && grep -q "high" "$f" 2>/dev/null && return 0
  done
  service_installed strata-amd-gpu-perf.service && unit_enabled strata-amd-gpu-perf.service && return 0
  return 1
}
explain_amd_gpu_perf() { echo -e "Impact:\n  Sets amdgpu power_dpm_force_performance_level='high' (with amd-smi / rocm-smi\n  fallback on Instinct GPUs) via persistent service for ROCm/HIP."; }
apply_amd_gpu_perf() {
  install_service strata-amd-gpu-perf.service <<'EOF'
[Unit]
Description=Set AMD GPU DPM Performance Level to High for Strata
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'w=0; for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do [ -w "$f" ] && echo high > "$f" 2>/dev/null && w=1; done; if [ "$w" -eq 0 ]; then if command -v amd-smi >/dev/null 2>&1; then amd-smi set --perf-level high >/dev/null 2>&1 || true; elif command -v rocm-smi >/dev/null 2>&1; then rocm-smi --setperflevel high >/dev/null 2>&1 || true; fi; fi; true'
ExecStop=/bin/sh -c 'w=0; for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do [ -w "$f" ] && echo auto > "$f" 2>/dev/null && w=1; done; if [ "$w" -eq 0 ]; then if command -v amd-smi >/dev/null 2>&1; then amd-smi set --perf-level auto >/dev/null 2>&1 || true; elif command -v rocm-smi >/dev/null 2>&1; then rocm-smi --setperflevel auto >/dev/null 2>&1 || true; fi; fi; true'

[Install]
WantedBy=multi-user.target
EOF
}
revert_amd_gpu_perf() {
  remove_service strata-amd-gpu-perf.service
  run_root sh -c 'w=0; for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do [ -w "$f" ] && echo auto > "$f" 2>/dev/null && w=1; done; if [ "$w" -eq 0 ]; then if command -v amd-smi >/dev/null 2>&1; then amd-smi set --perf-level auto >/dev/null 2>&1 || true; elif command -v rocm-smi >/dev/null 2>&1; then rocm-smi --setperflevel auto >/dev/null 2>&1 || true; fi; fi; true' 2>/dev/null || true
}

# 11d. NVIDIA Volta (V100 / sm_70) Strata Decode Table

applicable_amd_apu_memory() {
  [[ "$HAS_AMD" == true && "$HAS_AMD_APU" == true ]] || return 1
  local drm_dir="${STRATA_DRM_DIR:-/sys/class/drm}"
  compgen -G "${drm_dir}/card*/device/mem_info_gtt_total" >/dev/null 2>&1
}
title_amd_apu_memory() { echo "AMD APU Unified Memory GPU Limit (ttm.pages_limit ~ $(( $(amd_apu_gtt_pages) * 4 / 1048576 )) GiB)"; }
status_amd_apu_memory() { [[ -n "$(kernel_param_value ttm.pages_limit || true)" ]]; }
explain_amd_apu_memory() {
  cat <<EOF
Impact:
  Raises the amount of system RAM unified-memory AMD APUs (Strix Point gfx1150,
  Strix Halo gfx1151, Krackan gfx1152, Phoenix/Hawk Point gfx1103, etc.) can
  address via GTT from the default of about half of RAM to ~$(( $(amd_apu_gtt_pages) * 4 / 1048576 )) GiB
  (all RAM minus a 4 GiB / 12.5% reserve) by adding 'ttm.pages_limit' and
  'ttm.page_pool_size' to the bootloader kernel command line.
  Lets large models fully offload to the integrated GPU. Requires a reboot.
EOF
}
apply_amd_apu_memory() {
  local pages
  pages="$(amd_apu_gtt_pages)"
  add_kernel_param "ttm.pages_limit=${pages}" "ttm.page_pool_size=${pages}"
}
revert_amd_apu_memory() {
  local n v
  local -a rem=()
  for n in ttm.pages_limit ttm.page_pool_size; do
    v="$(kernel_param_value "$n" || true)"
    [[ -n "$v" ]] && rem+=("${n}=${v}")
  done
  (( ${#rem[@]} > 0 )) && remove_kernel_param "${rem[@]}"
}

# 12j2. AMD Radeon 780M/760M MES Reset Workaround (gfx1103)
applicable_amd_cwsr_disable() {
  amd_has_gfx "gfx1103" || has_kernel_param "amdgpu.cwsr_enable=0"
}
title_amd_cwsr_disable() { echo "AMD Radeon 780M/760M MES Reset Workaround (amdgpu.cwsr_enable=0)"; }
status_amd_cwsr_disable() { has_kernel_param "amdgpu.cwsr_enable=0"; }
explain_amd_cwsr_disable() {
  cat <<'EOF'
Impact:
  Disables Compute Wave Save/Restore (CWSR) preemption by adding
  'amdgpu.cwsr_enable=0' to the bootloader kernel command line. Stops MES
  REMOVE_QUEUE GPU resets seen on Linux with Radeon 780M / 760M (gfx1103,
  Strata #6132) without increasing idle power draw. Requires a reboot.
EOF
}
apply_amd_cwsr_disable() { add_kernel_param "amdgpu.cwsr_enable=0"; }
revert_amd_cwsr_disable() { remove_kernel_param "amdgpu.cwsr_enable=0"; }

# 12k. NVMe Tuning

applicable_ryzenadj_tdp() {
  service_installed strata-ryzenadj.service && return 0
  is_amd_mobile_apu_cpu || return 1
  command -v ryzenadj >/dev/null 2>&1 || pkg_available repo ryzenadj || pkg_available aur ryzenadj
}
title_ryzenadj_tdp() { echo "Ryzen APU Sustained Power Limits (STAPM/PPT via ryzenadj)"; }
status_ryzenadj_tdp() { service_installed strata-ryzenadj.service && unit_enabled strata-ryzenadj.service; }
explain_ryzenadj_tdp() {
  cat <<'EOF'
Impact:
  Raises the Ryzen mobile/APU sustained (STAPM), slow and fast PPT power limits via
  ryzenadj and re-applies them at boot and after resume. Many laptops and mini PCs
  ship with limits far below what the cooling can handle, which throttles
  sustained CPU/iGPU inference. You choose the target wattage (default: +25%).
  Higher limits raise power draw and heat; the previous limits are saved and
  restored on revert. Needs ryzen_smu or iomem=relaxed support from the kernel.
EOF
}
apply_ryzenadj_tdp() {
  command -v ryzenadj >/dev/null 2>&1 || prompt_install_repo_or_aur ryzenadj || return 0
  local bin info stapm slow fast target in_w fast_t
  bin="$(command -v ryzenadj)" || return 1
  if ! info="$(run_root "$bin" -i 2>&1)"; then
    echo -e "${C_YELLOW}ryzenadj cannot read this CPU (load the ryzen_smu module or boot with iomem=relaxed): ${info}${C_RESET}"
    return 1
  fi
  stapm="$(awk -F'|' '/STAPM LIMIT/ {gsub(/ /,"",$3); print $3; exit}' <<<"$info")"
  slow="$(awk -F'|' '/PPT LIMIT SLOW/ {gsub(/ /,"",$3); print $3; exit}' <<<"$info")"
  fast="$(awk -F'|' '/PPT LIMIT FAST/ {gsub(/ /,"",$3); print $3; exit}' <<<"$info")"
  if ! [[ "$slow" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo -e "${C_YELLOW}Could not read current power limits from ryzenadj.${C_RESET}"
    return 1
  fi
  if [[ ! -f "$RYZENADJ_MARKER" ]]; then
    [[ "$stapm" =~ ^[0-9]+(\.[0-9]+)?$ ]] || stapm=0
    [[ "$fast" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fast=0
    awk -v a="$stapm" -v b="$fast" -v c="$slow" 'BEGIN {printf "%d %d %d\n", a*1000, b*1000, c*1000}' | run_root tee "$RYZENADJ_MARKER" >/dev/null
  fi
  target="$(awk -v s="$slow" 'BEGIN {printf "%d", s*1.25 + 0.5}')"
  read -r -p "Sustained power limit in watts [default: ${target}]: " in_w
  [[ -n "$in_w" ]] && target="$in_w"
  if ! [[ "$target" =~ ^[0-9]+$ ]] || (( target < 5 || target > 200 )); then
    echo -e "${C_RED}Power limit must be an integer between 5 and 200 W.${C_RESET}"
    return 1
  fi
  fast_t="$(awk -v t="$target" 'BEGIN {printf "%d", t*1.15 + 0.5}')"
  local prev_stapm=0 prev_fast=0 prev_slow=0 stop_args=""
  [[ -r "$RYZENADJ_MARKER" ]] && read -r prev_stapm prev_fast prev_slow < "$RYZENADJ_MARKER"
  (( ${prev_stapm:-0} > 0 )) && stop_args+=" --stapm-limit=${prev_stapm}"
  (( ${prev_slow:-0} > 0 )) && stop_args+=" --slow-limit=${prev_slow}"
  (( ${prev_fast:-0} > 0 )) && stop_args+=" --fast-limit=${prev_fast}"
  install_service strata-ryzenadj.service <<EOF
[Unit]
Description=Raise Ryzen APU Power Limits for Strata
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${bin} --stapm-limit=$((target * 1000)) --slow-limit=$((target * 1000)) --fast-limit=$((fast_t * 1000))
${stop_args:+ExecStop=-${bin}${stop_args}}

[Install]
WantedBy=multi-user.target
EOF
}
revert_ryzenadj_tdp() {
  remove_service strata-ryzenadj.service
  run_root rm -f "$RYZENADJ_MARKER"
}

applicable_amd_instinct_partition() {
  amd_instinct_partition_supported || [[ -f "$AMD_INSTINCT_PART_MARKER" ]]
}
title_amd_instinct_partition() { echo "AMD Instinct Compute/Memory Partition Mode (SPX/CPX, NPS1/NPS4)"; }
note_amd_instinct_partition() { echo -e "${C_BLUE}[OPT]${C_RESET}"; }
status_amd_instinct_partition() { [[ -f "$AMD_INSTINCT_PART_MARKER" ]]; }
explain_amd_instinct_partition() {
  cat <<'EOF'
Impact:
  Switches AMD Instinct MI250X/MI300X/MI325X compute and memory partitioning:
    - SPX + NPS1: Single unified GPU per package (best for massive single LLMs)
    - CPX + NPS4: Splits XCDs & memory domains (best for concurrent small models)
  Saves your original modes and restores them on revert. May require a reboot.
EOF
}
apply_amd_instinct_partition() {
  local drm_dir="${STRATA_DRM_DIR:-/sys/class/drm}" cur_cp="" cur_mp="" f
  for f in "${drm_dir}"/card*/device/current_compute_partition; do
    [[ -r "$f" ]] && { cur_cp="$(cat "$f" 2>/dev/null | tr -d '[:space:]')"; break; }
  done
  for f in "${drm_dir}"/card*/device/current_memory_partition; do
    [[ -r "$f" ]] && { cur_mp="$(cat "$f" 2>/dev/null | tr -d '[:space:]')"; break; }
  done
  if [[ -z "$cur_cp" ]] && command -v amd-smi >/dev/null 2>&1; then
    local part_out
    part_out="$(amd-smi partition --current 2>/dev/null || true)"
    cur_cp="$(awk -F: '/COMPUTE_PARTITION/ {gsub(/ /,"",$2); print $2; exit}' <<<"$part_out")"
    cur_mp="$(awk -F: '/MEMORY_PARTITION/ {gsub(/ /,"",$2); print $2; exit}' <<<"$part_out")"
  fi
  echo -e "\n${C_BOLD}Select AMD Instinct Partition Preset (current: compute=${cur_cp:-unknown}, memory=${cur_mp:-unknown}):${C_RESET}"
  echo "  1) SPX + NPS1 (Unified GPU — recommended for large single LLMs)"
  echo "  2) CPX + NPS4 (Split XCDs — concurrent smaller models)"
  local pchoice="" tgt_cp="SPX" tgt_mp="NPS1"
  read -r -p "Choose [1-2, default 1]: " pchoice
  case "$pchoice" in
    2) tgt_cp="CPX"; tgt_mp="NPS4" ;;
    1|"") ;;
    *) echo -e "${C_RED}Invalid choice '${pchoice}'. Cancelled.${C_RESET}"; return 1 ;;
  esac
  if [[ ! -f "$AMD_INSTINCT_PART_MARKER" ]]; then
    echo "${cur_cp:-SPX}:${cur_mp:-NPS1}" | run_root tee "$AMD_INSTINCT_PART_MARKER" >/dev/null
  fi
  local ok=false
  if command -v amd-smi >/dev/null 2>&1; then
    run_root amd-smi set --compute-partition "$tgt_cp" >/dev/null 2>&1 && ok=true
    run_root amd-smi set --memory-partition "$tgt_mp" >/dev/null 2>&1 && ok=true
  fi
  if [[ "$ok" == false ]]; then
    for f in "${drm_dir}"/card*/device/current_compute_partition; do
      [[ -f "$f" ]] && echo "$tgt_cp" | run_root tee "$f" >/dev/null 2>&1 && ok=true
    done
    for f in "${drm_dir}"/card*/device/current_memory_partition; do
      [[ -f "$f" ]] && echo "$tgt_mp" | run_root tee "$f" >/dev/null 2>&1 && ok=true
    done
  fi
  if [[ "$ok" == false ]]; then
    run_root rm -f "$AMD_INSTINCT_PART_MARKER"
    echo -e "${C_YELLOW}Could not change Instinct partition mode (may require idle GPU or root amd-smi).${C_RESET}"
    return 1
  fi
  if [[ -n "$cur_mp" && "$cur_mp" != "$tgt_mp" ]]; then
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
  fi
}
revert_amd_instinct_partition() {
  if [[ -f "$AMD_INSTINCT_PART_MARKER" ]]; then
    local drm_dir="${STRATA_DRM_DIR:-/sys/class/drm}" orig_cp orig_mp f
    IFS=: read -r orig_cp orig_mp < "$AMD_INSTINCT_PART_MARKER"
    if command -v amd-smi >/dev/null 2>&1; then
      [[ -n "$orig_cp" ]] && run_root amd-smi set --compute-partition "$orig_cp" >/dev/null 2>&1 || true
      [[ -n "$orig_mp" ]] && run_root amd-smi set --memory-partition "$orig_mp" >/dev/null 2>&1 || true
    fi
    for f in "${drm_dir}"/card*/device/current_compute_partition; do
      [[ -n "$orig_cp" && -f "$f" ]] && echo "$orig_cp" | run_root tee "$f" >/dev/null 2>&1 || true
    done
    for f in "${drm_dir}"/card*/device/current_memory_partition; do
      [[ -n "$orig_mp" && -f "$f" ]] && echo "$orig_mp" | run_root tee "$f" >/dev/null 2>&1 || true
    done
    run_root rm -f "$AMD_INSTINCT_PART_MARKER"
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
  fi
}

applicable_amd_x3d_mode() {
  service_installed strata-amd-x3d.service && return 0
  compgen -G "/sys/bus/platform/drivers/amd_x3d_vcache/*/amd_x3d_mode" >/dev/null 2>&1
}
title_amd_x3d_mode() { echo "AMD Ryzen X3D V-Cache CCD Mode (amd_x3d_vcache -> cache)"; }
status_amd_x3d_mode() {
  local f
  for f in /sys/bus/platform/drivers/amd_x3d_vcache/*/amd_x3d_mode; do
    [[ -r "$f" ]] && [[ "$(cat "$f" 2>/dev/null)" == "cache" ]] && return 0
  done
  return 1
}
explain_amd_x3d_mode() {
  echo -e "Impact:\n  Sets amd_x3d_mode='cache' via systemd so dual-CCD Ryzen X3D processors\n  prefer the 3D V-Cache CCD for inference threads instead of migrating across CCDs."
}
apply_amd_x3d_mode() {
  install_service strata-amd-x3d.service <<'EOF'
[Unit]
Description=Set AMD X3D V-Cache Mode to Cache for Strata
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for f in /sys/bus/platform/drivers/amd_x3d_vcache/*/amd_x3d_mode; do [ -w "$f" ] && echo cache > "$f"; done; true'
ExecStop=/bin/sh -c 'for f in /sys/bus/platform/drivers/amd_x3d_vcache/*/amd_x3d_mode; do [ -w "$f" ] && echo frequency > "$f"; done; true'

[Install]
WantedBy=multi-user.target
EOF
}
revert_amd_x3d_mode() {
  remove_service strata-amd-x3d.service
  run_root sh -c 'for f in /sys/bus/platform/drivers/amd_x3d_vcache/*/amd_x3d_mode; do [ -w "$f" ] && echo frequency > "$f"; done; true' 2>/dev/null || true
}

# 12x. Intel Hybrid P-Core Pinning
