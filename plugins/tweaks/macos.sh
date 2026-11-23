#!/usr/bin/env bash
# PLUGIN_ID: macos
# PLUGIN_NAME: macos
# PLUGIN_DESC: macOS Apple Silicon wired memory, power mode, Spotlight, and Metal tweaks

register_tweak --id "macos_wired_limit" --stars 5 --tier "opt_in" --os "macos" --laptop-recommended false --vm-supported false --experimental-non-arch false
register_tweak --id "macos_power_mode" --stars 4 --tier "recommended" --os "macos" --laptop-recommended false --vm-supported false --experimental-non-arch false
register_tweak --id "macos_spotlight_exclude" --stars 4 --tier "recommended" --os "macos" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "macos_timemachine_exclude" --stars 2 --tier "recommended" --os "macos" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "macos_metal_tuning" --stars 4 --tier "opt_in" --os "macos" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "macos_rdma_tb5" --stars 4 --tier "opt_in" --os "macos" --laptop-recommended false --vm-supported false --experimental-non-arch false

applicable_macos_wired_limit() {
  [[ "$IS_MACOS" == true && "$IS_APPLE_SILICON" == true ]] && (( RAM_GB >= 24 ))
}
title_macos_wired_limit() { echo "macOS Metal GPU Wired Memory Limit (iogpu.wired_limit_mb)"; }
note_macos_wired_limit() { echo -e "${C_BLUE}[OPT]${C_RESET}"; }
macos_wired_limit_managed() { service_installed strata-macos-wired-limit.service; }
status_macos_wired_limit() {
  service_installed strata-macos-wired-limit.service && return 0
  (( $(_macos_wired_limit_cur_mb) > 0 ))
}
explain_macos_wired_limit() {
  local rec_gb cur_mb
  rec_gb="$(_macos_wired_limit_rec_gb "$RAM_GB")"
  cur_mb="$(_macos_wired_limit_cur_mb)"
  cat <<EOF
Impact:
  Overrides macOS's ~75% Metal GPU memory residency cap by setting
  'sysctl iogpu.wired_limit_mb' and persisting it via LaunchDaemon.
  Allows larger resident packs (e.g. UD-Q4_K_XL, IQ3_S, Gyro) on 32-192+ GiB
  Apple Silicon Macs without spilling experts to SSD streaming.
  Recommended safe ceiling for ${RAM_GB} GiB RAM: ~${rec_gb} GiB ($(( rec_gb * 1024 )) MiB).
  Current wired limit: $( (( cur_mb > 0 )) && echo "${cur_mb} MiB ($(( cur_mb / 1024 )) GiB)" || echo "0 (macOS default ~75%)" )
EOF
  echo -e "\n${C_YELLOW}[NOTE] Always leave enough RAM for macOS (5-16+ GiB); setting this too${C_RESET}"
  echo -e "${C_YELLOW}       close to physical RAM can trigger kernel memory-watchdog panics.${C_RESET}"
}
apply_macos_wired_limit() {
  local rec_gb rec_mb max_safe_mb cur_mb target_mb=""
  rec_gb="$(_macos_wired_limit_rec_gb "$RAM_GB")"
  rec_mb=$(( rec_gb * 1024 ))
  max_safe_mb=$(( (RAM_GB - 4) * 1024 ))
  (( rec_mb > max_safe_mb )) && rec_mb="$max_safe_mb"
  cur_mb="$(_macos_wired_limit_cur_mb)"
  echo "Detected unified memory: ${RAM_GB} GiB (current iogpu.wired_limit_mb=${cur_mb})"
  echo "Recommended safe limit: ${rec_mb} MiB ($(( rec_mb / 1024 )) GiB; hard max ${max_safe_mb} MiB)"
  read -r -p "Target Metal wired memory limit in MiB [${rec_mb}]: " target_mb || true
  target_mb="${target_mb:-$rec_mb}"
  if ! [[ "$target_mb" =~ ^[0-9]+$ ]] || (( target_mb < 4096 || target_mb > max_safe_mb )); then
    echo -e "${C_RED}Invalid value '${target_mb}' (must be between 4096 and ${max_safe_mb} MiB). Cancelled.${C_RESET}"
    return 1
  fi
  if ! run_root sysctl -w "iogpu.wired_limit_mb=${target_mb}"; then
    echo -e "${C_RED}Failed to set iogpu.wired_limit_mb=${target_mb}.${C_RESET}"
    return 1
  fi
  MACOS_WIRED_LIMIT_MB="$target_mb"
  install_service strata-macos-wired-limit.service <<EOF
[Unit]
Description=Set macOS Metal Wired Memory Limit for Strata

[Service]
ExecStart=/usr/sbin/sysctl -w iogpu.wired_limit_mb=${target_mb}
ExecStop=/usr/sbin/sysctl -w iogpu.wired_limit_mb=0
EOF
  echo -e "${C_GREEN}Set iogpu.wired_limit_mb=${target_mb} MiB ($(( target_mb / 1024 )) GiB).${C_RESET}"
}
revert_macos_wired_limit() {
  remove_service strata-macos-wired-limit.service
  run_root sysctl -w iogpu.wired_limit_mb=0 2>/dev/null || true
  MACOS_WIRED_LIMIT_MB=0
  echo -e "${C_GREEN}Restored iogpu.wired_limit_mb=0 (macOS default ~75%).${C_RESET}"
}

# 12z. macOS Power Mode (High Power Mode / Disable Low Power Mode)
applicable_macos_power_mode() {
  [[ "$IS_MACOS" == true && "$IS_APPLE_SILICON" == true ]] && command -v pmset >/dev/null 2>&1
}
title_macos_power_mode() {
  if [[ "$MACOS_POWER_MODE_SUPPORTED" == true ]]; then
    echo "macOS High Power Mode & Disable Low Power Mode (pmset)"
  else
    echo "macOS Disable Low Power Mode (pmset)"
  fi
}
status_macos_power_mode() {
  [[ -f "$MACOS_POWER_MODE_MARKER" ]] || return 1
  local applied_mode="" cur_pm="" cur_lp=""
  applied_mode="$(sed -n 's/^applied_mode=//p' "$MACOS_POWER_MODE_MARKER" 2>/dev/null | head -n1)"
  cur_pm="$(_pmset_ac_val powermode || true)"
  cur_lp="$(_pmset_ac_val lowpowermode || true)"
  if [[ "$applied_mode" == "high" ]]; then
    [[ "$cur_pm" == "2" ]]
  else
    [[ ( -z "$cur_pm" || "$cur_pm" == "0" ) && ( -z "$cur_lp" || "$cur_lp" == "0" ) ]]
  fi
}
explain_macos_power_mode() {
  cat <<'EOF'
Impact:
  Enables macOS High Power Mode (pmset powermode 2, where supported by Max/Ultra
  Apple Silicon chips) and ensures Low Power Mode is disabled so fans ramp more
  proactively and sustained prefill/decode avoids early thermal throttling.
  On MacBooks, scoped to AC power (-c) so battery behavior stays untouched.
EOF
}
apply_macos_power_mode() {
  local scope="-a" prev_pm="" prev_lp="" applied_mode="auto"
  [[ "$IS_LAPTOP" == true ]] && scope="-c"
  if [[ -r "$MACOS_POWER_MODE_MARKER" ]]; then
    prev_pm="$(sed -n 's/^prev_powermode=//p' "$MACOS_POWER_MODE_MARKER" 2>/dev/null | head -n1)"
    prev_lp="$(sed -n 's/^prev_lowpowermode=//p' "$MACOS_POWER_MODE_MARKER" 2>/dev/null | head -n1)"
  fi
  [[ -n "$prev_pm" ]] || prev_pm="$(_pmset_ac_val powermode || true)"
  [[ -n "$prev_lp" ]] || prev_lp="$(_pmset_ac_val lowpowermode || true)"
  run_root mkdir -p "$MACOS_SUPPORT_DIR"
  if run_root pmset "$scope" powermode 2 2>/dev/null && [[ "$(_pmset_ac_val powermode || true)" == "2" ]]; then
    applied_mode="high"
  else
    [[ -n "$prev_pm" ]] && run_root pmset "$scope" powermode 0 2>/dev/null || true
    run_root pmset "$scope" lowpowermode 0 2>/dev/null || true
    applied_mode="auto"
  fi
  run_root tee "$MACOS_POWER_MODE_MARKER" >/dev/null <<EOF
scope=${scope}
applied_mode=${applied_mode}
prev_powermode=${prev_pm}
prev_lowpowermode=${prev_lp}
EOF
  if [[ "$applied_mode" == "high" ]]; then
    echo -e "${C_GREEN}Enabled macOS High Power Mode (${scope}).${C_RESET}"
  else
    echo -e "${C_GREEN}Set macOS Power Mode to Automatic / Low Power Mode off (${scope}).${C_RESET}"
  fi
}
revert_macos_power_mode() {
  local scope="-a" prev_pm="" prev_lp=""
  [[ "$IS_LAPTOP" == true ]] && scope="-c"
  if [[ -r "$MACOS_POWER_MODE_MARKER" ]]; then
    scope="$(sed -n 's/^scope=//p' "$MACOS_POWER_MODE_MARKER" 2>/dev/null | head -n1)"
    prev_pm="$(sed -n 's/^prev_powermode=//p' "$MACOS_POWER_MODE_MARKER" 2>/dev/null | head -n1)"
    prev_lp="$(sed -n 's/^prev_lowpowermode=//p' "$MACOS_POWER_MODE_MARKER" 2>/dev/null | head -n1)"
    [[ -n "$scope" ]] || scope="-a"
  fi
  [[ -n "$prev_pm" ]] && run_root pmset "$scope" powermode "$prev_pm" 2>/dev/null || true
  [[ -n "$prev_lp" ]] && run_root pmset "$scope" lowpowermode "$prev_lp" 2>/dev/null || true
  run_root rm -f "$MACOS_POWER_MODE_MARKER"
  echo -e "${C_GREEN}Restored previous macOS power mode settings.${C_RESET}"
}

# 12aa. macOS Spotlight Exclusion for Strata Models & Data
_macos_spotlight_dirs() {
  local -a dirs=("$TARGET_HOME/.local/share/strata" "$TARGET_HOME/.cache/strata")
  [[ -d "$TARGET_HOME/.strata" ]] && dirs+=("$TARGET_HOME/.strata")
  [[ -d "$TARGET_HOME/Documents/Strata" ]] && dirs+=("$TARGET_HOME/Documents/Strata")
  [[ -n "${STRATA_DATA_DIR:-}" ]] && dirs+=("$STRATA_DATA_DIR")
  printf '%s\n' "${dirs[@]}" | awk '!seen[$0]++'
}
applicable_macos_spotlight_exclude() { [[ "$IS_MACOS" == true ]]; }
title_macos_spotlight_exclude() { echo "Exclude Strata Data & Models from Spotlight Indexing (SSD I/O)"; }
status_macos_spotlight_exclude() {
  [[ -f "$TARGET_HOME/.local/share/strata/.metadata_never_index" && -f "$TARGET_HOME/.cache/strata/.metadata_never_index" ]] || return 1
  if [[ -r "$MACOS_SPOTLIGHT_LIST" ]]; then
    local d
    while IFS= read -r d; do
      [[ -n "$d" && -d "$d" ]] || continue
      [[ -f "${d}/.metadata_never_index" ]] || return 1
    done < "$MACOS_SPOTLIGHT_LIST"
  fi
  return 0
}
explain_macos_spotlight_exclude() {
  cat <<'EOF'
Impact:
  Places '.metadata_never_index' markers inside Strata's data, cache, and model
  directories (~/.local/share/strata, ~/.cache/strata, ~/.strata, and optional
  custom model paths) so Spotlight (mds_stores) does not scan multi-GB GGUF/
  expert files and introduce SSD latency spikes during SSD expert streaming.
EOF
}
_macos_prompt_exclude_dirs() {
  local label="$1" list_fn="$2"
  local -a raw_dirs=()
  local d extra_dir=""
  while IFS= read -r d; do
    [[ -n "$d" ]] && raw_dirs+=("$d")
  done < <("$list_fn")
  read -r -p "Optional extra model folder to exclude from ${label} (blank to skip): " extra_dir || true
  if [[ -n "$extra_dir" ]]; then
    extra_dir="${extra_dir%\"}"; extra_dir="${extra_dir#\"}"
    extra_dir="${extra_dir%\'}"; extra_dir="${extra_dir#\'}"
    if [[ "$extra_dir" == "~" ]]; then
      extra_dir="$TARGET_HOME"
    elif [[ "$extra_dir" == "~/"* ]]; then
      extra_dir="${TARGET_HOME}/${extra_dir#\~/}"
    fi
    [[ "$extra_dir" != "/" ]] && extra_dir="${extra_dir%/}"
    if [[ -d "$extra_dir" ]]; then
      raw_dirs+=("$extra_dir")
    else
      echo -e "${C_YELLOW}Directory not found (${extra_dir}); skipping custom path.${C_RESET}" >&2
    fi
  fi
  printf '%s\n' "${raw_dirs[@]}" | awk '!seen[$0]++'
}
apply_macos_spotlight_exclude() {
  local -a dirs=()
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] && dirs+=("$d")
  done < <(_macos_prompt_exclude_dirs "Spotlight" "_macos_spotlight_dirs")
  run_as_user_exec mkdir -p "$(dirname "$MACOS_SPOTLIGHT_LIST")"
  : | run_as_user_exec tee "$MACOS_SPOTLIGHT_LIST" >/dev/null
  for d in "${dirs[@]}"; do
    run_as_user_exec mkdir -p "$d"
    run_as_user_exec touch "${d}/.metadata_never_index"
    printf '%s\n' "$d" | run_as_user_exec tee -a "$MACOS_SPOTLIGHT_LIST" >/dev/null
    echo -e "  ${C_GREEN}Excluded:${C_RESET} ${d}"
  done
}
revert_macos_spotlight_exclude() {
  local -a dirs=()
  local d
  if [[ -r "$MACOS_SPOTLIGHT_LIST" ]]; then
    while IFS= read -r d; do
      [[ -n "$d" ]] && dirs+=("$d")
    done < "$MACOS_SPOTLIGHT_LIST"
  fi
  while IFS= read -r d; do
    [[ -n "$d" ]] && dirs+=("$d")
  done < <(_macos_spotlight_dirs)
  while IFS= read -r d; do
    [[ -n "$d" && -f "${d}/.metadata_never_index" ]] && run_as_user_exec rm -f "${d}/.metadata_never_index"
  done < <(printf '%s\n' "${dirs[@]}" | awk '!seen[$0]++')
  run_as_user_exec rm -f "$MACOS_SPOTLIGHT_LIST"
  echo -e "${C_GREEN}Removed Spotlight exclusion markers from Strata directories.${C_RESET}"
}

# 12ab. Strata Metal Engine Environment Switches
_strip_shell_hook_line() {
  local rc_file="$1" tag="$2" tmp=""
  [[ -f "$rc_file" ]] && grep -qF "$tag" "$rc_file" 2>/dev/null || return 0
  if tmp="$(awk -v t="$tag" 'index($0, t) == 0 {print}' "$rc_file")"; then
    if [[ -n "$tmp" ]]; then
      printf '%s\n' "$tmp" | run_as_user_exec tee "$rc_file" >/dev/null
    else
      : | run_as_user_exec tee "$rc_file" >/dev/null
    fi
  fi
}
applicable_macos_metal_tuning() { [[ "$IS_MACOS" == true && "$IS_APPLE_SILICON" == true ]]; }
title_macos_metal_tuning() { echo "Strata Metal Engine Switches (FP16 Decode / Rootless Sensors / Arena)"; }
note_macos_metal_tuning() { echo -e "${C_BLUE}[OPT]${C_RESET}"; }
status_macos_metal_tuning() {
  [[ -s "$MACOS_METAL_ENV_FILE" ]] && grep -qE '^STRATA_[A-Z0-9_]+=' "$MACOS_METAL_ENV_FILE" 2>/dev/null
}
explain_macos_metal_tuning() {
  cat <<'EOF'
Impact:
  Configures documented Strata Metal runtime environment switches in
  ~/.config/strata/macos-metal-env.conf (automatically applied to wizard CLI
  runs, benchmarks, and the com.strata.server launchd service, plus optional
  ~/.zprofile shell integration):
    - STRATA_METAL_F16=1        : FP16 GEMVs on resident Q2_0/IQ3_S (+9-15% decode)
    - STRATA_MACOS_SENSORS=1    : Rootless SMC/IOReport GPU temp & power in Monitor
    - STRATA_METAL_PROMPT_CHUNK : Optional SSD streaming prompt chunk override
    - STRATA_METAL_ARENA_GB     : Optional SSD streaming expert cache arena size
    - STRATA_METAL_WIRE_ARENA=0 : Leave 64+ GiB streaming arena pageable
EOF
}
apply_macos_metal_tuning() {
  local -a vars=()
  local pchunk="" arena_gb=""
  if confirm_yn "Enable FP16 decode GEMVs for resident IQ3_S / Q2_0 packs (STRATA_METAL_F16=1)? [Y/n]: " "Y"; then
    vars+=("STRATA_METAL_F16=1")
  fi
  if confirm_yn "Enable rootless GPU temp/power sensors in Strata Monitor (STRATA_MACOS_SENSORS=1, uses private SMC/IOReport APIs)? [y/N]: " "N"; then
    vars+=("STRATA_MACOS_SENSORS=1")
  fi
  read -r -p "Override Metal prompt chunk size (STRATA_METAL_PROMPT_CHUNK, blank for auto): " pchunk || true
  if [[ -n "$pchunk" ]]; then
    if [[ "$pchunk" =~ ^[0-9]+$ ]] && (( pchunk >= 256 && pchunk <= 32768 )); then
      vars+=("STRATA_METAL_PROMPT_CHUNK=${pchunk}")
    else
      echo -e "${C_RED}Invalid prompt chunk '${pchunk}' (expected 256-32768). Skipping.${C_RESET}"
    fi
  fi
  read -r -p "Override SSD streaming expert arena size in GB (STRATA_METAL_ARENA_GB, blank for auto): " arena_gb || true
  if [[ -n "$arena_gb" ]]; then
    if [[ "$arena_gb" =~ ^[0-9]+$ ]] && (( arena_gb >= 1 && arena_gb <= RAM_GB )); then
      vars+=("STRATA_METAL_ARENA_GB=${arena_gb}")
    else
      echo -e "${C_RED}Invalid arena size '${arena_gb}' (expected 1-${RAM_GB}). Skipping.${C_RESET}"
    fi
  fi
  if (( RAM_GB >= 64 )) && confirm_yn "Disable mlock wiring of the SSD streaming arena (STRATA_METAL_WIRE_ARENA=0)? [y/N]: " "N"; then
    vars+=("STRATA_METAL_WIRE_ARENA=0")
  fi
  if (( ${#vars[@]} == 0 )); then
    echo -e "${C_YELLOW}No Metal switches selected; nothing written.${C_RESET}"
    return 0
  fi

  run_as_user_exec mkdir -p "$(dirname "$MACOS_METAL_ENV_FILE")"
  : | run_as_user_exec tee "$MACOS_METAL_ENV_FILE" >/dev/null
  : | run_as_user_exec tee "$MACOS_METAL_ENV_SH" >/dev/null
  local kv
  for kv in "${vars[@]}"; do
    printf '%s\n' "$kv" | run_as_user_exec tee -a "$MACOS_METAL_ENV_FILE" >/dev/null
    printf 'export %s\n' "$kv" | run_as_user_exec tee -a "$MACOS_METAL_ENV_SH" >/dev/null
  done
  if [[ -t 0 ]] && confirm_yn "Also source ${MACOS_METAL_ENV_SH} from ~/.zprofile for interactive shells? [y/N]: " "N"; then
    local zprof="$TARGET_HOME/.zprofile"
    local hook="[ -r \"${MACOS_METAL_ENV_SH}\" ] && . \"${MACOS_METAL_ENV_SH}\" # strata-metal-env"
    _strip_shell_hook_line "$zprof" "# strata-metal-env"
    printf '%s\n' "$hook" | run_as_user_exec tee -a "$zprof" >/dev/null
  fi
  echo -e "${C_GREEN}Saved Strata Metal switches to ${MACOS_METAL_ENV_FILE}.${C_RESET}"
  if service_installed strata.service; then
    echo -e "${C_YELLOW}Note: Restart com.strata.server from [STRATA] -> Service so launchd picks up the updated Metal switches.${C_RESET}"
  fi
}
revert_macos_metal_tuning() {
  run_as_user_exec rm -f "$MACOS_METAL_ENV_FILE" "$MACOS_METAL_ENV_SH"
  _strip_shell_hook_line "$TARGET_HOME/.zprofile" "# strata-metal-env"
  _strip_shell_hook_line "$TARGET_HOME/.bash_profile" "# strata-metal-env"
  if [[ "$HAS_LAUNCHD" == true ]]; then
    local _sc _lb _pl _rn _tmp=""
    IFS='|' read -r _sc _lb _pl _rn <<< "$(_launchd_meta strata.service)"
    if [[ -f "$_rn" ]] && grep -qE '^export STRATA_(METAL_|MACOS_SENSORS=)' "$_rn" 2>/dev/null; then
      if _tmp="$(awk '!/^export STRATA_(METAL_|MACOS_SENSORS=)/ {print}' "$_rn")"; then
        printf '%s\n' "$_tmp" | run_as_user_exec tee "$_rn" >/dev/null
        run_as_user_exec chmod 755 "$_rn"
      fi
    fi
  fi
  echo -e "${C_GREEN}Removed Strata Metal engine environment overrides.${C_RESET}"
}

# 12ac. macOS Time Machine Exclusion for Model & Cache Directories
MACOS_TM_LIST="${TARGET_HOME}/.local/share/strata-performance-setup/timemachine-excluded.list"

_macos_tm_dirs() {
  local d
  _macos_spotlight_dirs
  for d in "$TARGET_HOME/.cache/huggingface" "$TARGET_HOME/.ollama"; do
    [[ -d "$d" ]] && echo "$d"
  done
}
applicable_macos_timemachine_exclude() {
  [[ "$IS_MACOS" == true ]] && command -v tmutil >/dev/null 2>&1
}
title_macos_timemachine_exclude() { echo "Exclude Model & Cache Folders from Time Machine (tmutil)"; }
status_macos_timemachine_exclude() {
  [[ -r "$MACOS_TM_LIST" ]] || return 1
  local d checked=0
  while IFS= read -r d; do
    [[ -n "$d" && -d "$d" ]] || continue
    tmutil isexcluded "$d" 2>/dev/null | grep -q "\[Excluded\]" || return 1
    ((checked++))
  done < "$MACOS_TM_LIST"
  (( checked > 0 ))
}
explain_macos_timemachine_exclude() {
  cat <<'EOF'
Impact:
  Runs 'tmutil addexclusion' on Strata, HuggingFace, and Ollama model/cache
  folders (plus an optional custom folder) so Time Machine snapshots and
  background backups do not contend for SSD bandwidth during model loads.
EOF
}
apply_macos_timemachine_exclude() {
  local -a dirs=()
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] && dirs+=("$d")
  done < <(_macos_prompt_exclude_dirs "Time Machine" "_macos_tm_dirs")
  run_as_user_exec mkdir -p "$(dirname "$MACOS_TM_LIST")"
  : | run_as_user_exec tee "$MACOS_TM_LIST" >/dev/null
  for d in "${dirs[@]}"; do
    run_as_user_exec mkdir -p "$d"
    if run_as_user_exec tmutil addexclusion "$d" 2>/dev/null; then
      printf '%s\n' "$d" | run_as_user_exec tee -a "$MACOS_TM_LIST" >/dev/null
      echo -e "  ${C_GREEN}Excluded:${C_RESET} ${d}"
    fi
  done
}
revert_macos_timemachine_exclude() {
  local d
  if [[ -r "$MACOS_TM_LIST" ]]; then
    while IFS= read -r d; do
      [[ -n "$d" && -d "$d" ]] && run_as_user_exec tmutil removeexclusion "$d" 2>/dev/null || true
    done < "$MACOS_TM_LIST"
    run_as_user_exec rm -f "$MACOS_TM_LIST"
  fi
  echo -e "${C_GREEN}Removed Time Machine exclusions for model/cache directories.${C_RESET}"
}

# 12ad. macOS RDMA over Thunderbolt 5 (Distributed Mac Clusters)
applicable_macos_rdma_tb5() {
  [[ "$IS_MACOS" == true && "$IS_APPLE_SILICON" == true ]] || return 1
  (( MACOS_MAJOR >= 26 )) && return 0
  command -v rdma_ctl >/dev/null 2>&1
}
title_macos_rdma_tb5() { echo "macOS RDMA over Thunderbolt 5 (exo / MLX Distributed Clusters)"; }
note_macos_rdma_tb5() { echo -e "${C_BLUE}[OPT]${C_RESET}"; }
status_macos_rdma_tb5() {
  command -v rdma_ctl >/dev/null 2>&1 && rdma_ctl status 2>/dev/null | grep -qiE 'enabled|active'
}
explain_macos_rdma_tb5() {
  cat <<'EOF'
Impact:
  Enables RDMA over Thunderbolt 5 (macOS 26.2+ / rdma_ctl enable) for low-
  latency, high-bandwidth tensor/pipeline parallelism across clustered Macs
  (exo, mlx.distributed). Only relevant when networking multiple Macs via TB5.
EOF
  echo -e "\n${C_YELLOW}[NOTE] On Apple Silicon Macs, enabling RDMA may require confirming 'rdma_ctl enable'${C_RESET}"
  echo -e "${C_YELLOW}       from macOS Recovery Terminal if not already authorized.${C_RESET}"
}
apply_macos_rdma_tb5() {
  if ! command -v rdma_ctl >/dev/null 2>&1; then
    echo -e "${C_YELLOW}rdma_ctl was not found (requires macOS 26.2+ on Apple Silicon with Thunderbolt 5).${C_RESET}"
    return 1
  fi
  if ! run_root rdma_ctl enable; then
    echo -e "${C_YELLOW}Could not enable RDMA from live macOS. Boot into macOS Recovery -> Terminal and run 'rdma_ctl enable', then reboot.${C_RESET}"
    return 1
  fi
  echo -e "${C_GREEN}Enabled RDMA over Thunderbolt 5.${C_RESET}"
}
revert_macos_rdma_tb5() {
  if command -v rdma_ctl >/dev/null 2>&1; then
    run_root rdma_ctl disable 2>/dev/null || true
  fi
  echo -e "${C_GREEN}Disabled RDMA over Thunderbolt 5.${C_RESET}"
}
