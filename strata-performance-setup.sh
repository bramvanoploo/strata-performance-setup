#!/usr/bin/env bash
# ==============================================================================
# Strata Host Performance Optimizer & Setup Wizard
# ==============================================================================
# Interactive TUI wizard to apply, inspect, and revert host-level performance
# optimizations for running Strata LLM inference (and install/manage Strata).
#
# Supported platforms:
#   - Linux: Arch, Fedora/RHEL, Debian/Ubuntu (incl. Jetson L4T), openSUSE,
#            Slackware, Unraid, TrueNAS SCALE, Synology DSM
#   - macOS: Apple Silicon (M1 or newer, macOS 15+ / Metal / launchd)
# ==============================================================================

# Ensure Bash 4.3+ (associative arrays, namerefs, fractional read timeouts).
# macOS ships Bash 3.2 at /bin/bash; re-exec under Homebrew/MacPorts/Nix Bash.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 3 ]; }; then
  _strata_bash=""
  for _strata_cand in /opt/homebrew/bin/bash /usr/local/bin/bash /opt/local/bin/bash /nix/var/nix/profiles/default/bin/bash; do
    if [ -x "$_strata_cand" ]; then
      if "$_strata_cand" -c '[ "${BASH_VERSINFO[0]:-0}" -gt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 3 ]; }' 2>/dev/null; then
        _strata_bash="$_strata_cand"
        break
      fi
    fi
  done
  if [ -n "$_strata_bash" ]; then
    exec "$_strata_bash" "$0" "$@"
  fi
  printf 'strata-performance-setup.sh requires Bash 4.3+ (running %s).\n' "${BASH_VERSION:-unknown}" >&2
  if [ "$(uname -s 2>/dev/null || true)" = "Darwin" ]; then
    _strata_brew=""
    for _strata_cand in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      [ -x "$_strata_cand" ] && { _strata_brew="$_strata_cand"; break; }
    done
    if [ -n "$_strata_brew" ] && [ "${EUID:-$(id -u)}" -ne 0 ] && [ -t 0 ]; then
      printf 'Install modern Bash via Homebrew now (%s install bash)? [Y/n]: ' "$_strata_brew" >&2
      read -r _strata_ans || _strata_ans="n"
      case "${_strata_ans:-Y}" in
        y|Y|yes|YES|Yes)
          if "$_strata_brew" install bash; then
            for _strata_cand in /opt/homebrew/bin/bash /usr/local/bin/bash; do
              [ -x "$_strata_cand" ] && exec "$_strata_cand" "$0" "$@"
            done
          fi
          ;;
      esac
    fi
    printf 'Install Bash 4.3+ on macOS with Homebrew: brew install bash\n' >&2
  fi
  exit 1
fi

set -uo pipefail

if [[ "${STRATA_OS_UNAME:-$(uname -s 2>/dev/null || echo Linux)}" == "Darwin" ]]; then
  IS_MACOS=true
  [[ -d /opt/homebrew/bin && ":${PATH}:" != *":/opt/homebrew/bin:"* ]] && PATH="/opt/homebrew/bin:${PATH}"
  [[ -d /opt/homebrew/sbin && ":${PATH}:" != *":/opt/homebrew/sbin:"* ]] && PATH="/opt/homebrew/sbin:${PATH}"
  [[ -d /usr/local/bin && ":${PATH}:" != *":/usr/local/bin:"* ]] && PATH="/usr/local/bin:${PATH}"
  [[ -d /usr/local/sbin && ":${PATH}:" != *":/usr/local/sbin:"* ]] && PATH="/usr/local/sbin:${PATH}"
  export PATH
else
  IS_MACOS=false
fi

has_working_python3() {
  local py_bin
  py_bin="$(command -v python3 2>/dev/null || true)"
  [[ -n "$py_bin" ]] || return 1
  if [[ "$IS_MACOS" == true && "$py_bin" == "/usr/bin/python3" ]] && command -v xcode-select >/dev/null 2>&1; then
    xcode-select -p >/dev/null 2>&1 || return 1
  fi
  return 0
}

# ------------------------------------------------------------------------------
# Colors & Globals
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET='\033[0m' C_BOLD='\033[1m' C_DIM='\033[2m'
  C_RED='\033[0;31m' C_GREEN='\033[0;32m' C_BGREEN='\033[1;32m' C_YELLOW='\033[0;33m' C_BLUE='\033[1;34m' C_MAGENTA='\033[0;35m' C_CYAN='\033[0;36m'
  C_UPDATE_BANNER='\033[1;30;102m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_BGREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN='' C_UPDATE_BANNER=''
fi

TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
TARGET_HOME=""
if [[ "$IS_MACOS" == true ]] && command -v dscl >/dev/null 2>&1; then
  TARGET_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2; exit}' || true)"
elif command -v getent >/dev/null 2>&1; then
  TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
fi
if [[ -z "$TARGET_HOME" ]] && has_working_python3; then
  TARGET_HOME="$(python3 -c 'import pwd, sys; print(pwd.getpwnam(sys.argv[1]).pw_dir)' "$TARGET_USER" 2>/dev/null || true)"
fi
[[ -n "$TARGET_HOME" ]] || TARGET_HOME="$HOME"
STRATA_BIN="" STRATA_VERSION="" STRATA_RUNNING_PRESET="" STRATA_RUNNING_URL="" STRATA_DOCKER_CONTAINER="" STRATA_DOCKER_IMAGE=""
STRATA_API_KEY="${STRATA_API_KEY:-}"
[[ -n "$STRATA_API_KEY" ]] && export STRATA_API_KEY
CHECK_ONLY=false
DISTRO_FAMILY="unknown" DISTRO_ID="unknown" OS_PRETTY="" KERNEL_VER="" AUR_HELPER="" HAS_SYSTEMD=true HAS_LAUNCHD=false IS_UNRAID=false IS_TRUENAS=false IS_SYNOLOGY=false
IS_APPLE_SILICON=false IS_APPLE_LINUX=false IS_ASAHI_LINUX=false HAS_APPLESMC=false
MACOS_VER="" MACOS_MAJOR=0 MACOS_CHIP="" MACOS_GPU_CORES="" MACOS_METAL_VER="" MACOS_MODEL_ID="" MACOS_WIRED_LIMIT_MB="" MACOS_POWER_MODE_SUPPORTED=false
MACOS_CPU_THREADS="" MACOS_RAM_BYTES=0
MACOS_SUPPORT_DIR="${STRATA_MACOS_SUPPORT_DIR:-/Library/Application Support/strata-performance-setup}"
MACOS_POWER_MODE_MARKER="${MACOS_SUPPORT_DIR}/macos-power-mode.prev"
MACOS_NOSLEEP_MARKER="${MACOS_SUPPORT_DIR}/macos-nosleep.prev"
MACOS_METAL_ENV_FILE="$TARGET_HOME/.config/strata/macos-metal-env.conf"
MACOS_METAL_ENV_SH="$TARGET_HOME/.config/strata/macos-metal-env.sh"
MACOS_SPOTLIGHT_LIST="$TARGET_HOME/.local/share/strata-performance-setup/spotlight-excluded.list"
APPLESMC_MBPFAN_MARKER="/etc/strata-applesmc-mbpfan.conf"
HAS_NVIDIA=false HAS_NVIDIA_POWERD=false HAS_AMD=false HAS_INTEL_GPU=false HAS_INTEL_ARC=false
HAS_AMD_APU=false HAS_AMD_PREBUILT_GFX=false AMD_GTT_TOTAL_MB=0
HAS_AMD_INSTINCT=false HAS_AMD_NON_INSTINCT=false
HAS_NVIDIA_TESLA=false HAS_NVIDIA_NON_TESLA=false NVIDIA_COMPUTE_MODE_NON_DEFAULT=false
HAS_NVIDIA_DATACENTER=false HAS_NVIDIA_PASSIVE=false HAS_NVIDIA_LEGACY_PSTATE_CARD=false
HAS_NVIDIA_KEPLER=false HAS_NVIDIA_MAXWELL=false HAS_NVIDIA_PASCAL=false HAS_NVIDIA_VOLTA_SM70=false
HAS_NVIDIA_NVSWITCH=false IS_DGX_SPARK=false HAS_NVIDIA_UNIFIED_MEM=false
NVIDIA_DRIVER_VER="" NVIDIA_DRIVER_MAJOR=0 NVIDIA_LIVE_EXTRA_FIELDS=""
NVIDIA_MIG_ANY_ENABLED=false NVIDIA_MIG_ANY_PEND_ENABLED=false
GPU_SUMMARY="" GPU_RAW="" AMD_GFX_SUMMARY="" AMD_MISSING_GFX_SUMMARY="" CPU_SUMMARY="" RAM_GB=0 RAM_MB=0 RAM_DETAILS="" NVIDIA_VRAM_MB=0 TOTAL_VRAM_MB=0
HAS_MSI_EC=false SYS_VENDOR="" PRODUCT_NAME="" IS_LAPTOP=false HAS_ASPM=false
IS_JETSON=false IS_JETSON_TX2=false IS_JETSON_XAVIER=false IS_JETSON_ORIN=false IS_JETSON_THOR=false
JETSON_MODEL="" JETSON_L4T_REL="" JETSON_SOC=""
NVIDIA_DEFAULT_PL="" NVIDIA_MAX_PL="" NVIDIA_CURRENT_PL=""
NVIDIA_MAX_GFX_CLK="" NVIDIA_MAX_MEM_CLK="" NVIDIA_ECC_CUR="" NVIDIA_ECC_PEND=""
IS_VIRT="" NUMA_NODES=1 CPU_SOCKETS=1 DISCRETE_GPU_COUNT=0 DMI_MEM_CACHE=""
HAS_FULL_GPU_INTERCONNECT=false PCIE_ACS_ENABLED=false PCIE_ACS_CHECKED=false
declare -a RAM_HEALTH_LINES=() GPU_TOPO_LINES=()
declare -a AMD_GFX_ARCHS=() AMD_MISSING_GFX_ARCHS=()
declare -a NVIDIA_GPU_INDICES=() NVIDIA_GPU_NAMES=() NVIDIA_GPU_CUR_PL=() NVIDIA_GPU_DEF_PL=() NVIDIA_GPU_MAX_PL=() NVIDIA_GPU_MIN_PL=() NVIDIA_GPU_VRAM=() NVIDIA_GPU_COMPUTE_MODE=() NVIDIA_GPU_IS_TESLA=() NVIDIA_GPU_IS_DATACENTER=() NVIDIA_GPU_IS_PASSIVE=() NVIDIA_GPU_PL_SUPPORTED=() NVIDIA_GPU_COMPUTE_CAP=()
declare -a NVIDIA_GPU_MAX_GFX_CLK=() NVIDIA_GPU_MAX_MEM_CLK=() NVIDIA_ECC_INDICES=()
declare -a NVIDIA_MIG_INDICES=() NVIDIA_GPU_MIG_CUR=() NVIDIA_GPU_MIG_PEND=()
RYZENADJ_MARKER="/etc/strata-ryzenadj.prev" RAPL_MARKER="/etc/strata-rapl.prev" TUNED_MARKER="/etc/strata-tuned.prev" NUMACTL_MARKER="/etc/strata-numactl.enabled"
HEADLESS_MARKER="/etc/strata-headless.prev" PSTATE_MARKER="/etc/strata-pstate.prev" GPU_GROUPS_MARKER="/etc/strata-gpu-groups.added"
NVIDIA_COMPUTE_PREV_MARKER="/etc/strata-nvidia-compute-mode.prev"
NVIDIA_MIG_PREV_MARKER="/etc/strata-nvidia-mig.prev"
NVIDIA_POWER_CAP_MARKER="/etc/strata-nvidia-power-cap.conf"
NVIDIA_SM70_MARKER="/etc/strata-nvidia-sm70-table.enabled"
NVIDIA_PSTATE_MARKER="/etc/strata-nvidia-pstate.mode"
AMD_INSTINCT_PART_MARKER="/etc/strata-amd-instinct-partition.prev"
REBOOT_REQUIRED=false REBOOT_PROMPT_PENDING=false
PREV_CPU_TOTAL="" PREV_CPU_IDLE="" PREV_RAPL_UJ="" PREV_RAPL_US="" LIVE_STATS_COUNT=0 POST_HEADER_LINES=0 UPDATE_BANNER_OFFSET=1 INDEX_LEGEND_LINES=1
declare -A PREV_INTEL_GPU_UJ_MAP=() PREV_INTEL_GPU_US_MAP=()
TERM_COLS_CACHED=120 LIVE_COMPACT_SYS="" LIVE_COMPACT_STRATA=""
declare -a LIVE_STAT_LINES=() SYS_INFO_LINES=() STRATA_STAT_LINES=() STRATA_BENCH_LINES=()
STRATA_BENCH_CACHE_KEY=""
BENCH_HISTORY_COUNT_KEY="" BENCH_HISTORY_COUNT_CACHE=0
LOCAL_HIP_INFO_CACHE_KEY="" LOCAL_HIP_INFO_CACHE_MATCH="" LOCAL_HIP_INFO_CACHE_ANY=""
STRATA_BENCH_HISTORY_FILE="$TARGET_HOME/.local/share/strata-performance-setup/bench-history.json"
BENCH_POWER_SAMPLER_PID="" BENCH_POWER_TMP_FILE=""
ACTIVE_SAMPLER_PID="" ACTIVE_SAMPLER_TMP=""
STRATA_UPDATE_AVAILABLE=false STRATA_UPDATE_SUMMARY="" STRATA_UPDATE_CACHE_FILE="" STRATA_POLLER_PID=""
UNIT_FILES_CACHE=""
declare -A PKG_AVAIL_CACHE PKG_INST_CACHE
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="1.9.0"
PLUGIN_BASE_URL="${STRATA_PLUGIN_BASE_URL:-https://raw.githubusercontent.com/bramvanoploo/strata-performance-setup/main}"
PLUGIN_CACHE_DIR="${STRATA_PLUGIN_CACHE_DIR:-${XDG_CACHE_HOME:-$TARGET_HOME/.cache}/strata-performance-setup/plugins}"
NO_PLUGINS=false
REGISTRY_FETCHED=false
declare -a REQUESTED_HOST_PLUGINS=() LOADED_HOST_PLUGINS=() LOADED_TWEAK_PACKS=() AVAILABLE_HOST_PLUGINS=("strata")
declare -A HOST_PLUGIN_LOADED=() TWEAK_PACK_LOADED=()
declare -A HOST_PLUGIN_NAMES=([strata]="Strata")
declare -A HOST_PLUGIN_DESCS=([strata]="Install, update, launch, and benchmark Strata LLM server")
declare -A TWEAK_REGISTERED=() STEP_TIER=() STEP_OS=() STEP_LAPTOP_REC=() STEP_VM_SUPPORTED=() STEP_EXP_NON_ARCH=()

# ------------------------------------------------------------------------------
# Core Helpers (Privileges, Packages, Services, Bootloader)
# ------------------------------------------------------------------------------
file_mtime() {
  local path="$1"
  if [[ "$IS_MACOS" == true ]]; then
    stat -f '%m' "$path" 2>/dev/null || echo 0
  else
    stat -c '%Y' "$path" 2>/dev/null || echo 0
  fi
}

_xml_escape() {
  local s="$1" _had_pr=0
  shopt -q patsub_replacement 2>/dev/null && { _had_pr=1; shopt -u patsub_replacement; }
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  (( _had_pr )) && shopt -s patsub_replacement
  printf '%s' "$s"
}

run_root() {
  [[ "${CHECK_ONLY:-false}" == true ]] && return 1
  if [[ $EUID -eq 0 ]]; then "$@"
  else sudo "$@"; fi
}

run_as_user() {
  local env_prefix="" _kv="" _k="" _qv=""
  local -a _rt_env=()
  [[ -n "${STRATA_API_KEY:-}" ]] && printf -v env_prefix 'export STRATA_API_KEY=%q; ' "$STRATA_API_KEY"
  _fill_strata_runtime_env_array _rt_env
  for _kv in ${_rt_env[@]+"${_rt_env[@]}"}; do
    _k="${_kv%%=*}"
    printf -v _qv '%q' "${_kv#*=}"
    env_prefix+="export ${_k}=${_qv}; "
  done
  if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
    if [[ "$IS_MACOS" == true ]]; then
      sudo -u "$TARGET_USER" -H -- env "PATH=${TARGET_HOME}/.local/bin:${PATH}" bash -c "${env_prefix}$*"
    elif command -v runuser >/dev/null 2>&1; then
      runuser -u "$TARGET_USER" -- bash -c "${env_prefix}$*"
    else
      su - "$TARGET_USER" -c "${env_prefix}$*"
    fi
  else
    bash -c "${env_prefix}$*"
  fi
}

# Argument-safe execution as TARGET_USER without extra shell interpolation.
run_as_user_exec() {
  local -a env_args=() env_cmd=() _rt_env=()
  [[ -n "${STRATA_API_KEY:-}" ]] && env_args+=("STRATA_API_KEY=${STRATA_API_KEY}")
  _fill_strata_runtime_env_array _rt_env
  (( ${#_rt_env[@]} > 0 )) && env_args+=("${_rt_env[@]}")
  (( ${#env_args[@]} > 0 )) && env_cmd=(env "${env_args[@]}")
  if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
    if [[ "$IS_MACOS" == true ]]; then
      sudo -u "$TARGET_USER" -H -- env "PATH=${TARGET_HOME}/.local/bin:${PATH}" ${env_args[@]+"${env_args[@]}"} "$@"
    elif command -v runuser >/dev/null 2>&1; then
      runuser -u "$TARGET_USER" -- ${env_cmd[@]+"${env_cmd[@]}"} "$@"
    else
      local cmd=""
      printf -v cmd '%q ' ${env_cmd[@]+"${env_cmd[@]}"} "$@"
      su - "$TARGET_USER" -c "$cmd"
    fi
  else
    ${env_cmd[@]+"${env_cmd[@]}"} "$@"
  fi
}

refresh_unit_files_cache() {
  if [[ "$HAS_SYSTEMD" == true ]]; then
    UNIT_FILES_CACHE="$(systemctl list-unit-files --no-legend --no-pager 2>/dev/null || true)"
  else
    UNIT_FILES_CACHE=""
  fi
}

unit_exists() {
  [[ "$HAS_SYSTEMD" == true ]] || return 1
  awk -v u="$1" '$1 == u {found=1; exit} END {exit !found}' <<< "$UNIT_FILES_CACHE"
}

_launchd_meta() {
  local unit="$1" name="${1%.service}" scope="system" label="" plist="" runner="" short=""
  if [[ "$unit" == "strata.service" ]]; then
    scope="user"
    label="com.strata.server"
    plist="${STRATA_LAUNCHD_USER_DIR:-$TARGET_HOME/Library/LaunchAgents}/${label}.plist"
    runner="${STRATA_LAUNCHD_USER_BIN_DIR:-$TARGET_HOME/.local/share/strata-performance-setup}/strata-server-ctl.sh"
  else
    short="${name#strata-}"
    label="com.strata.${short}"
    plist="${STRATA_LAUNCHD_SYS_DIR:-/Library/LaunchDaemons}/${label}.plist"
    runner="${STRATA_LAUNCHD_SYS_BIN_DIR:-$MACOS_SUPPORT_DIR}/${name}.sh"
  fi
  printf '%s|%s|%s|%s\n' "$scope" "$label" "$plist" "$runner"
}

_launchd_user_uid() {
  id -u "$TARGET_USER" 2>/dev/null || id -u
}

resolve_rc_script() {
  local name="${1%.service}" rc_dir="${STRATA_RC_DIR:-/etc/rc.d}"
  if [[ -x "${rc_dir}/rc.strata.${name}" ]]; then
    echo "${rc_dir}/rc.strata.${name}"
  elif [[ "$IS_UNRAID" == true && -f "/boot/config/strata/rc.strata.${name}" ]]; then
    echo "/boot/config/strata/rc.strata.${name}"
  elif [[ "$IS_SYNOLOGY" == true && -x "/usr/local/etc/rc.d/strata-${name}.sh" ]]; then
    echo "/usr/local/etc/rc.d/strata-${name}.sh"
  else
    return 1
  fi
}

service_installed() {
  local unit="$1"
  if [[ "$HAS_SYSTEMD" == true ]]; then
    [[ -f "/etc/systemd/system/${unit}" ]]
  elif [[ "$HAS_LAUNCHD" == true ]]; then
    local _sc _lb _pl _rn
    IFS='|' read -r _sc _lb _pl _rn <<< "$(_launchd_meta "$unit")"
    [[ -f "$_pl" ]]
  else
    resolve_rc_script "$unit" >/dev/null
  fi
}

unit_enabled() {
  if [[ "$HAS_SYSTEMD" == true ]]; then
    systemctl is-enabled "$1" >/dev/null 2>&1
  else
    service_installed "$1"
  fi
}

unit_active() {
  if [[ "$HAS_SYSTEMD" == true ]]; then
    systemctl is-active "$1" >/dev/null 2>&1
  elif [[ "$HAS_LAUNCHD" == true ]]; then
    local _sc _lb _pl _rn
    IFS='|' read -r _sc _lb _pl _rn <<< "$(_launchd_meta "$1")"
    [[ -f "$_pl" ]] || return 1
    if [[ "$_sc" == "user" ]]; then
      local uid
      uid="$(_launchd_user_uid)"
      if run_as_user_exec launchctl print "gui/${uid}/${_lb}" >/dev/null 2>&1 || run_as_user_exec launchctl list "$_lb" >/dev/null 2>&1; then
        return 0
      fi
      [[ "$1" == "strata.service" && -f "$_pl" && -n "$STRATA_RUNNING_PRESET" ]]
    else
      if [[ $EUID -eq 0 ]]; then
        launchctl print "system/${_lb}" >/dev/null 2>&1 || launchctl list "$_lb" >/dev/null 2>&1
      elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n launchctl print "system/${_lb}" >/dev/null 2>&1 || [[ -f "$_pl" ]]
      else
        [[ -f "$_pl" ]]
      fi
    fi
  else
    service_installed "$1"
  fi
}

service_ctl() {
  local action="$1" unit="$2"
  [[ "${CHECK_ONLY:-false}" == true ]] && return 1
  if [[ "$HAS_SYSTEMD" == true ]]; then
    run_root systemctl "$action" "$unit"
  elif [[ "$HAS_LAUNCHD" == true ]]; then
    local _sc _lb _pl _rn
    IFS='|' read -r _sc _lb _pl _rn <<< "$(_launchd_meta "$unit")"
    [[ -f "$_pl" ]] || return 1
    if [[ "$_sc" == "user" ]]; then
      local uid
      uid="$(_launchd_user_uid)"
      case "$action" in
        start)
          run_as_user_exec launchctl bootout "gui/${uid}/${_lb}" >/dev/null 2>&1 || true
          if ! run_as_user_exec launchctl bootstrap "gui/${uid}" "$_pl" >/dev/null 2>&1; then
            if ! run_as_user_exec launchctl load -w "$_pl" >/dev/null 2>&1; then
              [[ -x "$_rn" ]] && run_as_user_exec sh "$_rn" start || return 1
            fi
          fi
          ;;
        stop)
          run_as_user_exec launchctl bootout "gui/${uid}/${_lb}" >/dev/null 2>&1 || run_as_user_exec launchctl unload -w "$_pl" >/dev/null 2>&1 || true
          [[ -x "$_rn" ]] && run_as_user_exec sh "$_rn" stop || true
          ;;
        restart)
          service_ctl stop "$unit" || true
          service_ctl start "$unit"
          ;;
        *) return 1 ;;
      esac
    else
      case "$action" in
        start)
          run_root launchctl bootout "system/${_lb}" >/dev/null 2>&1 || true
          if ! run_root launchctl bootstrap system "$_pl" >/dev/null 2>&1; then
            if ! run_root launchctl load -w "$_pl" >/dev/null 2>&1; then
              [[ -x "$_rn" ]] && run_root sh "$_rn" start || return 1
            fi
          fi
          ;;
        stop)
          run_root launchctl bootout "system/${_lb}" >/dev/null 2>&1 || run_root launchctl unload -w "$_pl" >/dev/null 2>&1 || true
          [[ -x "$_rn" ]] && run_root sh "$_rn" stop || true
          ;;
        restart)
          service_ctl stop "$unit" || true
          service_ctl start "$unit"
          ;;
        *) return 1 ;;
      esac
    fi
  else
    local rc_script
    rc_script="$(resolve_rc_script "$unit")" || return 1
    run_root sh "$rc_script" "$action"
  fi
}

add_boot_hook() {
  local file="$1" tag="$2" hook="$3" shebang="${4:-#!/bin/sh}"
  if [[ ! -f "$file" ]]; then
    printf '%s\n' "$shebang" | run_root tee "$file" >/dev/null
  fi
  if [[ -f "$file" ]] && grep -qF "$tag" "$file" 2>/dev/null && ! grep -qxF "$hook" "$file" 2>/dev/null; then
    remove_boot_hook "$file" "$tag"
  fi
  if ! grep -qF "$tag" "$file" 2>/dev/null; then
    [[ -s "$file" && -n "$(tail -c1 "$file" 2>/dev/null)" ]] && printf '\n' | run_root tee -a "$file" >/dev/null
    printf '%s\n' "$hook" | run_root tee -a "$file" >/dev/null
  fi
}

remove_boot_hook() {
  local file="$1" tag="$2" tmp
  [[ -f "$file" ]] && grep -qF "$tag" "$file" 2>/dev/null || return 0
  if tmp="$(awk -v t="$tag" 'index($0, t) == 0 {print}' "$file")"; then
    if [[ -n "$tmp" ]]; then
      printf '%s\n' "$tmp" | run_root tee "$file" >/dev/null
    else
      : | run_root tee "$file" >/dev/null
    fi
  fi
}

install_service() {
  local unit="$1"
  [[ "${CHECK_ONLY:-false}" == true ]] && return 1
  if [[ "$HAS_SYSTEMD" == true ]]; then
    run_root tee "/etc/systemd/system/${unit}" >/dev/null
    run_root systemctl daemon-reload
    refresh_unit_files_cache
    run_root systemctl enable --now "$unit"
    return $?
  fi

  local name="${unit%.service}"
  local content env_cmds="" start_cmds="" stop_cmds="" work_dir="" svc_user="" limit_memlock="" line cmd ignore_err ev ek evv
  content="$(cat)"
  while IFS= read -r line; do
    if [[ "$line" =~ ^Environment=(.*)$ ]]; then
      ev="${BASH_REMATCH[1]}"
      [[ "$ev" == \"*\" ]] && ev="${ev#\"}" && ev="${ev%\"}"
      if [[ "$ev" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        ek="${BASH_REMATCH[1]}"
        evv="${BASH_REMATCH[2]}"
        if [[ "$evv" =~ ^[A-Za-z0-9_.,:/+-]*$ ]]; then
          env_cmds+="export ${ek}=${evv}"$'\n'
        else
          evv="$(printf "%s" "$evv" | sed "s/'/'\\\\''/g")"
          env_cmds+="export ${ek}='${evv}'"$'\n'
        fi
      fi
    elif [[ "$line" =~ ^WorkingDirectory=(.*)$ ]]; then
      work_dir="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^User=(.*)$ ]]; then
      svc_user="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^LimitMEMLOCK=(.*)$ ]]; then
      limit_memlock="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^ExecStart=(.*)$ ]]; then
      cmd="${BASH_REMATCH[1]}"
      ignore_err=""
      if [[ "$cmd" == -* ]]; then cmd="${cmd#-}"; ignore_err=" || true"; fi
      start_cmds+="    ${cmd}${ignore_err}"$'\n'
    elif [[ "$line" =~ ^ExecStop=(.*)$ ]]; then
      cmd="${BASH_REMATCH[1]}"
      ignore_err=""
      if [[ "$cmd" == -* ]]; then cmd="${cmd#-}"; ignore_err=" || true"; fi
      stop_cmds+="    ${cmd}${ignore_err}"$'\n'
    fi
  done <<< "$content"

  if [[ "$HAS_LAUNCHD" == true ]]; then
    local scope label plist runner work_dir_line="" dyn_env_line="" runner_content plist_content
    IFS='|' read -r scope label plist runner <<< "$(_launchd_meta "$unit")"
    if [[ "$scope" == "user" && -n "${MACOS_METAL_ENV_SH:-}" ]]; then
      local me_sq
      me_sq="$(printf "%s" "$MACOS_METAL_ENV_SH" | sed "s/'/'\\\\''/g")"
      dyn_env_line="[ -r '${me_sq}' ] && . '${me_sq}'"$'\n'
    fi
    if [[ -n "$work_dir" ]]; then
      local wd_sq
      wd_sq="$(printf "%s" "$work_dir" | sed "s/'/'\\\\''/g")"
      work_dir_line="cd '${wd_sq}' || true"$'\n'
    fi
    runner_content="#!/bin/sh
# Managed by strata-performance-setup (${unit})
export PATH=\"${TARGET_HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\${PATH:-}\"
${env_cmds}${dyn_env_line}${work_dir_line}case \"\$1\" in
  start)
${start_cmds:-    :}
    ;;
  stop)
${stop_cmds:-    :}
    ;;
  restart)
    \"\$0\" stop
    \"\$0\" start
    ;;
  *)
    echo \"Usage: \$0 {start|stop|restart}\"
    exit 1
    ;;
esac
"
    local extra_plist=""
    if [[ "$scope" == "user" ]]; then
      local log_dir="$TARGET_HOME/Library/Logs"
      extra_plist="  <key>AbandonProcessGroup</key>
  <true/>
"
      [[ -n "$work_dir" ]] && extra_plist+="  <key>WorkingDirectory</key>
  <string>$(_xml_escape "$work_dir")</string>
"
      extra_plist+="  <key>StandardOutPath</key>
  <string>$(_xml_escape "${log_dir}/strata.log")</string>
  <key>StandardErrorPath</key>
  <string>$(_xml_escape "${log_dir}/strata.err.log")</string>
"
    fi
    plist_content="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>Label</key>
  <string>$(_xml_escape "$label")</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>$(_xml_escape "$runner")</string>
    <string>start</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
${extra_plist}</dict>
</plist>
"
    if [[ "$scope" == "user" ]]; then
      local uid
      uid="$(_launchd_user_uid)"
      run_as_user_exec mkdir -p "$(dirname "$plist")" "$(dirname "$runner")" "$TARGET_HOME/Library/Logs"
      printf '%s' "$runner_content" | run_as_user_exec tee "$runner" >/dev/null
      run_as_user_exec chmod 755 "$runner"
      printf '%s' "$plist_content" | run_as_user_exec tee "$plist" >/dev/null
      run_as_user_exec chmod 644 "$plist"
      run_as_user_exec launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
      if ! run_as_user_exec launchctl bootstrap "gui/${uid}" "$plist" >/dev/null 2>&1; then
        if ! run_as_user_exec launchctl load -w "$plist" >/dev/null 2>&1; then
          run_as_user_exec sh "$runner" start
          echo -e "${C_YELLOW}Note: launchd GUI domain unavailable in this session; auto-start will activate on next login.${C_RESET}"
        fi
      fi
    else
      run_root mkdir -p "$(dirname "$plist")" "$(dirname "$runner")"
      printf '%s' "$runner_content" | run_root tee "$runner" >/dev/null
      run_root chmod 755 "$runner"
      printf '%s' "$plist_content" | run_root tee "$plist" >/dev/null
      run_root chown root:wheel "$plist" 2>/dev/null || true
      run_root chmod 644 "$plist"
      run_root launchctl bootout "system/${label}" >/dev/null 2>&1 || true
      if ! run_root launchctl bootstrap system "$plist" >/dev/null 2>&1; then
        run_root launchctl load -w "$plist" >/dev/null 2>&1 || run_root sh "$runner" start
      fi
    fi
    return 0
  fi

  local rc_dir="${STRATA_RC_DIR:-/etc/rc.d}"
  local rc_script="${rc_dir}/rc.strata.${name}"
  local rc_work_line="" rc_memlock_line="" rc_start_body="${start_cmds:-    :}" rc_stop_body="${stop_cmds:-    :}"
  if [[ -n "$work_dir" ]]; then
    local rc_wd_sq
    rc_wd_sq="$(printf "%s" "$work_dir" | sed "s/'/'\\\\''/g")"
    rc_work_line="cd '${rc_wd_sq}' || true"$'\n'
  fi
  if [[ "$limit_memlock" == "infinity" ]]; then
    rc_memlock_line="ulimit -l unlimited 2>/dev/null || true"$'\n'
  fi
  if [[ -n "$svc_user" && "$svc_user" != "root" ]]; then
    local rc_u_sq rc_home_sq rc_start_sq rc_stop_sq
    rc_u_sq="$(printf "%s" "$svc_user" | sed "s/'/'\\\\''/g")"
    rc_home_sq="$(printf "%s" "${work_dir:-$TARGET_HOME}" | sed "s/'/'\\\\''/g")"
    _rc_wrap_user() {
      local body_txt="$1" body_sq=""
      body_sq="$(printf "%s" "${env_cmds}${rc_work_line}${body_txt}" | sed "s/'/'\\\\''/g")"
      printf '    if [ "$(id -un)" = '\''%s'\'' ]; then\n      sh -c '\''%s'\''\n    elif command -v runuser >/dev/null 2>&1; then\n      HOME='\''%s'\'' runuser -u '\''%s'\'' -- sh -c '\''%s'\''\n    else\n      HOME='\''%s'\'' su -s /bin/sh '\''%s'\'' -c '\''%s'\''\n    fi\n' \
        "$rc_u_sq" "$body_sq" "$rc_home_sq" "$rc_u_sq" "$body_sq" "$rc_home_sq" "$rc_u_sq" "$body_sq"
    }
    rc_start_body="$(_rc_wrap_user "$rc_start_body")"
    rc_stop_body="$(_rc_wrap_user "$rc_stop_body")"
    unset -f _rc_wrap_user
    env_cmds=""
    rc_work_line=""
  fi
  run_root tee "$rc_script" >/dev/null <<EOF
#!/bin/sh
# Managed by strata-performance-setup (${unit})
${env_cmds}${rc_work_line}${rc_memlock_line}case "\$1" in
  start)
${rc_start_body}
    ;;
  stop)
${rc_stop_body}
    ;;
  restart)
    "\$0" stop
    "\$0" start
    ;;
  *)
    echo "Usage: \$0 {start|stop|restart}"
    exit 1
    ;;
esac
EOF
  run_root chmod +x "$rc_script"
  if [[ "$IS_UNRAID" == true && -d /boot/config ]]; then
    # Unraid's rootfs lives in RAM; persist scripts on the USB flash drive via /boot/config/go
    local flash_dir="/boot/config/strata" flash_script="/boot/config/strata/rc.strata.${name}"
    run_root mkdir -p "$flash_dir"
    run_root cp "$rc_script" "$flash_script"
    run_root chmod +x "$flash_script" 2>/dev/null || true
    add_boot_hook "/boot/config/go" "# strata:${name}" "[ -f ${flash_script} ] && sh ${flash_script} start # strata:${name}" "#!/bin/bash"
  elif [[ "$IS_SYNOLOGY" == true && -d /usr/local/etc/rc.d ]]; then
    local syno_script="/usr/local/etc/rc.d/strata-${name}.sh"
    run_root cp "$rc_script" "$syno_script"
    run_root chmod +x "$syno_script"
  else
    add_boot_hook "${rc_dir}/rc.local" "# strata:${name}" "[ -x ${rc_script} ] && ${rc_script} start # strata:${name}" "#!/bin/sh"
    run_root chmod +x "${rc_dir}/rc.local"
  fi
  run_root "$rc_script" start
}

remove_service() {
  local unit="$1"
  [[ "${CHECK_ONLY:-false}" == true ]] && return 1
  if [[ "$HAS_SYSTEMD" == true ]]; then
    run_root systemctl disable --now "$unit" 2>/dev/null || true
    run_root rm -f "/etc/systemd/system/${unit}"
    run_root systemctl daemon-reload
    refresh_unit_files_cache
    return 0
  elif [[ "$HAS_LAUNCHD" == true ]]; then
    local scope label plist runner
    IFS='|' read -r scope label plist runner <<< "$(_launchd_meta "$unit")"
    service_ctl stop "$unit" >/dev/null 2>&1 || true
    if [[ "$scope" == "user" ]]; then
      run_as_user_exec rm -f "$plist" "$runner"
    else
      run_root rm -f "$plist" "$runner"
    fi
    return 0
  fi

  local name="${unit%.service}" rc_script
  if rc_script="$(resolve_rc_script "$unit")"; then
    run_root sh "$rc_script" stop >/dev/null 2>&1 || true
  fi
  run_root rm -f "${STRATA_RC_DIR:-/etc/rc.d}/rc.strata.${name}"
  if [[ "$IS_UNRAID" == true ]]; then
    run_root rm -f "/boot/config/strata/rc.strata.${name}"
    remove_boot_hook "/boot/config/go" "# strata:${name}"
  fi
  if [[ "$IS_SYNOLOGY" == true ]]; then
    run_root rm -f "/usr/local/etc/rc.d/strata-${name}.sh"
  fi
  remove_boot_hook "${STRATA_RC_DIR:-/etc/rc.d}/rc.local" "# strata:${name}"
}

pkg_installed() {
  local pkg="$1" rc=1
  [[ -n "${PKG_INST_CACHE[$pkg]+x}" ]] && return "${PKG_INST_CACHE[$pkg]}"
  case "$DISTRO_FAMILY" in
    arch)      pacman -Qi "$pkg" >/dev/null 2>&1 && rc=0 ;;
    fedora)    rpm -q "$pkg" >/dev/null 2>&1 && rc=0 ;;
    debian)    dpkg -s "$pkg" >/dev/null 2>&1 && rc=0 ;;
    suse)      rpm -q "$pkg" >/dev/null 2>&1 && rc=0 ;;
    slackware)
      if compgen -G "/var/lib/pkgtools/packages/${pkg}-[0-9]*" >/dev/null 2>&1 || compgen -G "/var/log/packages/${pkg}-[0-9]*" >/dev/null 2>&1; then
        rc=0
      fi
      ;;
    macos)     command -v brew >/dev/null 2>&1 && run_as_user_exec brew list --formula "$pkg" >/dev/null 2>&1 && rc=0 ;;
    *)         return 1 ;;
  esac
  PKG_INST_CACHE[$pkg]=$rc
  return "$rc"
}

pkg_available() {
  local mode="$1" pkg="$2" key="${1}:${2}" rc=1
  [[ -n "${PKG_AVAIL_CACHE[$key]+x}" ]] && return "${PKG_AVAIL_CACHE[$key]}"
  if pkg_installed "$pkg"; then
    rc=0
  else
    case "$DISTRO_FAMILY" in
      arch)
        if [[ "$mode" == "aur" ]]; then
          [[ -n "$AUR_HELPER" ]] && run_as_user_exec "$AUR_HELPER" -Si "$pkg" >/dev/null 2>&1 && rc=0
        else
          pacman -Si "$pkg" >/dev/null 2>&1 && rc=0
        fi
        ;;
      fedora)    [[ "$mode" == "repo" ]] && dnf info --available "$pkg" >/dev/null 2>&1 && rc=0 ;;
      debian)    [[ "$mode" == "repo" && ! ( "$IS_TRUENAS" == true && ! "$(command -v apt-get 2>/dev/null)" ) ]] && apt-cache show "$pkg" >/dev/null 2>&1 && rc=0 ;;
      suse)      [[ "$mode" == "repo" ]] && zypper --non-interactive info "$pkg" 2>/dev/null | grep -i "^Repository" >/dev/null && rc=0 ;;
      slackware)
        if [[ "$mode" == "repo" ]]; then
          if [[ -r /var/lib/slackpkg/pkglist ]]; then
            grep -qE "^[[:alnum:]_-]+[[:space:]]+${pkg}[[:space:]]" /var/lib/slackpkg/pkglist 2>/dev/null && rc=0
          elif command -v slackpkg >/dev/null 2>&1; then
            slackpkg search "^${pkg}$" 2>/dev/null | grep -qE "[[:space:]]${pkg}-" && rc=0
          fi
        fi
        ;;
      macos)
        [[ "$mode" == "repo" ]] && command -v brew >/dev/null 2>&1 && run_as_user_exec brew info "$pkg" >/dev/null 2>&1 && rc=0
        ;;
    esac
  fi
  PKG_AVAIL_CACHE[$key]=$rc
  return "$rc"
}

pkg_install() {
  local rc=0
  case "$DISTRO_FAMILY" in
    arch)      run_root pacman -S --needed --noconfirm "$@" || rc=$? ;;
    fedora)    run_root dnf install -y "$@" || rc=$? ;;
    debian)
      if [[ "$IS_TRUENAS" == true ]] && ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${C_YELLOW}TrueNAS SCALE appliance mode restricts apt; skipping package install ($*).${C_RESET}"; return 1
      fi
      run_root apt-get update -qq && run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" || rc=$?
      ;;
    suse)      run_root zypper --non-interactive install "$@" || rc=$? ;;
    slackware)
      if command -v slackpkg >/dev/null 2>&1; then
        run_root slackpkg -batch=on -default_answer=y install "$@" || rc=$?
      else
        echo -e "${C_RED}slackpkg not found; please install manually: $*${C_RESET}"; return 1
      fi
      ;;
    macos)
      if command -v brew >/dev/null 2>&1; then
        run_as_user_exec brew install "$@" || rc=$?
      else
        echo -e "${C_RED}Homebrew (brew) not found; please install manually: $*${C_RESET}"; return 1
      fi
      ;;
    *)         echo -e "${C_RED}Unsupported package manager.${C_RESET}"; return 1 ;;
  esac
  PKG_INST_CACHE=()
  refresh_unit_files_cache
  return "$rc"
}

aur_install() {
  [[ "$DISTRO_FAMILY" == "arch" && -n "$AUR_HELPER" ]] || {
    echo -e "${C_YELLOW}AUR helper (yay/paru) unavailable; please install: $*${C_RESET}"
    return 1
  }
  local rc=0
  run_as_user_exec "$AUR_HELPER" -S --needed --noconfirm "$@" || rc=$?
  PKG_INST_CACHE=()
  refresh_unit_files_cache
  return "$rc"
}

confirm_yn() {
  local prompt="$1" default="${2:-N}" ans
  read -r -p "$prompt" ans || return 1
  [[ -z "$ans" ]] && ans="$default"
  case "$ans" in
    y|Y|yes|YES|Yes) return 0 ;;
    n|N|no|NO|No)    return 1 ;;
    *)               echo -e "${C_RED}Invalid input '${ans}'. Cancelled.${C_RESET}"; return 1 ;;
  esac
}

prompt_install_deps() {
  local mode="$1"; shift
  local missing=() pkg
  for pkg in "$@"; do pkg_installed "$pkg" || missing+=("$pkg"); done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  echo -e "${C_YELLOW}Missing dependencies for this step: ${C_BOLD}${missing[*]}${C_RESET}"
  if ! confirm_yn "Install missing dependencies now? [Y/n]: " "Y"; then
    echo -e "${C_DIM}Skipped dependency installation.${C_RESET}"
    return 1
  fi
  if [[ "$mode" == "aur" ]]; then
    aur_install "${missing[@]}"
  else
    pkg_install "${missing[@]}"
  fi
}

prompt_install_repo_or_aur() {
  local pkg="$1"
  if pkg_available repo "$pkg"; then
    prompt_install_deps repo "$@"
  elif [[ "$DISTRO_FAMILY" == "arch" ]] && pkg_available aur "$pkg"; then
    prompt_install_deps aur "$@"
  else
    return 1
  fi
}

bls_entries_dir() {
  local br="${STRATA_BOOT_ROOT:-}" d
  for d in "${br}/boot/loader/entries" "${br}/efi/loader/entries" "${br}/boot/efi/loader/entries"; do
    compgen -G "$d/*.conf" >/dev/null 2>&1 && { echo "$d"; return 0; }
  done
  return 1
}

_kernel_param_files() {
  local br="${STRATA_BOOT_ROOT:-}"
  printf '%s\n' \
    "${br}/etc/default/limine" \
    "${br}/etc/default/grub" \
    "${br}/etc/kernel/cmdline" \
    "${br}/boot/refind_linux.conf" \
    "${br}"/boot/loader/entries/*.conf \
    "${br}"/efi/loader/entries/*.conf \
    "${br}"/boot/efi/loader/entries/*.conf \
    "${br}/boot/efi/EFI/Slackware/elilo.conf" \
    "${br}/etc/elilo.conf" \
    "${br}/etc/lilo.conf"
}

_escape_ere() {
  printf '%s' "$1" | sed 's/[][(){}.+*?^$|\\]/\\&/g'
}

_file_has_kparam() {
  local param="$1" file="$2" esc
  [[ -r "$file" ]] || return 1
  esc="$(_escape_ere "$param")"
  grep -Ev '^[[:space:]]*#' "$file" 2>/dev/null | grep -E "(^|[[:space:]\"'])${esc}([[:space:]\"']|\$)" >/dev/null
}

_remove_kparam_from_file() {
  local param="$1" file="$2"
  [[ -f "$file" ]] || return 0
  if command -v python3 >/dev/null 2>&1; then
    run_root python3 - "$file" "$param" <<'PYEOF'
import re, sys
p, tok = sys.argv[1], sys.argv[2]
with open(p) as f:
    txt = f.read()
pat = re.compile(r'(?:(?<=^)|(?<=[\s"\']))' + re.escape(tok) + r'(?=$|[\s"\'])')
out = []
for ln in txt.splitlines(True):
    if ln.lstrip().startswith('#'):
        out.append(ln)
        continue
    nl = pat.sub('', ln)
    if nl != ln:
        nl = re.sub(r' {2,}', ' ', nl)
        nl = re.sub(r'=(["\']) ', r'=\1', nl)
        nl = re.sub(r' (["\'])(?=\s|$)', r'\1', nl)
    out.append(nl)
new_txt = ''.join(out)
if new_txt != txt:
    with open(p, 'w') as f:
        f.write(new_txt)
PYEOF
  else
    local esc
    esc="$(printf '%s' "$param" | sed 's/[.[\*^$()+?{|/\\]/\\&/g')"
    run_root sed -i -E "/^[[:space:]]*#/!{s/(^|[[:space:]\"'])${esc}([[:space:]\"']|\$)/\1\2/g; s/  +/ /g; s/=\" /=\"/g; s/ \"/\"/g}" "$file"
  fi
}

_append_kparam_to_cmdline_file() {
  local file="$1"; shift
  local -a pending=()
  local p
  for p in "$@"; do
    _file_has_kparam "$p" "$file" || pending+=("$p")
  done
  (( ${#pending[@]} > 0 )) || return 1
  local joined="${pending[*]}"
  if [[ ! -s "$file" ]] || ! grep -qv '^[[:space:]]*$' "$file" 2>/dev/null; then
    printf '%s\n' "$joined" | run_root tee "$file" >/dev/null
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    run_root python3 - "$file" "$joined" <<'PYEOF'
import sys
p, add = sys.argv[1], sys.argv[2]
with open(p) as f:
    lines = f.read().splitlines(True)
out = []
done = False
for ln in lines:
    if not done and ln.strip() and not ln.lstrip().startswith('#'):
        nl = "\n" if ln.endswith("\n") else ""
        out.append(ln.rstrip("\r\n") + " " + add + nl)
        done = True
    else:
        out.append(ln)
if not done:
    out.append(add + "\n")
with open(p, 'w') as f:
    f.writelines(out)
PYEOF
  else
    local esc_j
    esc_j="$(printf '%s' "$joined" | sed 's/[&/\\]/\\&/g')"
    run_root sed -i "0,/^[[:space:]]*[^#[:space:]]/{s/[[:space:]]*$/ ${esc_j}/; s/^[[:space:]]*//}" "$file"
  fi
  return 0
}

_append_kparam_to_refind_file() {
  local file="$1"; shift
  local -a pending=()
  local p
  for p in "$@"; do
    _file_has_kparam "$p" "$file" || pending+=("$p")
  done
  (( ${#pending[@]} > 0 )) || return 1
  local joined="${pending[*]}"
  if command -v python3 >/dev/null 2>&1; then
    run_root python3 - "$file" "$joined" <<'PYEOF'
import re, sys
p, add = sys.argv[1], sys.argv[2]
with open(p) as f:
    lines = f.read().splitlines(True)
out = []
done = False
for ln in lines:
    if not done and not ln.lstrip().startswith('#') and re.search(r'"\s*$', ln):
        out.append(re.sub(r'"(\s*)$', f' {add}"\\1', ln, count=1))
        done = True
    else:
        out.append(ln)
with open(p, 'w') as f:
    f.writelines(out)
PYEOF
  else
    local esc_j
    esc_j="$(printf '%s' "$joined" | sed 's/[&/\\]/\\&/g')"
    run_root sed -i -E "0,/^[[:space:]]*[^#[:space:]].*\"[[:space:]]*$/{s/\"[[:space:]]*$/ ${esc_j}\"/}" "$file"
  fi
  return 0
}

has_kernel_param() {
  local param="$1" f br="${STRATA_BOOT_ROOT:-}"
  _file_has_kparam "$param" "${br}/proc/cmdline" && return 0
  while IFS= read -r f; do
    _file_has_kparam "$param" "$f" && return 0
  done < <(_kernel_param_files)
  return 1
}

add_kernel_param() {
  local br="${STRATA_BOOT_ROOT:-}"
  local -a params=() missing=()
  local param bls_dir=""
  for param in "$@"; do
    [[ -n "$param" ]] || continue
    _file_has_kparam "$param" "${br}/proc/cmdline" || params+=("$param")
  done
  (( ${#params[@]} > 0 )) || return 0

  if [[ "$DISTRO_FAMILY" == "fedora" || "$DISTRO_FAMILY" == "suse" ]] && command -v grubby >/dev/null 2>&1 && [[ ! -f "${br}/etc/default/limine" ]]; then
    run_root grubby --update-kernel=ALL --args="${params[*]}" || true
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${params[*]}' via grubby (reboot required).${C_RESET}"
    return 0
  fi

  if [[ -f "${br}/etc/default/limine" ]]; then
    missing=()
    for param in "${params[@]}"; do
      _file_has_kparam "$param" "${br}/etc/default/limine" || missing+=("$param")
    done
    if (( ${#missing[@]} > 0 )); then
      local joined="${missing[*]}" esc_j
      esc_j="$(printf '%s' "$joined" | sed 's/[&/\\]/\\&/g')"
      if grep -qE '^KERNEL_CMDLINE\[default\]\+?="' "${br}/etc/default/limine"; then
        run_root sed -i "s/\(KERNEL_CMDLINE\[default\]+\{0,1\}=\"[^\"]*\)\"/\1 ${esc_j}\"/" "${br}/etc/default/limine"
        run_root sed -i 's/KERNEL_CMDLINE\[default\]\(+\{0,1\}\)=\" /KERNEL_CMDLINE[default]\1=\"/' "${br}/etc/default/limine"
      else
        echo "KERNEL_CMDLINE[default]+=\"${joined}\"" | run_root tee -a "${br}/etc/default/limine" >/dev/null
      fi
      command -v limine-mkinitcpio >/dev/null 2>&1 && run_root limine-mkinitcpio || true
    fi
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${params[*]}' to ${br}/etc/default/limine (reboot required).${C_RESET}"
  elif [[ -f "${br}/etc/default/grub" ]]; then
    missing=()
    for param in "${params[@]}"; do
      _file_has_kparam "$param" "${br}/etc/default/grub" || missing+=("$param")
    done
    if (( ${#missing[@]} > 0 )); then
      local joined="${missing[*]}" esc_j
      esc_j="$(printf '%s' "$joined" | sed 's/[&/\\]/\\&/g')"
      if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT="' "${br}/etc/default/grub"; then
        run_root sed -i "s/\(^GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 ${esc_j}\"/" "${br}/etc/default/grub"
        run_root sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=\" /GRUB_CMDLINE_LINUX_DEFAULT=\"/' "${br}/etc/default/grub"
      elif grep -qE "^GRUB_CMDLINE_LINUX_DEFAULT='" "${br}/etc/default/grub"; then
        run_root sed -i "s/\(^GRUB_CMDLINE_LINUX_DEFAULT='[^']*\)'/\1 ${esc_j}'/" "${br}/etc/default/grub"
        run_root sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=' /GRUB_CMDLINE_LINUX_DEFAULT='/" "${br}/etc/default/grub"
      elif grep -qE '^GRUB_CMDLINE_LINUX="' "${br}/etc/default/grub"; then
        run_root sed -i "s/\(^GRUB_CMDLINE_LINUX=\"[^\"]*\)\"/\1 ${esc_j}\"/" "${br}/etc/default/grub"
        run_root sed -i 's/^GRUB_CMDLINE_LINUX=\" /GRUB_CMDLINE_LINUX=\"/' "${br}/etc/default/grub"
      else
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${joined}\"" | run_root tee -a "${br}/etc/default/grub" >/dev/null
      fi
      if command -v grub-mkconfig >/dev/null 2>&1; then
        run_root grub-mkconfig -o "${br}/boot/grub/grub.cfg" || true
      elif command -v grub2-mkconfig >/dev/null 2>&1; then
        run_root grub2-mkconfig -o "${br}/boot/grub2/grub.cfg" || true
      fi
    fi
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${params[*]}' to ${br}/etc/default/grub (reboot required).${C_RESET}"
  elif [[ -f "${br}/etc/kernel/cmdline" ]] || bls_dir="$(bls_entries_dir)"; then
    local updated_sd=false
    if [[ -f "${br}/etc/kernel/cmdline" ]]; then
      if _append_kparam_to_cmdline_file "${br}/etc/kernel/cmdline" "${params[@]}"; then
        updated_sd=true
        if compgen -G "${br}/efi/EFI/Linux/*.efi" >/dev/null 2>&1 || compgen -G "${br}/boot/EFI/Linux/*.efi" >/dev/null 2>&1 || compgen -G "${br}/boot/efi/EFI/Linux/*.efi" >/dev/null 2>&1; then
          if command -v mkinitcpio >/dev/null 2>&1; then
            run_root mkinitcpio -P || true
          else
            echo -e "${C_YELLOW}Note: UKI image detected; rebuild your UKI (dracut/ukify/kernel-install) for /etc/kernel/cmdline changes to apply.${C_RESET}"
          fi
        fi
      fi
      echo -e "${C_GREEN}Added '${params[*]}' to ${br}/etc/kernel/cmdline (reboot required).${C_RESET}"
    fi
    if [[ -n "$bls_dir" ]] || bls_dir="$(bls_entries_dir)"; then
      local f
      for f in "$bls_dir"/*.conf; do
        [[ -f "$f" ]] || continue
        missing=()
        for param in "${params[@]}"; do
          _file_has_kparam "$param" "$f" || missing+=("$param")
        done
        if (( ${#missing[@]} > 0 )); then
          local joined="${missing[*]}" esc_j
          esc_j="$(printf '%s' "$joined" | sed 's/[&/\\]/\\&/g')"
          if grep -qE '^options[[:space:]]' "$f"; then
            run_root sed -i "s/^options .*/& ${esc_j}/" "$f"
          else
            echo "options ${joined}" | run_root tee -a "$f" >/dev/null
          fi
        fi
      done
      echo -e "${C_GREEN}Added '${params[*]}' to systemd-boot entries in ${bls_dir} (reboot required).${C_RESET}"
    fi
    [[ "$updated_sd" == true ]] && command -v bootctl >/dev/null 2>&1 && run_root bootctl update >/dev/null 2>&1 || true
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
  elif [[ -f "${br}/boot/refind_linux.conf" ]]; then
    _append_kparam_to_refind_file "${br}/boot/refind_linux.conf" "${params[@]}" || true
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${params[*]}' to ${br}/boot/refind_linux.conf (reboot required).${C_RESET}"
  elif [[ -f "${br}/boot/efi/EFI/Slackware/elilo.conf" || -f "${br}/etc/elilo.conf" ]]; then
    local elilo_f="${br}/boot/efi/EFI/Slackware/elilo.conf"
    [[ -f "$elilo_f" ]] || elilo_f="${br}/etc/elilo.conf"
    missing=()
    for param in "${params[@]}"; do
      _file_has_kparam "$param" "$elilo_f" || missing+=("$param")
    done
    if (( ${#missing[@]} > 0 )); then
      local joined="${missing[*]}" esc_j
      esc_j="$(printf '%s' "$joined" | sed 's/[&/\\]/\\&/g')"
      if grep -qE '^[[:space:]]*append="' "$elilo_f"; then
        run_root sed -i -E "s/^([[:space:]]*append=\"[^\"]*)\"/\1 ${esc_j}\"/" "$elilo_f"
        run_root sed -i -E 's/^([[:space:]]*append=") /\1/' "$elilo_f"
      else
        echo "append=\"${joined}\"" | run_root tee -a "$elilo_f" >/dev/null
      fi
    fi
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${params[*]}' to ${elilo_f} (reboot required).${C_RESET}"
  elif [[ -f "${br}/etc/lilo.conf" ]]; then
    missing=()
    for param in "${params[@]}"; do
      _file_has_kparam "$param" "${br}/etc/lilo.conf" || missing+=("$param")
    done
    if (( ${#missing[@]} > 0 )); then
      local joined="${missing[*]}" esc_j
      esc_j="$(printf '%s' "$joined" | sed 's/[&/\\]/\\&/g')"
      if grep -qE '^[[:space:]]*append="' "${br}/etc/lilo.conf"; then
        run_root sed -i -E "s/^([[:space:]]*append=\"[^\"]*)\"/\1 ${esc_j}\"/" "${br}/etc/lilo.conf"
        run_root sed -i -E 's/^([[:space:]]*append=") /\1/' "${br}/etc/lilo.conf"
      else
        echo "append=\"${joined}\"" | run_root tee -a "${br}/etc/lilo.conf" >/dev/null
      fi
      command -v lilo >/dev/null 2>&1 && run_root lilo || true
    fi
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${params[*]}' to ${br}/etc/lilo.conf (reboot required).${C_RESET}"
  else
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_YELLOW}Please add '${params[*]}' to your bootloader kernel command line manually.${C_RESET}"
  fi
}

remove_kernel_param() {
  local br="${STRATA_BOOT_ROOT:-}" changed=false
  local param ef limine_changed=false grub_changed=false cmdline_changed=false lilo_changed=false
  for param in "$@"; do
    [[ -n "$param" ]] || continue
    if _file_has_kparam "$param" "${br}/etc/default/limine"; then
      _remove_kparam_from_file "$param" "${br}/etc/default/limine"
      limine_changed=true changed=true
    fi
    if _file_has_kparam "$param" "${br}/etc/default/grub"; then
      _remove_kparam_from_file "$param" "${br}/etc/default/grub"
      grub_changed=true changed=true
    fi
    if _file_has_kparam "$param" "${br}/etc/kernel/cmdline"; then
      _remove_kparam_from_file "$param" "${br}/etc/kernel/cmdline"
      cmdline_changed=true changed=true
    fi
    if [[ "$DISTRO_FAMILY" == "fedora" || "$DISTRO_FAMILY" == "suse" ]] && command -v grubby >/dev/null 2>&1; then
      run_root grubby --update-kernel=ALL --remove-args="$param" >/dev/null 2>&1 && changed=true || true
    fi
    for ef in "${br}"/boot/loader/entries/*.conf "${br}"/efi/loader/entries/*.conf "${br}"/boot/efi/loader/entries/*.conf "${br}/boot/refind_linux.conf" "${br}/boot/efi/EFI/Slackware/elilo.conf" "${br}/etc/elilo.conf"; do
      if [[ -f "$ef" ]] && _file_has_kparam "$param" "$ef"; then
        _remove_kparam_from_file "$param" "$ef"
        changed=true
      fi
    done
    if _file_has_kparam "$param" "${br}/etc/lilo.conf"; then
      _remove_kparam_from_file "$param" "${br}/etc/lilo.conf"
      lilo_changed=true changed=true
    fi
  done
  if [[ "$limine_changed" == true ]]; then
    command -v limine-mkinitcpio >/dev/null 2>&1 && run_root limine-mkinitcpio || true
  fi
  if [[ "$grub_changed" == true ]]; then
    if command -v grub-mkconfig >/dev/null 2>&1; then
      run_root grub-mkconfig -o "${br}/boot/grub/grub.cfg" || true
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
      run_root grub2-mkconfig -o "${br}/boot/grub2/grub.cfg" || true
    fi
  fi
  if [[ "$cmdline_changed" == true ]]; then
    if compgen -G "${br}/efi/EFI/Linux/*.efi" >/dev/null 2>&1 || compgen -G "${br}/boot/EFI/Linux/*.efi" >/dev/null 2>&1 || compgen -G "${br}/boot/efi/EFI/Linux/*.efi" >/dev/null 2>&1; then
      command -v mkinitcpio >/dev/null 2>&1 && run_root mkinitcpio -P || true
    fi
    command -v bootctl >/dev/null 2>&1 && run_root bootctl update >/dev/null 2>&1 || true
  fi
  if [[ "$lilo_changed" == true ]]; then
    command -v lilo >/dev/null 2>&1 && run_root lilo || true
  fi
  if [[ "$changed" == true ]]; then
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
  fi
}

pause_prompt() { echo ""; read -r -p "Press [Enter] to continue..." _ || true; }

prompt_reboot_if_needed() {
  [[ "$REBOOT_PROMPT_PENDING" == true ]] || return 0
  REBOOT_PROMPT_PENDING=false
  echo -e "\n${C_YELLOW}[REBOOT REQUIRED] A reboot is required to activate all changes.${C_RESET}"
  if confirm_yn "Reboot this system now? [y/N]: " "N"; then
    if [[ "$HAS_SYSTEMD" == true ]]; then
      run_root systemctl reboot
    else
      run_root reboot
    fi
    exit 0
  fi
}

# ------------------------------------------------------------------------------
# Hardware & Environment Detection
# ------------------------------------------------------------------------------
detect_ram_details() {
  local ddr_type="" ddr_speed="" ddr_cl=""
  if command -v python3 >/dev/null 2>&1; then
    local spd_info
    spd_info="$(python3 -c '
import glob, math, struct
for p in glob.glob("/sys/bus/i2c/drivers/ee1004/*/eeprom") + glob.glob("/sys/bus/i2c/drivers/spd5118/*/eeprom"):
    try: b = open(p, "rb").read(128)
    except Exception: continue
    if len(b) >= 126 and b[2] == 0x0C:
        ftb = lambda x: struct.unpack("b", bytes([x]))[0] * 0.001
        tck = b[18] * 0.125 + ftb(b[125])
        taa = b[24] * 0.125 + ftb(b[123])
        if tck > 0 and taa > 0:
            print(f"DDR4|{round(2000.0 / tck)}|CL{math.ceil(taa / tck - 1e-6)}"); break
    elif len(b) >= 32 and b[2] == 0x12:
        tck_ps = int.from_bytes(b[20:22], "little")
        taa_ps = int.from_bytes(b[30:32], "little")
        if tck_ps > 0 and taa_ps > 0:
            print(f"DDR5|{round(2000000.0 / tck_ps)}|CL{math.ceil(taa_ps / tck_ps - 1e-6)}"); break
' 2>/dev/null || true)"
    [[ -n "$spd_info" ]] && IFS='|' read -r ddr_type ddr_speed ddr_cl <<< "$spd_info"
  fi

  if [[ -z "$ddr_type" ]] && command -v decode-dimms >/dev/null 2>&1; then
    local dimms_out taa_ns
    dimms_out="$(decode-dimms 2>/dev/null || true)"
    if [[ -n "$dimms_out" ]]; then
      ddr_type="$(echo "$dimms_out" | awk -F'  +' '/Fundamental Memory [Tt]ype/ {print $2; exit}' | awk '{print $1}')"
      ddr_speed="$(echo "$dimms_out" | awk '/Maximum module speed/ {for(i=1;i<=NF;i++) if($i~/^[0-9]+$/ && $(i+1)=="MT/s") {print $i; exit}}')"
      taa_ns="$(echo "$dimms_out" | awk '/Minimum CAS Latency Time \(tAA\)/ {for(i=1;i<=NF;i++) if($i~/^[0-9.]+$/ && $(i+1)=="ns") {print $i; exit}}')"
      [[ -n "$taa_ns" && -n "$ddr_speed" ]] && ddr_cl="$(awk -v taa="$taa_ns" -v spd="$ddr_speed" 'BEGIN {cl=(taa*spd)/2000.0; printf "CL%d",(cl==int(cl)?cl:int(cl)+1)}')"
    fi
  fi

  if [[ -z "$ddr_type" || -z "$ddr_speed" ]] && [[ -n "$DMI_MEM_CACHE" ]]; then
    [[ -z "$ddr_type" ]] && ddr_type="$(awk -F': ' '/^\tType: (DDR|LPDDR)/ {print $2; exit}' <<<"$DMI_MEM_CACHE")"
    [[ -z "$ddr_speed" ]] && ddr_speed="$(awk -F': ' '/^\tConfigured Memory Speed: [0-9]+/ {print $2; exit}' <<<"$DMI_MEM_CACHE" | awk '{print $1}')"
  fi

  local parts=()
  [[ -n "$ddr_type" ]] && parts+=("$ddr_type")
  [[ -n "$ddr_speed" ]] && parts+=("${ddr_speed} MT/s")
  [[ -n "$ddr_cl" ]] && parts+=("$ddr_cl")
  [[ ${#parts[@]} -gt 0 ]] && RAM_DETAILS=" (${parts[*]})" || RAM_DETAILS=""
}

_docker_ro() {
  [[ -S /var/run/docker.sock ]] && command -v docker >/dev/null 2>&1 || return 1
  local _to=()
  if command -v timeout >/dev/null 2>&1; then
    _to=(timeout 3)
  elif command -v gtimeout >/dev/null 2>&1; then
    _to=(gtimeout 3)
  fi
  if [[ $EUID -eq 0 || ( -r /var/run/docker.sock && -w /var/run/docker.sock ) ]]; then
    "${_to[@]}" docker "$@" 2>/dev/null
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n "${_to[@]}" docker "$@" 2>/dev/null
  else
    return 1
  fi
}

detect_jetson_platform() {
  IS_JETSON=false IS_JETSON_TX2=false IS_JETSON_XAVIER=false IS_JETSON_ORIN=false IS_JETSON_THOR=false
  JETSON_MODEL="" JETSON_L4T_REL="" JETSON_SOC=""
  local dt_dir="${STRATA_DT_DIR:-/proc/device-tree}" dt_model="" dt_compat="" tegra_rel=""
  [[ -r "$dt_dir/model" ]] && dt_model="$(tr -d '\0' < "$dt_dir/model" 2>/dev/null || true)"
  [[ -r "$dt_dir/compatible" ]] && dt_compat="$(tr '\0' ' ' < "$dt_dir/compatible" 2>/dev/null || true)"
  [[ -r /etc/nv_tegra_release ]] && tegra_rel="$(head -n1 /etc/nv_tegra_release 2>/dev/null || true)"

  if [[ -n "$tegra_rel" ]] || grep -qiE "jetson|tegra" <<< "${dt_model} ${dt_compat}"; then
    IS_JETSON=true
  else
    return 0
  fi

  if [[ -n "$tegra_rel" ]]; then
    local l4t_maj="" l4t_rev=""
    l4t_maj="$(sed -nE 's/.*# *R([0-9]+).*/\1/p' <<< "$tegra_rel")"
    l4t_rev="$(sed -nE 's/.*REVISION: *([0-9.]+).*/\1/p' <<< "$tegra_rel")"
    if [[ -n "$l4t_maj" && -n "$l4t_rev" ]]; then
      JETSON_L4T_REL="R${l4t_maj}.${l4t_rev}"
    elif [[ -n "$l4t_maj" ]]; then
      JETSON_L4T_REL="R${l4t_maj}"
    fi
  fi

  JETSON_MODEL="${dt_model:-NVIDIA Jetson}"
  if grep -qi "nvidia,tegra264" <<< "$dt_compat" || grep -qiE "t264ref|t264" <<< "$tegra_rel" || grep -qi "Thor" <<< "$dt_model"; then
    IS_JETSON_THOR=true
    JETSON_SOC="tegra264"
    [[ -z "$dt_model" ]] && JETSON_MODEL="NVIDIA Jetson AGX Thor"
  elif grep -qi "nvidia,tegra234" <<< "$dt_compat" || grep -qiE "t234ref|t234" <<< "$tegra_rel" || grep -qi "Orin" <<< "$dt_model"; then
    IS_JETSON_ORIN=true
    JETSON_SOC="tegra234"
    [[ -z "$dt_model" ]] && JETSON_MODEL="NVIDIA Jetson Orin"
  elif grep -qi "nvidia,tegra194" <<< "$dt_compat" || grep -qiE "t194ref|t194" <<< "$tegra_rel" || grep -qiE "Xavier|galen|jakku" <<< "$dt_model"; then
    IS_JETSON_XAVIER=true
    JETSON_SOC="tegra194"
    [[ -z "$dt_model" ]] && JETSON_MODEL="NVIDIA Jetson Xavier"
  elif grep -qi "nvidia,tegra186" <<< "$dt_compat" || grep -qiE "t186ref|t186" <<< "$tegra_rel" || grep -qiE "TX2|quill|storm|lanai" <<< "$dt_model"; then
    IS_JETSON_TX2=true
    JETSON_SOC="tegra186"
    if [[ -z "$dt_model" || "$dt_model" =~ ^(quill|storm|lanai|p2771|p3636) ]]; then
      JETSON_MODEL="NVIDIA Jetson TX2"
    fi
  fi
}

_array_contains_val() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

amd_gfx_has_prebuilt() {
  case "$1" in
    gfx1200|gfx1201|gfx1100|gfx1101|gfx1102|gfx1030|gfx1031|gfx1032|gfx1151) return 0 ;;
    *) return 1 ;;
  esac
}

amd_gfx_is_wave64() {
  case "$1" in
    gfx906|gfx908|gfx90a|gfx942|gfx950) return 0 ;;
    *) return 1 ;;
  esac
}

amd_gfx_is_missing_target() {
  amd_gfx_has_prebuilt "$1" && return 1
  case "$1" in
    gfx1036) return 1 ;; # 2-CU Raphael/Granite Ridge desktop display iGPU
    gfx101[0-9a-f]|gfx103[0-9a-f]|gfx110[0-9a-f]|gfx115[0-9a-f]|gfx120[0-9a-f]|gfx906|gfx908|gfx90a|gfx942|gfx950) return 0 ;;
    *) return 1 ;;
  esac
}

_is_amd_compute_apu_gfx() {
  case "$1" in
    gfx115[0-9a-f]|gfx1103|gfx1033|gfx1035|gfx1037|gfx90c|gfx902|gfx909) return 0 ;;
    *) return 1 ;;
  esac
}

amd_has_gfx() {
  (( ${#AMD_GFX_ARCHS[@]} > 0 )) && _array_contains_val "$1" "${AMD_GFX_ARCHS[@]}"
}

amd_missing_has_gfx() {
  (( ${#AMD_MISSING_GFX_ARCHS[@]} > 0 )) && _array_contains_val "$1" "${AMD_MISSING_GFX_ARCHS[@]}"
}

_fill_strata_runtime_env_array() {
  local -n _out_env="$1"
  _out_env=()
  local _ag _has_1150=false _has_1103=false
  if (( ${#AMD_MISSING_GFX_ARCHS[@]} > 0 )); then
    for _ag in "${AMD_MISSING_GFX_ARCHS[@]}"; do
      case "$_ag" in
        gfx1150) [[ "$_has_1150" == false ]] && { _out_env+=("STRATA_EXPERIMENTAL_GFX1150=1"); _has_1150=true; } ;;
        gfx1103) [[ "$_has_1103" == false ]] && { _out_env+=("STRATA_EXPERIMENTAL_GFX1103=1"); _has_1103=true; } ;;
      esac
    done
  fi
  [[ -f "$NVIDIA_SM70_MARKER" ]] && _out_env+=("STRATA_SM70_TABLE=1")
  if [[ "$IS_MACOS" == true && -r "$MACOS_METAL_ENV_FILE" ]]; then
    local _mline=""
    while IFS= read -r _mline; do
      [[ "$_mline" =~ ^STRATA_[A-Z0-9_]+=[^\;[:space:]]+$ ]] && _out_env+=("$_mline")
    done < "$MACOS_METAL_ENV_FILE"
  fi
}

strata_runtime_env_list() {
  local -a _rt_env=()
  _fill_strata_runtime_env_array _rt_env
  (( ${#_rt_env[@]} > 0 )) && printf '%s\n' "${_rt_env[@]}"
  return 0
}

amd_gfx_label() {
  case "$1" in
    gfx1150) echo "Radeon 890M / 880M (Strix Point APU)" ;;
    gfx1151) echo "Radeon 8060S / 8050S (Strix Halo APU)" ;;
    gfx1152) echo "Radeon 860M / 840M (Krackan Point APU)" ;;
    gfx1153) echo "Radeon APU (RDNA 3.5)" ;;
    gfx1103) echo "Radeon 780M / 760M / 740M (Phoenix / Hawk Point APU)" ;;
    gfx1010) echo "Radeon RX 5700 / 5600 (RDNA1)" ;;
    gfx1011) echo "Radeon Pro V520 / 5600M (RDNA1)" ;;
    gfx1012) echo "Radeon RX 5500 (RDNA1)" ;;
    gfx1033) echo "Radeon Graphics (Van Gogh APU)" ;;
    gfx1034) echo "Radeon RX 6500 XT / 6400 (RDNA2)" ;;
    gfx906)  echo "Instinct MI50 / MI60 / Radeon VII (Vega 20 wave64)" ;;
    gfx908)  echo "Instinct MI100 (CDNA 1 wave64)" ;;
    gfx90a)  echo "Instinct MI210 / MI250 / MI250X (CDNA 2 wave64)" ;;
    gfx942)  echo "Instinct MI300X / MI300A / MI325X (CDNA 3 wave64)" ;;
    gfx950)  echo "Instinct MI350X / MI355X (CDNA 4 wave64)" ;;
    gfx1201) echo "Radeon RX 9070 / AI PRO R9700 (RDNA4)" ;;
    gfx1200) echo "Radeon RX 9060 (RDNA4)" ;;
    gfx1100) echo "Radeon RX 7900 / W7900 (RDNA3)" ;;
    gfx1101) echo "Radeon RX 7800 / 7700 (RDNA3)" ;;
    gfx1102) echo "Radeon RX 7600 (RDNA3)" ;;
    gfx1030) echo "Radeon RX 6900 / 6800 (RDNA2)" ;;
    gfx1031) echo "Radeon RX 6700 XT (RDNA2)" ;;
    gfx1032) echo "Radeon RX 6600 (RDNA2)" ;;
    gfx1035) echo "Radeon 680M / 660M (Rembrandt APU)" ;;
    gfx1036) echo "Radeon Graphics (Raphael / Granite Ridge iGPU)" ;;
    gfx1037) echo "Radeon 610M (Mendocino APU)" ;;
    gfx90c)  echo "Radeon Vega iGPU (Cezanne / Renoir APU)" ;;
    gfx902)  echo "Radeon Vega iGPU (Raven Ridge / Picasso APU)" ;;
    gfx909)  echo "Radeon Vega iGPU (Renoir / Picasso APU)" ;;
    *)       echo "AMD Radeon ($1)" ;;
  esac
}

amd_gfx_therock_family() {
  case "$1" in
    gfx115[0-9a-f]) echo "$1" ;;
    gfx110[0-9a-f]) echo "gfx110X-all" ;;
    gfx103[0-9a-f]) echo "gfx103X-all" ;;
    gfx101[0-9a-f]) echo "gfx101X-dgpu" ;;
    gfx120[0-9a-f]) echo "gfx120X-all" ;;
    gfx125[0-9a-f]) echo "gfx125X-dcgpu" ;;
    gfx94[0-9a-f])  echo "gfx94X-dcgpu" ;;
    gfx95[0-9a-f])  echo "gfx950-dcgpu" ;;
    *) return 1 ;;
  esac
}

amd_gfx_from_pci_id() {
  case "${1,,}" in
    0x150e) echo "gfx1150" ;;
    0x1586) echo "gfx1151" ;;
    0x1114|0x1902) echo "gfx1152" ;;
    0x15bf|0x15c8|0x164f|0x1900|0x1901) echo "gfx1103" ;;
    0x7550|0x7551) echo "gfx1201" ;;
    0x7590) echo "gfx1200" ;;
    0x744c|0x7448|0x745e) echo "gfx1100" ;;
    0x747e) echo "gfx1101" ;;
    0x7480) echo "gfx1102" ;;
    0x73bf|0x73af|0x73a5|0x73a1) echo "gfx1030" ;;
    0x73df) echo "gfx1031" ;;
    0x73ff|0x73ef|0x73e3) echo "gfx1032" ;;
    0x163f) echo "gfx1033" ;;
    0x743f|0x7422|0x7423|0x7424) echo "gfx1034" ;;
    0x1681) echo "gfx1035" ;;
    0x164e|0x13c0) echo "gfx1036" ;;
    0x1506) echo "gfx1037" ;;
    0x1638|0x1636) echo "gfx90c" ;;
    0x731f|0x7310|0x7312|0x7318|0x7319|0x731a|0x731b|0x731e) echo "gfx1010" ;;
    0x7360|0x7362) echo "gfx1011" ;;
    0x7340|0x7341|0x7347|0x734f) echo "gfx1012" ;;
    0x66a0|0x66a1|0x66a2|0x66a3|0x66a7|0x66af) echo "gfx906" ;;
    0x738c|0x738e) echo "gfx908" ;;
    0x7408|0x740c|0x740f|0x7410) echo "gfx90a" ;;
    0x74a0|0x74a1|0x74a2|0x74a5|0x74a9|0x74b5|0x74b9|0x74bd) echo "gfx942" ;;
    0x75a0|0x75a3) echo "gfx950" ;;
    *) return 1 ;;
  esac
}

_is_amd_apu_pci_id() {
  case "${1,,}" in
    0x1586|0x150e|0x1114|0x1902|0x15bf|0x15c8|0x164f|0x1900|0x1901|0x163f|0x1681|0x1506|0x1638|0x1636|0x15d8|0x15e7) return 0 ;;
    *) return 1 ;;
  esac
}

_is_drm_card_amd_apu() {
  local dev_dir="$1" ven="" did="" gfx="" vt="" gt=""
  [[ -d "$dev_dir" ]] || return 1
  if [[ -r "$dev_dir/vendor" ]]; then
    ven="$(tr '[:upper:]' '[:lower:]' < "$dev_dir/vendor" 2>/dev/null || true)"
    [[ "$ven" == "0x1002" ]] || return 1
  fi
  if [[ -r "$dev_dir/device" ]]; then
    did="$(tr '[:upper:]' '[:lower:]' < "$dev_dir/device" 2>/dev/null || true)"
    if [[ "$did" =~ ^0x[0-9a-f]+$ ]]; then
      _is_amd_apu_pci_id "$did" && return 0
      gfx="$(amd_gfx_from_pci_id "$did" || true)"
      if [[ -n "$gfx" ]]; then
        _is_amd_compute_apu_gfx "$gfx" && return 0
        [[ "$gfx" == "gfx1036" && "$HAS_AMD_APU" == true ]] && return 0
        return 1
      fi
    fi
  fi
  [[ "$HAS_AMD_APU" == true ]] || return 1
  [[ -r "$dev_dir/mem_info_vram_total" && -r "$dev_dir/mem_info_gtt_total" ]] || return 1
  vt="$(cat "$dev_dir/mem_info_vram_total" 2>/dev/null || echo 0)"
  gt="$(cat "$dev_dir/mem_info_gtt_total" 2>/dev/null || echo 0)"
  [[ "$vt" =~ ^[0-9]+$ && "$gt" =~ ^[0-9]+$ ]] || return 1
  (( vt == 0 || (vt <= 34359738368 && gt > vt) ))
}

amd_gfx_from_name() {
  local name="$1"
  if grep -qiE '\b(8060S|8050S|8040S)\b|Strix Halo|Ryzen AI Max' <<<"$name"; then echo "gfx1151"
  elif grep -qiE '\b(890M|880M)\b|Strix Point' <<<"$name"; then echo "gfx1150"
  elif grep -qiE '\b(860M|840M)\b|Krackan' <<<"$name"; then echo "gfx1152"
  elif grep -qiE '\b(780M|760M|740M)\b|Phoenix|Hawk Point' <<<"$name"; then echo "gfx1103"
  elif grep -qiE '\b(680M|660M)\b|Rembrandt' <<<"$name"; then echo "gfx1035"
  elif grep -qiE '\b610M\b|Mendocino' <<<"$name"; then echo "gfx1037"
  elif grep -qiE 'Van Gogh' <<<"$name"; then echo "gfx1033"
  elif grep -qiE '\bRX 9070\b|\bR9700\b' <<<"$name"; then echo "gfx1201"
  elif grep -qiE '\bRX 9060\b' <<<"$name"; then echo "gfx1200"
  elif grep -qiE '\bRX 7900\b|\bW7[89]00\b' <<<"$name"; then echo "gfx1100"
  elif grep -qiE '\bRX 7[78]00\b' <<<"$name"; then echo "gfx1101"
  elif grep -qiE '\bRX 7600\b' <<<"$name"; then echo "gfx1102"
  elif grep -qiE '\bRX 6(800|900|950)\b|\bW6800\b' <<<"$name"; then echo "gfx1030"
  elif grep -qiE '\bRX 67[05]0\b' <<<"$name"; then echo "gfx1031"
  elif grep -qiE '\bRX 66[05]0\b|\bW6600\b' <<<"$name"; then echo "gfx1032"
  elif grep -qiE '\bRX 6(400|500)\b' <<<"$name"; then echo "gfx1034"
  elif grep -qiE '\bRX 5[67]00\b' <<<"$name"; then echo "gfx1010"
  elif grep -qiE 'Pro V520|\b5600M\b' <<<"$name"; then echo "gfx1011"
  elif grep -qiE '\bRX 5500\b' <<<"$name"; then echo "gfx1012"
  elif grep -qiE '\bMI50\b|\bMI60\b|Radeon VII' <<<"$name"; then echo "gfx906"
  elif grep -qiE '\bMI100\b' <<<"$name"; then echo "gfx908"
  elif grep -qiE '\bMI2(10|50X?)\b' <<<"$name"; then echo "gfx90a"
  elif grep -qiE '\bMI3(00[XA]?|25X)\b' <<<"$name"; then echo "gfx942"
  elif grep -qiE '\bMI35[05]X\b' <<<"$name"; then echo "gfx950"
  elif grep -qiE 'Raphael|Granite Ridge' <<<"$name"; then echo "gfx1036"
  else return 1; fi
}

_append_unique_amd_gfx() {
  local g="$1"
  [[ -n "$g" ]] || return 0
  if (( ${#AMD_GFX_ARCHS[@]} == 0 )) || ! _array_contains_val "$g" "${AMD_GFX_ARCHS[@]}"; then
    AMD_GFX_ARCHS+=("$g")
  fi
}

detect_amd_gfx_archs() {
  AMD_GFX_ARCHS=()
  AMD_MISSING_GFX_ARCHS=()
  AMD_GFX_SUMMARY=""
  AMD_MISSING_GFX_SUMMARY=""
  HAS_AMD_APU=false
  HAS_AMD_PREBUILT_GFX=false
  HAS_AMD_INSTINCT=false
  HAS_AMD_NON_INSTINCT=false
  AMD_GTT_TOTAL_MB=0

  local kfd_dir="${STRATA_KFD_NODES_DIR:-/sys/class/kfd/kfd/topology/nodes}"
  local drm_dir="${STRATA_DRM_DIR:-/sys/class/drm}"
  local pci_dir="${STRATA_PCI_DIR:-/sys/bus/pci/devices}"

  # 1. Primary probe: KFD sysfs topology
  if [[ -d "$kfd_dir" ]]; then
    local prop val n_dec gfx
    for prop in "$kfd_dir"/*/properties; do
      [[ -r "$prop" ]] || continue
      val="$(awk '$1 == "gfx_target_version" {print $2; exit}' "$prop" 2>/dev/null || true)"
      if [[ "$val" =~ ^[0-9]+$ ]] && (( 10#$val > 0 )); then
        n_dec=$(( 10#$val ))
        gfx="$(printf 'gfx%d%x%x' "$(( n_dec / 10000 ))" "$(( (n_dec / 100) % 100 ))" "$(( n_dec % 100 ))")"
        _append_unique_amd_gfx "$gfx"
      fi
    done
  fi

  # 2. Secondary probe: rocminfo
  if (( ${#AMD_GFX_ARCHS[@]} == 0 )) && command -v rocminfo >/dev/null 2>&1; then
    local r_out gfx
    r_out="$(rocminfo 2>/dev/null || true)"
    while IFS= read -r gfx; do
      _append_unique_amd_gfx "$gfx"
    done < <(awk '/^[[:space:]]*Name:[[:space:]]*gfx[0-9a-fA-F]+/ {print tolower($2)}' <<<"$r_out")
  fi

  # 3. Tertiary probe: PCI device IDs (sysfs DRM, sysfs PCI incl. class 0x1200, then lspci -nn)
  local card dev_p cls ven did gfx found_pci=false has_mi50_60_id=false has_r7_id=false
  if [[ -d "$drm_dir" ]]; then
    for card in "$drm_dir"/card[0-9]*; do
      [[ -e "$card" ]] || continue
      [[ "$(basename "$card")" == *-* ]] && continue
      ven="$(tr '[:upper:]' '[:lower:]' < "$card/device/vendor" 2>/dev/null || true)"
      [[ "$ven" == "0x1002" ]] || continue
      did="$(tr '[:upper:]' '[:lower:]' < "$card/device/device" 2>/dev/null || true)"
      [[ "$did" =~ ^0x[0-9a-f]+$ ]] || continue
      found_pci=true
      [[ "$did" =~ ^0x66a[0123]$ ]] && has_mi50_60_id=true
      [[ "$did" == "0x66af" || "$did" == "0x66a7" ]] && has_r7_id=true
      if (( ${#AMD_GFX_ARCHS[@]} == 0 )); then
        _is_amd_apu_pci_id "$did" && HAS_AMD_APU=true
        gfx="$(amd_gfx_from_pci_id "$did" || true)"
        _append_unique_amd_gfx "$gfx"
      fi
    done
  fi
  if [[ -d "$pci_dir" ]]; then
    for dev_p in "$pci_dir"/*; do
      [[ -d "$dev_p" ]] || continue
      ven="$(tr '[:upper:]' '[:lower:]' < "$dev_p/vendor" 2>/dev/null || true)"
      [[ "$ven" == "0x1002" ]] || continue
      cls="$(tr '[:upper:]' '[:lower:]' < "$dev_p/class" 2>/dev/null || true)"
      [[ "$cls" == 0x03* || "$cls" == 0x12* ]] || continue
      did="$(tr '[:upper:]' '[:lower:]' < "$dev_p/device" 2>/dev/null || true)"
      [[ "$did" =~ ^0x[0-9a-f]+$ ]] || continue
      found_pci=true
      [[ "$did" =~ ^0x66a[0123]$ ]] && has_mi50_60_id=true
      [[ "$did" == "0x66af" || "$did" == "0x66a7" ]] && has_r7_id=true
      if (( ${#AMD_GFX_ARCHS[@]} == 0 )); then
        _is_amd_apu_pci_id "$did" && HAS_AMD_APU=true
        gfx="$(amd_gfx_from_pci_id "$did" || true)"
        _append_unique_amd_gfx "$gfx"
      fi
    done
  fi
  if (( ${#AMD_GFX_ARCHS[@]} == 0 )) && [[ "$found_pci" == false ]] && command -v lspci >/dev/null 2>&1; then
    local lspci_nn l
    lspci_nn="$(lspci -nn 2>/dev/null | grep -iE "vga|3d|display|processing accelerators" || true)"
    while IFS= read -r l; do
      [[ -n "$l" ]] || continue
      if [[ "$l" =~ \[1002:([0-9a-fA-F]{4})\] ]]; then
        did="0x${BASH_REMATCH[1],,}"
        [[ "$did" =~ ^0x66a[0123]$ ]] && has_mi50_60_id=true
        [[ "$did" == "0x66af" || "$did" == "0x66a7" ]] && has_r7_id=true
        _is_amd_apu_pci_id "$did" && HAS_AMD_APU=true
        gfx="$(amd_gfx_from_pci_id "$did" || true)"
        _append_unique_amd_gfx "$gfx"
      fi
    done <<<"$lspci_nn"
  fi

  # 4. Quaternary probe: marketing name fallback from lspci
  if (( ${#AMD_GFX_ARCHS[@]} == 0 )) && [[ "$HAS_AMD" == true && -n "$GPU_RAW" ]]; then
    local gline gfx
    while IFS= read -r gline; do
      [[ -n "$gline" ]] || continue
      grep -qiE "\b(amd|ati|radeon|instinct)\b" <<<"$gline" || continue
      gfx="$(amd_gfx_from_name "$gline" || true)"
      _append_unique_amd_gfx "$gfx"
    done <<<"$GPU_RAW"
  fi

  # Ensure LXC / container KFD-only hosts still set HAS_AMD and GPU_SUMMARY
  if (( ${#AMD_GFX_ARCHS[@]} > 0 )); then
    HAS_AMD=true
    if [[ -z "$GPU_SUMMARY" || "$GPU_SUMMARY" == "Unknown" ]]; then
      local a sum="" lbl
      for a in "${AMD_GFX_ARCHS[@]}"; do
        lbl="AMD $(amd_gfx_label "$a") [$a]"
        sum="${sum:+${sum}; }${lbl}"
      done
      [[ -n "$sum" ]] && GPU_SUMMARY="$sum"
    fi
  fi

  # Classify detected architectures
  local a has_display_igpu=false
  if (( ${#AMD_GFX_ARCHS[@]} > 0 )); then
    for a in "${AMD_GFX_ARCHS[@]}"; do
      amd_gfx_has_prebuilt "$a" && HAS_AMD_PREBUILT_GFX=true
      if amd_gfx_is_missing_target "$a"; then
        if (( ${#AMD_MISSING_GFX_ARCHS[@]} == 0 )) || ! _array_contains_val "$a" "${AMD_MISSING_GFX_ARCHS[@]}"; then
          AMD_MISSING_GFX_ARCHS+=("$a")
        fi
      fi
      if _is_amd_compute_apu_gfx "$a"; then
        HAS_AMD_APU=true
        HAS_AMD_NON_INSTINCT=true
      elif [[ "$a" == "gfx1036" ]]; then
        has_display_igpu=true
      elif [[ "$a" == "gfx908" || "$a" == "gfx90a" || "$a" == "gfx942" || "$a" == "gfx950" ]]; then
        HAS_AMD_INSTINCT=true
      elif [[ "$a" == "gfx906" ]]; then
        if [[ "$has_mi50_60_id" == true ]] || grep -qiE "\bMI50\b|\bMI60\b|Instinct" <<<"${GPU_RAW:-$GPU_SUMMARY}"; then
          HAS_AMD_INSTINCT=true
        fi
        if [[ "$has_r7_id" == true ]] || grep -qi "Radeon VII" <<<"${GPU_RAW:-$GPU_SUMMARY}" || [[ "$HAS_AMD_INSTINCT" == false ]]; then
          HAS_AMD_NON_INSTINCT=true
        fi
      else
        HAS_AMD_NON_INSTINCT=true
      fi
    done
  elif [[ "$HAS_AMD" == true ]]; then
    if grep -qiE "Instinct|\bMI50\b|\bMI60\b|\bMI100\b|\bMI2(10|50X?)\b|\bMI3(00[XA]?|25X|5[05]X)\b" <<<"${GPU_RAW:-$GPU_SUMMARY}"; then
      HAS_AMD_INSTINCT=true
    else
      HAS_AMD_NON_INSTINCT=true
    fi
  fi

  if [[ "$HAS_AMD_APU" == false && "$HAS_NVIDIA" == false && "$HAS_INTEL_ARC" == false && "$HAS_AMD_PREBUILT_GFX" == false && ${#AMD_MISSING_GFX_ARCHS[@]} -eq 0 ]]; then
    if [[ "$has_display_igpu" == true ]]; then
      HAS_AMD_APU=true
    elif [[ "$HAS_AMD" == true && -n "$GPU_RAW" ]]; then
      grep -iE "AMD|ATI|Radeon" <<<"$GPU_RAW" | grep -qiE "Raphael|Granite Ridge|Radeon Graphics" && HAS_AMD_APU=true
    fi
  fi
  if [[ "$HAS_AMD_APU" == false && "$HAS_AMD" == true && -n "$GPU_RAW" ]]; then
    grep -iE "AMD|ATI|Radeon" <<<"$GPU_RAW" | grep -qiE "Strix|Phoenix|Hawk Point|Rembrandt|Barcelo|Cezanne|Renoir|Lucienne|Mendocino|Krackan|Kraken|Picasso|Raven|Van Gogh|Vega Series|Vega Mobile|Radeon [0-9]{3}M|Radeon 8[0-9]{2,3}S" && HAS_AMD_APU=true
  fi

  if (( ${#AMD_GFX_ARCHS[@]} > 0 )); then
    local IFS=,
    AMD_GFX_SUMMARY="${AMD_GFX_ARCHS[*]}"
  fi
  if (( ${#AMD_MISSING_GFX_ARCHS[@]} > 0 )); then
    local IFS=,
    AMD_MISSING_GFX_SUMMARY="${AMD_MISSING_GFX_ARCHS[*]}"
  fi

  # Record AMD APU GTT pool size across AMD DRM cards (shared system-RAM TTM pool: take max, not sum)
  if [[ "$HAS_AMD_APU" == true && -d "$drm_dir" ]]; then
    local gt gt_mb max_apu_gtt=0 max_any_gtt=0
    for card in "$drm_dir"/card[0-9]*; do
      [[ -e "$card" ]] || continue
      [[ "$(basename "$card")" == *-* ]] && continue
      [[ -r "$card/device/mem_info_gtt_total" ]] || continue
      if [[ -r "$card/device/vendor" ]]; then
        ven="$(tr '[:upper:]' '[:lower:]' < "$card/device/vendor" 2>/dev/null || true)"
        [[ "$ven" == "0x1002" ]] || continue
      fi
      gt="$(cat "$card/device/mem_info_gtt_total" 2>/dev/null || echo 0)"
      [[ "$gt" =~ ^[0-9]+$ ]] && (( gt > 0 )) || continue
      gt_mb=$(( gt / 1048576 ))
      (( gt_mb > max_any_gtt )) && max_any_gtt=$gt_mb
      if _is_drm_card_amd_apu "$card/device"; then
        (( gt_mb > max_apu_gtt )) && max_apu_gtt=$gt_mb
      fi
    done
    AMD_GTT_TOTAL_MB=$(( max_apu_gtt > 0 ? max_apu_gtt : max_any_gtt ))
  fi
}

PLATFORM_BASICS_DONE=false
detect_platform_basics() {
  [[ "$PLATFORM_BASICS_DONE" == true ]] && return 0
  PLATFORM_BASICS_DONE=true
  local host_os="${STRATA_OS_UNAME:-$(uname -s 2>/dev/null || echo Linux)}"
  local host_arch="${STRATA_ARCH_UNAME:-$(uname -m 2>/dev/null || echo unknown)}"
  if [[ "$host_os" == "Darwin" ]]; then
    IS_MACOS=true
    HAS_SYSTEMD=false
    HAS_LAUNCHD=true
    DISTRO_FAMILY="macos"
    DISTRO_ID="macos"
    MACOS_VER="${STRATA_MACOS_VER:-$(sw_vers -productVersion 2>/dev/null || true)}"
    MACOS_MAJOR="${MACOS_VER%%.*}"
    [[ "$MACOS_MAJOR" =~ ^[0-9]+$ ]] || MACOS_MAJOR=0
    OS_PRETTY="macOS ${MACOS_VER:-unknown}"
    KERNEL_VER="Darwin ${STRATA_KERNEL_VER:-$(uname -r 2>/dev/null || echo unknown)}"
    if [[ "$host_arch" == "arm64" || "$host_arch" == "aarch64" ]]; then
      IS_APPLE_SILICON=true
    else
      IS_APPLE_SILICON=false
    fi
    IS_VIRT=""
    local hv_vmm=""
    hv_vmm="${STRATA_MACOS_VM:-$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)}"
    [[ "$hv_vmm" == "1" ]] && IS_VIRT="apple-vm"
    refresh_unit_files_cache
    return 0
  fi

  IS_MACOS=false
  HAS_LAUNCHD=false
  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    HAS_SYSTEMD=true
  else
    HAS_SYSTEMD=false
  fi
  refresh_unit_files_cache
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    IS_VIRT="$(systemd-detect-virt 2>/dev/null || true)"
    [[ "$IS_VIRT" == "none" ]] && IS_VIRT=""
  elif grep -qiE "QEMU|KVM|VMware|VirtualBox|Xen|Bochs|Hyper-V" /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null; then
    IS_VIRT="vm"
  elif grep -q "^flags.*\bhypervisor\b" /proc/cpuinfo 2>/dev/null; then
    IS_VIRT="vm"
  fi
  detect_jetson_platform

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-$DISTRO_ID}"
    local id_like="${ID_LIKE:-}"
    if [[ "$DISTRO_ID" =~ ^(arch|cachyos|endeavouros|manjaro|garuda)$ ]] || [[ "$id_like" == *arch* ]]; then
      DISTRO_FAMILY="arch"
    elif [[ "$DISTRO_ID" =~ ^(fedora|nobara|rhel|centos|rocky|alma)$ ]] || [[ "$id_like" == *fedora* || "$id_like" == *rhel* ]]; then
      DISTRO_FAMILY="fedora"
    elif [[ "$DISTRO_ID" =~ ^(debian|ubuntu|pop|linuxmint|neon)$ ]] || [[ "$id_like" == *debian* || "$id_like" == *ubuntu* ]]; then
      DISTRO_FAMILY="debian"
    elif [[ "$DISTRO_ID" =~ ^(opensuse.*|sles|sled|suse)$ ]] || [[ "$id_like" == *suse* ]]; then
      DISTRO_FAMILY="suse"
    elif [[ "$DISTRO_ID" =~ ^(slackware|unraid)$ ]] || [[ "$id_like" == *slackware* ]]; then
      DISTRO_FAMILY="slackware"
    fi
  elif [[ -r /etc/slackware-version ]]; then
    DISTRO_ID="slackware"
    DISTRO_FAMILY="slackware"
    OS_PRETTY="$(cat /etc/slackware-version 2>/dev/null || echo "Slackware Linux")"
  fi

  if [[ -r /etc/unraid-version ]] || [[ "$DISTRO_ID" == "unraid" ]]; then
    IS_UNRAID=true
    DISTRO_FAMILY="slackware"
    HAS_SYSTEMD=false
    local unraid_ver=""
    if [[ -r /etc/unraid-version ]]; then
      unraid_ver="$(sed -n 's/.*version="\([^"]*\)".*/\1/p' /etc/unraid-version 2>/dev/null | head -n1)"
      [[ -n "$unraid_ver" ]] && OS_PRETTY="Unraid ${unraid_ver} (Slackware)" || OS_PRETTY="Unraid (Slackware)"
    fi
  elif [[ -r /etc/truenas-version ]] || [[ "$DISTRO_ID" == "truenas" ]] || grep -qi "truenas" /etc/os-release 2>/dev/null; then
    IS_TRUENAS=true
    [[ "$DISTRO_FAMILY" == "unknown" ]] && DISTRO_FAMILY="debian"
    if [[ -r /etc/truenas-version ]]; then
      OS_PRETTY="TrueNAS SCALE $(head -n1 /etc/truenas-version 2>/dev/null || true)"
    fi
  elif [[ -d /usr/syno ]] || [[ -r /etc.defaults/VERSION ]] || grep -qi "synology" /etc/os-release 2>/dev/null; then
    IS_SYNOLOGY=true
    DISTRO_ID="synology"
    DISTRO_FAMILY="synology"
    local dsm_ver=""
    if [[ -r /etc.defaults/VERSION ]]; then
      dsm_ver="$(sed -n 's/^productversion="\([^"]*\)".*/\1/p' /etc.defaults/VERSION 2>/dev/null | head -n1)"
    fi
    [[ -n "$dsm_ver" ]] && OS_PRETTY="Synology DSM ${dsm_ver}" || OS_PRETTY="Synology DSM"
  fi

  if [[ "$DISTRO_FAMILY" == "arch" ]]; then
    if command -v yay >/dev/null 2>&1; then
      AUR_HELPER="yay"
    elif command -v paru >/dev/null 2>&1; then
      AUR_HELPER="paru"
    fi
  fi
}

ensure_script_tools() {
  [[ -t 0 ]] || return 0
  if [[ "$IS_MACOS" == true ]]; then
    if ! command -v curl >/dev/null 2>&1; then
      echo -e "${C_YELLOW}Missing curl; install Xcode Command Line Tools ('xcode-select --install') or Homebrew curl.${C_RESET}"
    fi
    if ! has_working_python3; then
      if command -v brew >/dev/null 2>&1; then
        echo -e "${C_YELLOW}Working python3 not detected (used for JSON metrics & benchmark history).${C_RESET}"
        if confirm_yn "Install python3 via Homebrew now? [Y/n]: " "Y"; then
          pkg_install python3 || echo -e "${C_YELLOW}Warning: Failed to install python3; JSON telemetry may be incomplete.${C_RESET}"
        fi
      else
        echo -e "${C_YELLOW}Working python3 not detected (install Homebrew 'python3' or 'xcode-select --install' for benchmark history & live Strata metrics).${C_RESET}"
      fi
    fi
    return 0
  fi

  [[ "$DISTRO_FAMILY" != "unknown" && "$DISTRO_FAMILY" != "synology" ]] || return 0
  [[ "$IS_UNRAID" == true || "$IS_TRUENAS" == true ]] && return 0
  local missing_cmds=() missing_pkgs=()
  if ! command -v lspci >/dev/null 2>&1; then
    missing_cmds+=("lspci"); missing_pkgs+=("pciutils")
  fi
  if ! command -v curl >/dev/null 2>&1; then
    missing_cmds+=("curl"); missing_pkgs+=("curl")
  fi
  if ! has_working_python3; then
    missing_cmds+=("python3")
    case "$DISTRO_FAMILY" in
      arch) missing_pkgs+=("python") ;;
      *)    missing_pkgs+=("python3") ;;
    esac
  fi
  if [[ -z "$IS_VIRT" && "$IS_JETSON" == false ]] && ! command -v dmidecode >/dev/null 2>&1; then
    missing_cmds+=("dmidecode"); missing_pkgs+=("dmidecode")
  fi
  [[ ${#missing_pkgs[@]} -eq 0 ]] && return 0

  echo -e "${C_YELLOW}Missing tools needed by this script (${missing_cmds[*]}): ${C_BOLD}${missing_pkgs[*]}${C_RESET}"
  if confirm_yn "Install missing script tools now? [Y/n]: " "Y"; then
    pkg_install "${missing_pkgs[@]}" || echo -e "${C_YELLOW}Warning: Failed to install some tools; hardware detection or live stats may be incomplete.${C_RESET}"
  else
    echo -e "${C_DIM}Skipped installing missing script tools.${C_RESET}"
  fi
}

_applesmc_dir() {
  local d
  if [[ -n "${STRATA_APPLESMC_DIR:-}" && -d "$STRATA_APPLESMC_DIR" ]]; then
    echo "$STRATA_APPLESMC_DIR"
    return 0
  fi
  for d in /sys/devices/platform/applesmc* /sys/devices/platform/applesmc*/hwmon/hwmon*; do
    [[ -d "$d" ]] && compgen -G "$d/fan*_input" >/dev/null 2>&1 && { echo "$d"; return 0; }
  done
  local hm_base="${STRATA_HWMON_DIR:-/sys/class/hwmon}"
  for d in "$hm_base"/hwmon*; do
    [[ -r "$d/name" && "$(cat "$d/name" 2>/dev/null || true)" == "applesmc" ]] || continue
    compgen -G "$d/fan*_input" >/dev/null 2>&1 && { echo "$d"; return 0; }
  done
  for d in /sys/devices/platform/applesmc*; do
    [[ -d "$d" ]] && { echo "$d"; return 0; }
  done
  return 1
}

_is_nvidia_datacenter_name() {
  local n="${1:-}"
  grep -qiE "tesla" <<<"$n" && return 0
  grep -qiE "RTX PRO 6000.*Server|CMP [0-9]+HX|P10[246]-100" <<<"$n" && return 0
  grep -qiE "NVIDIA (T4G?|V100S?|A100|A800|A40|A30|A16|A10G?|A2|L40S?|L20|L4|L2|H100|H200|H800|H20|B100|B200|B300|GB200|GH200)\b" <<<"$n" && return 0
  grep -qiE "\b(T4G?|V100S?|A100|A800|A40|A30|A16|A10G?|A2|L40S?|L20|L4|L2|H100|H200|H800|H20|B100|B200|B300)\b.*(PCIe|SXM|NVL|HGX|16GB|24GB|32GB|40GB|48GB|80GB|94GB|96GB|141GB|180GB|192GB)" <<<"$n" && return 0
  return 1
}

_is_nvidia_consumer_unlock_name() {
  local n="${1:-}"
  _is_nvidia_datacenter_name "$n" && return 1
  grep -qiE "Quadro|RTX A[0-9]|RTX PRO" <<<"$n" && return 1
  grep -qiE "GTX 16|RTX 20|RTX 30|RTX 40|\b(TU10[246]|TU11[67]|GA10[2467]|AD10[23467])([^G]|$)" <<<"$n"
}

_is_intel_discrete_pci_id() {
  case "${1,,}" in
    0x569*|0x56a*|0x56b*|0x56c*|0x4f8*|0xe20*|0xe21*|0x0bd*) return 0 ;;
    *) return 1 ;;
  esac
}

_intel_dgpu_vram_mb_from_pci_id() {
  case "${1,,}" in
    0xe211) echo 24576 ;; # Intel Arc Pro B60 (24 GiB)
    0xe212) echo 16384 ;; # Intel Arc Pro B50 (16 GiB)
    0xe20b) echo 12288 ;; # Intel Arc B580 (12 GiB)
    0xe20c) echo 10240 ;; # Intel Arc B570 (10 GiB)
    *) return 1 ;;
  esac
}

detect_environment() {
  detect_platform_basics
  TOTAL_VRAM_MB=0
  NVIDIA_VRAM_MB=0
  HAS_NVIDIA=false HAS_NVIDIA_POWERD=false HAS_AMD=false HAS_INTEL_GPU=false HAS_INTEL_ARC=false
  HAS_AMD_APU=false HAS_AMD_PREBUILT_GFX=false AMD_GTT_TOTAL_MB=0
  HAS_AMD_INSTINCT=false HAS_AMD_NON_INSTINCT=false
  AMD_GFX_SUMMARY="" AMD_MISSING_GFX_SUMMARY="" AMD_GFX_ARCHS=() AMD_MISSING_GFX_ARCHS=()
  HAS_NVIDIA_TESLA=false HAS_NVIDIA_NON_TESLA=false NVIDIA_COMPUTE_MODE_NON_DEFAULT=false
  HAS_NVIDIA_DATACENTER=false HAS_NVIDIA_PASSIVE=false HAS_NVIDIA_LEGACY_PSTATE_CARD=false
  HAS_NVIDIA_KEPLER=false HAS_NVIDIA_MAXWELL=false HAS_NVIDIA_PASCAL=false HAS_NVIDIA_VOLTA_SM70=false
  HAS_NVIDIA_NVSWITCH=false IS_DGX_SPARK=false HAS_NVIDIA_UNIFIED_MEM=false
  NVIDIA_DRIVER_VER="" NVIDIA_DRIVER_MAJOR=0 NVIDIA_LIVE_EXTRA_FIELDS=""
  IS_LAPTOP=false HAS_MSI_EC=false HAS_ASPM=false
  IS_APPLE_LINUX=false IS_ASAHI_LINUX=false HAS_APPLESMC=false
  RAM_HEALTH_LINES=() GPU_TOPO_LINES=()
  GPU_SUMMARY="" GPU_RAW="" RAM_DETAILS=""
  NUMA_NODES=1 CPU_SOCKETS=1 DISCRETE_GPU_COUNT=0

  if [[ "$IS_MACOS" == true ]]; then
    SYS_VENDOR="Apple Inc."
    MACOS_MODEL_ID="${STRATA_MACOS_MODEL:-$(sysctl -n hw.model 2>/dev/null || true)}"
    PRODUCT_NAME="$MACOS_MODEL_ID"
    MACOS_CHIP="${STRATA_MACOS_CHIP:-$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)}"
    local cpu_threads p_cores e_cores ram_bytes sp_disp="" sp_chip="" sp_cores="" sp_metal=""
    cpu_threads="${STRATA_MACOS_THREADS:-$(sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?')}"
    MACOS_CPU_THREADS="$cpu_threads"
    p_cores="${STRATA_MACOS_PCORES:-$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || true)}"
    e_cores="${STRATA_MACOS_ECORES:-$(sysctl -n hw.perflevel1.logicalcpu 2>/dev/null || true)}"
    if [[ "$p_cores" =~ ^[0-9]+$ && "$e_cores" =~ ^[0-9]+$ ]]; then
      CPU_SUMMARY="${MACOS_CHIP:-Apple Silicon} (${cpu_threads} threads: ${p_cores}P+${e_cores}E)"
    else
      CPU_SUMMARY="${MACOS_CHIP:-Unknown CPU} (${cpu_threads} threads)"
    fi
    ram_bytes="${STRATA_MACOS_RAM_BYTES:-$(sysctl -n hw.memsize 2>/dev/null || echo 0)}"
    [[ "$ram_bytes" =~ ^[0-9]+$ ]] && { MACOS_RAM_BYTES="$ram_bytes"; RAM_GB=$(( ram_bytes / 1073741824 )); } || { MACOS_RAM_BYTES=0; RAM_GB=0; }
    [[ "$IS_APPLE_SILICON" == true ]] && RAM_DETAILS=" (Unified)" || RAM_DETAILS=""

    if command -v system_profiler >/dev/null 2>&1; then
      sp_disp="$(system_profiler SPDisplaysDataType 2>/dev/null || true)"
      sp_chip="$(sed -n 's/^[[:space:]]*Chipset Model:[[:space:]]*//p' <<< "$sp_disp" | head -n1)"
      sp_cores="$(sed -n 's/^[[:space:]]*Total Number of Cores:[[:space:]]*//p' <<< "$sp_disp" | head -n1)"
      sp_metal="$(sed -n 's/^[[:space:]]*Metal Support:[[:space:]]*//p' <<< "$sp_disp" | head -n1)"
    fi
    MACOS_GPU_CORES="${STRATA_MACOS_GPU_CORES:-$sp_cores}"
    MACOS_METAL_VER="${STRATA_MACOS_METAL_VER:-$sp_metal}"
    local gpu_base="${STRATA_MACOS_GPU_NAME:-${sp_chip:-$MACOS_CHIP}}"
    if [[ "$IS_APPLE_SILICON" == true ]]; then
      GPU_SUMMARY="${gpu_base:-Apple Silicon GPU}${MACOS_GPU_CORES:+ (${MACOS_GPU_CORES}-core GPU)}${MACOS_METAL_VER:+, ${MACOS_METAL_VER}}, Unified"
    else
      GPU_SUMMARY="${gpu_base:-Intel/Discrete GPU}${MACOS_METAL_VER:+, ${MACOS_METAL_VER}}"
    fi
    MACOS_WIRED_LIMIT_MB="${STRATA_MACOS_WIRED_LIMIT_MB:-$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)}"
    [[ "$MACOS_WIRED_LIMIT_MB" =~ ^[0-9]+$ ]] || MACOS_WIRED_LIMIT_MB=0
    if [[ "$MACOS_MODEL_ID" == MacBook* ]] || { command -v pmset >/dev/null 2>&1 && pmset -g batt 2>/dev/null | grep -qi "InternalBattery"; }; then
      IS_LAPTOP=true
    fi
    MACOS_POWER_MODE_SUPPORTED=false
    if command -v pmset >/dev/null 2>&1 && pmset -g 2>/dev/null | grep -qiE '(^|[[:space:]])powermode[[:space:]]'; then
      MACOS_POWER_MODE_SUPPORTED=true
    fi
  if declare -F refresh_strata_bin >/dev/null 2>&1; then
    refresh_strata_bin
  fi
    return 0
  fi

  SYS_VENDOR="${STRATA_SYS_VENDOR:-$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)}"
  PRODUCT_NAME="${STRATA_PRODUCT_NAME:-$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)}"
  local dt_dir="${STRATA_DT_DIR:-/proc/device-tree}"
  if grep -qiE "GB10|DGX Spark|Grace Blackwell" "$dt_dir/model" /sys/class/dmi/id/product_name 2>/dev/null; then
    IS_DGX_SPARK=true
    HAS_NVIDIA_UNIFIED_MEM=true
  fi
  if grep -qi "Apple" <<< "${SYS_VENDOR} ${PRODUCT_NAME}" || _applesmc_dir >/dev/null 2>&1; then
    IS_APPLE_LINUX=true
  fi
  if _applesmc_dir >/dev/null 2>&1; then
    HAS_APPLESMC=true
  fi
  if [[ "${STRATA_ARCH_UNAME:-$(uname -m 2>/dev/null || echo unknown)}" == "aarch64" ]] && grep -qi "apple," "$dt_dir/compatible" 2>/dev/null; then
    IS_APPLE_LINUX=true
    IS_ASAHI_LINUX=true
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    local nv_q cap_installed=false
    service_installed strata-nvidia-power-cap.service && cap_installed=true
    nv_q="$(nvidia-smi --query-gpu=index,name,power.limit,power.default_limit,power.max_limit,memory.total,compute_mode --format=csv,noheader,nounits 2>/dev/null || true)"
    if [[ -n "$nv_q" ]]; then
      HAS_NVIDIA=true
      NVIDIA_GPU_INDICES=() NVIDIA_GPU_NAMES=() NVIDIA_GPU_CUR_PL=() NVIDIA_GPU_DEF_PL=() NVIDIA_GPU_MAX_PL=() NVIDIA_GPU_MIN_PL=() NVIDIA_GPU_VRAM=() NVIDIA_GPU_COMPUTE_MODE=() NVIDIA_GPU_IS_TESLA=() NVIDIA_GPU_IS_DATACENTER=() NVIDIA_GPU_IS_PASSIVE=() NVIDIA_GPU_PL_SUPPORTED=() NVIDIA_GPU_COMPUTE_CAP=()
      local nv_vram_sum=0 nv_line g_idx g_name g_cur g_def g_mx g_vram g_cmode is_tesla pl_ok
      while IFS= read -r nv_line; do
        [[ -n "$nv_line" ]] || continue
        IFS=',' read -r g_idx g_name g_cur g_def g_mx g_vram g_cmode <<< "$nv_line"
        g_idx="${g_idx//[[:space:]]/}"
        g_name="${g_name#"${g_name%%[![:space:]]*}"}"; g_name="${g_name%"${g_name##*[![:space:]]}"}"
        g_cur="$(awk '$1 ~ /^[0-9]+(\.[0-9]+)?$/ {printf "%.0f", $1}' <<<"$g_cur")"
        g_def="$(awk '$1 ~ /^[0-9]+(\.[0-9]+)?$/ {printf "%.0f", $1}' <<<"$g_def")"
        g_mx="$(awk '$1 ~ /^[0-9]+(\.[0-9]+)?$/ {printf "%.0f", $1}' <<<"$g_mx")"
        g_vram="$(awk '$1 ~ /^[0-9]+$/ {print $1}' <<<"$g_vram")"
        g_cmode="${g_cmode//[[:space:]]/}"
        [[ "$g_idx" =~ ^[0-9]+$ ]] || continue
        is_tesla=false
        if _is_nvidia_datacenter_name "$g_name"; then
          is_tesla=true
          HAS_NVIDIA_TESLA=true
          HAS_NVIDIA_DATACENTER=true
        elif ! grep -qiE "GB10|DGX Spark" <<<"$g_name"; then
          HAS_NVIDIA_NON_TESLA=true
        fi
        if grep -qiE "GB10|DGX Spark" <<<"$g_name"; then
          IS_DGX_SPARK=true
          HAS_NVIDIA_UNIFIED_MEM=true
        fi
        pl_ok=false
        if [[ -n "$g_mx" && "$g_mx" -gt 0 ]] && { [[ -n "$g_def" && "$g_mx" -gt "$g_def" ]] || [[ "$cap_installed" == false && -n "$g_cur" && "$g_cur" -lt "$g_mx" ]]; } && ! grep -qiE "Laptop GPU|Mobile|Max-Q" <<<"$g_name"; then
          pl_ok=true
          if [[ "${CHECK_ONLY:-false}" == false && $EUID -eq 0 ]] && [[ -n "$g_cur" ]] && grep -qi "not supported" <<<"$(nvidia-smi -i "$g_idx" -pl "$g_cur" 2>&1 || true)"; then
            pl_ok=false
          fi
        fi
        NVIDIA_GPU_INDICES+=("$g_idx")
        NVIDIA_GPU_NAMES+=("$g_name")
        NVIDIA_GPU_CUR_PL+=("$g_cur")
        NVIDIA_GPU_DEF_PL+=("$g_def")
        NVIDIA_GPU_MAX_PL+=("$g_mx")
        NVIDIA_GPU_MIN_PL+=("")
        NVIDIA_GPU_VRAM+=("$g_vram")
        NVIDIA_GPU_COMPUTE_MODE+=("$g_cmode")
        NVIDIA_GPU_IS_TESLA+=("$is_tesla")
        NVIDIA_GPU_IS_DATACENTER+=("$is_tesla")
        NVIDIA_GPU_IS_PASSIVE+=("$is_tesla")
        NVIDIA_GPU_PL_SUPPORTED+=("$pl_ok")
        NVIDIA_GPU_COMPUTE_CAP+=("")
        [[ -n "$g_cmode" && "$g_cmode" != "Default" ]] && NVIDIA_COMPUTE_MODE_NON_DEFAULT=true
        [[ "$g_vram" =~ ^[0-9]+$ ]] && nv_vram_sum=$((nv_vram_sum + g_vram))
        if [[ "$pl_ok" == true ]]; then
          if [[ -z "$NVIDIA_MAX_PL" || -z "$NVIDIA_DEFAULT_PL" || "$NVIDIA_MAX_PL" -le "$NVIDIA_DEFAULT_PL" ]]; then
            NVIDIA_CURRENT_PL="$g_cur"
            NVIDIA_DEFAULT_PL="$g_def"
            NVIDIA_MAX_PL="$g_mx"
          fi
        elif [[ -z "$NVIDIA_CURRENT_PL" && -n "$g_cur" ]]; then
          NVIDIA_CURRENT_PL="$g_cur"
          NVIDIA_DEFAULT_PL="$g_def"
          NVIDIA_MAX_PL="$g_mx"
        fi
      done <<< "$nv_q"
      NVIDIA_VRAM_MB="$nv_vram_sum"
      [[ "$nv_vram_sum" -gt 0 ]] && TOTAL_VRAM_MB=$((TOTAL_VRAM_MB + nv_vram_sum))
      refresh_nvidia_clocks
      refresh_nvidia_ecc
      refresh_nvidia_caps
      refresh_nvidia_mig
    fi
  fi
  local raw_pci_lines gpu_lines="" gpu_render_lines gpu_src gpu_suffix="" p_line
  local pci_dir="${STRATA_PCI_DIR:-/sys/bus/pci/devices}"
  local drm_dir="${STRATA_DRM_DIR:-/sys/class/drm}"
  raw_pci_lines="$(lspci 2>/dev/null | grep -iE "vga|3d|display|processing accelerators" || true)"
  while IFS= read -r p_line; do
    [[ -n "$p_line" ]] || continue
    if grep -qi "processing accelerators" <<<"$p_line"; then
      if grep -qiE "QuickAssist|QAT|GNA|Gaussian|NPU|Movidius|VPU|Neural|IPU" <<<"$p_line"; then
        continue
      fi
      grep -qiE "\b(amd|ati|radeon|instinct|nvidia|tesla|arc|ponte vecchio|flex|battlemage|alchemist|bmg)\b|data center gpu" <<<"$p_line" || continue
    fi
    gpu_lines+="${p_line}"$'\n'
  done <<< "$raw_pci_lines"
  gpu_lines="${gpu_lines%$'\n'}"
  if [[ "$HAS_NVIDIA" == false ]] && grep -qi "nvidia" <<< "$gpu_lines"; then
    HAS_NVIDIA=true
  fi
  if grep -qi "nvidia" <<< "$gpu_lines" && _is_nvidia_datacenter_name "$gpu_lines"; then
    HAS_NVIDIA_TESLA=true
    HAS_NVIDIA_DATACENTER=true
  elif [[ "$HAS_NVIDIA_TESLA" == false ]] && grep -qiE "nvidia.*(tesla|k80|k40|k20|m40|m60|m10|p4\b|p40|p100|v100|t4\b|a100|a800|a40|a30|a16|a10g?|a2\b|l40s?|l20|l4\b|h100|h200|b100|b200|cmp.*hx)" <<< "$gpu_lines"; then
    HAS_NVIDIA_TESLA=true
    HAS_NVIDIA_DATACENTER=true
  fi
  if [[ "$HAS_NVIDIA" == true && ${#NVIDIA_GPU_INDICES[@]} -eq 0 ]]; then
    grep -qiE "\b(k80|k40|k20)\b" <<<"$gpu_lines" && HAS_NVIDIA_KEPLER=true
    grep -qiE "\b(m40|m60|m10)\b" <<<"$gpu_lines" && HAS_NVIDIA_MAXWELL=true
    grep -qiE "\b(p100|p40|p4|gtx 10)\b" <<<"$gpu_lines" && HAS_NVIDIA_PASCAL=true
    grep -qiE "\b(v100|titan v)\b" <<<"$gpu_lines" && HAS_NVIDIA_VOLTA_SM70=true
  fi
  if compgen -G "/dev/nvidia-nvswitch*" >/dev/null 2>&1 || lspci -nn 2>/dev/null | grep -qiE "10de:(1af1|1af2|22a3|22a4|22b1)|NVIDIA.*NVSwitch"; then
    HAS_NVIDIA_NVSWITCH=true
  fi
  if [[ "$IS_DGX_SPARK" == false && "$HAS_NVIDIA" == true ]] && { grep -qiE "GB10|DGX Spark" <<<"${gpu_lines} ${PRODUCT_NAME}" || { [[ "$(uname -m 2>/dev/null)" == "aarch64" && "$NVIDIA_VRAM_MB" -eq 0 ]] && grep -qiE "GB10|DGX Spark|Grace Blackwell" "${STRATA_DT_DIR:-/proc/device-tree}/model" /sys/class/dmi/id/product_name 2>/dev/null; }; }; then
    IS_DGX_SPARK=true
    HAS_NVIDIA_UNIFIED_MEM=true
  fi
  GPU_RAW="$gpu_lines"
  gpu_render_lines="$(grep -viE "aspeed|matrox.*g200|g200e|serverengines|pilot[0-9 ]|hi171[0-9]|xgi.*volari" <<< "$gpu_lines" || true)"
  gpu_src="$gpu_render_lines"
  if [[ -z "$gpu_src" && -n "$gpu_lines" ]]; then
    gpu_src="$gpu_lines"
    gpu_suffix=" (BMC video, not used)"
  fi
  if [[ -n "$gpu_src" ]]; then
    GPU_SUMMARY="$(echo "$gpu_src" | sed -E 's/^[^ ]+ [^:]+: //; s/ \((rev|prog-if)[^)]*\)//g; s/.*\[([^][]+)\][[:space:]]*$/\1/' | awk 'NF {s = (s ? s "; " $0 : $0)} END {print s}')${gpu_suffix}"
  else
    GPU_SUMMARY=""
  fi
  [[ -z "$GPU_SUMMARY" ]] && GPU_SUMMARY="Unknown"
  if echo "$gpu_lines" | grep -qi "intel"; then
    HAS_INTEL_GPU=true
    echo "$gpu_lines" | grep -qiE "\b(Arc|DG2|Battlemage|Alchemist|BMG|Flex)\b|Data Center GPU|Ponte Vecchio" && HAS_INTEL_ARC=true
  fi
  if [[ -d "$pci_dir" ]]; then
    local _idev _iven _idid _icls
    for _idev in "$pci_dir"/*; do
      [[ -d "$_idev" ]] || continue
      _icls="$(cat "$_idev/class" 2>/dev/null || true)"
      [[ "$_icls" == 0x03* || "$_icls" == 0x12* ]] || continue
      _iven="$(tr '[:upper:]' '[:lower:]' < "$_idev/vendor" 2>/dev/null || true)"
      if [[ "$_iven" == "0x8086" ]]; then
        [[ "$_icls" == 0x03* ]] && HAS_INTEL_GPU=true
        _idid="$(tr '[:upper:]' '[:lower:]' < "$_idev/device" 2>/dev/null || true)"
        if _is_intel_discrete_pci_id "$_idid"; then
          HAS_INTEL_GPU=true
          HAS_INTEL_ARC=true
        fi
      elif [[ "$_iven" == "0x1002" ]]; then
        HAS_AMD=true
      elif [[ "$_iven" == "0x10de" ]]; then
        HAS_NVIDIA=true
      fi
    done
  fi
  echo "$gpu_lines" | grep -qiE "\b(amd|ati|radeon|instinct)\b" && HAS_AMD=true
  detect_amd_gfx_archs
  if [[ "$HAS_AMD" == true ]]; then
    local card ven vram_file vt
    for card in "$drm_dir"/card[0-9]*; do
      [[ -e "$card" ]] || continue
      [[ "$(basename "$card")" == *-* ]] && continue
      if [[ -r "$card/device/vendor" ]]; then
        ven="$(tr '[:upper:]' '[:lower:]' < "$card/device/vendor" 2>/dev/null || true)"
        [[ "$ven" == "0x1002" ]] || continue
      fi
      vram_file="$card/device/mem_info_vram_total"
      [[ -r "$vram_file" ]] || continue
      vt="$(cat "$vram_file" 2>/dev/null || echo 0)"
      [[ "$vt" =~ ^[0-9]+$ ]] && (( vt > 0 )) && TOTAL_VRAM_MB=$((TOTAL_VRAM_MB + vt / 1048576))
    done
  fi
  if [[ "$HAS_INTEL_ARC" == true ]]; then
    local intel_vram_added=false card ven did vt_b v_mb max_b s e f sz
    for card in "$drm_dir"/card[0-9]*; do
      [[ -e "$card" ]] || continue
      [[ "$(basename "$card")" == *-* ]] && continue
      [[ -r "$card/device/vendor" ]] || continue
      ven="$(tr '[:upper:]' '[:lower:]' < "$card/device/vendor" 2>/dev/null || true)"
      [[ "$ven" == "0x8086" ]] || continue
      did="$(tr '[:upper:]' '[:lower:]' < "$card/device/device" 2>/dev/null || true)"
      _is_intel_discrete_pci_id "$did" || continue
      v_mb=""
      for vt_b in "$card/device/lmem_total_bytes" "$card/device/tile0/memory/vram_size" "$card/device/mem_info_vram_total"; do
        if [[ -r "$vt_b" ]]; then
          sz="$(cat "$vt_b" 2>/dev/null || echo 0)"
          if [[ "$sz" =~ ^[0-9]+$ ]] && (( sz > 0 )); then
            v_mb=$(( sz / 1048576 ))
            break
          fi
        fi
      done
      if [[ -z "$v_mb" ]]; then
        v_mb="$(_intel_dgpu_vram_mb_from_pci_id "$did" || true)"
      fi
      if [[ -z "$v_mb" && -r "$card/device/resource" ]]; then
        max_b=0
        while read -r s e f; do
          [[ "$s" =~ ^0x[0-9a-fA-F]+$ && "$e" =~ ^0x[0-9a-fA-F]+$ ]] || continue
          sz=$(( e - s + 1 ))
          (( e > s && sz > max_b )) && max_b=$sz
        done < "$card/device/resource" 2>/dev/null
        (( max_b >= 4294967296 )) && v_mb=$(( max_b / 1048576 ))
      fi
      if [[ "$v_mb" =~ ^[0-9]+$ ]] && (( v_mb > 0 )); then
        TOTAL_VRAM_MB=$((TOTAL_VRAM_MB + v_mb))
        intel_vram_added=true
      fi
    done
    if [[ "$intel_vram_added" == false && -d "$pci_dir" ]]; then
      for dev in "$pci_dir"/*; do
        [[ -d "$dev" ]] || continue
        ven="$(tr '[:upper:]' '[:lower:]' < "$dev/vendor" 2>/dev/null || true)"
        [[ "$ven" == "0x8086" ]] || continue
        did="$(tr '[:upper:]' '[:lower:]' < "$dev/device" 2>/dev/null || true)"
        _is_intel_discrete_pci_id "$did" || continue
        v_mb="$(_intel_dgpu_vram_mb_from_pci_id "$did" || true)"
        [[ "$v_mb" =~ ^[0-9]+$ ]] && (( v_mb > 0 )) && TOTAL_VRAM_MB=$((TOTAL_VRAM_MB + v_mb))
      done
    fi
  fi

  if [[ "$IS_JETSON" == true && "$HAS_NVIDIA" == false ]]; then
    HAS_NVIDIA=true
    if [[ "$IS_JETSON_TX2" == true ]]; then
      GPU_SUMMARY="NVIDIA Tegra X2 (Pascal, 256 CUDA cores, Unified)"
    elif [[ "$IS_JETSON_ORIN" == true ]]; then
      GPU_SUMMARY="${JETSON_MODEL:-NVIDIA Jetson Orin} (Ampere iGPU, Unified)"
    elif [[ "$IS_JETSON_XAVIER" == true ]]; then
      GPU_SUMMARY="${JETSON_MODEL:-NVIDIA Jetson Xavier} (Volta iGPU, Unified)"
    elif [[ "$IS_JETSON_THOR" == true ]]; then
      GPU_SUMMARY="${JETSON_MODEL:-NVIDIA Jetson AGX Thor} (Blackwell iGPU, Unified)"
    else
      GPU_SUMMARY="${JETSON_MODEL:-NVIDIA Jetson} Integrated GPU (Unified)"
    fi
  fi
  if [[ -z "$IS_VIRT" && "$IS_JETSON" == false ]] && command -v dmidecode >/dev/null 2>&1; then
    if [[ $EUID -eq 0 ]]; then DMI_MEM_CACHE="$(dmidecode -t 17 2>/dev/null || true)"
    elif sudo -n true >/dev/null 2>&1; then DMI_MEM_CACHE="$(sudo -n dmidecode -t 17 2>/dev/null || true)"; fi
  fi

  local ram_kb=0
  ram_kb="$(awk '/MemTotal/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  [[ "$ram_kb" =~ ^[0-9]+$ ]] || ram_kb=0
  RAM_MB=$(( ram_kb / 1024 ))
  RAM_GB=$(( (ram_kb + 524288) / 1048576 ))
  detect_ram_details
  detect_ram_health
  detect_gpu_topology
  KERNEL_VER="$(uname -r 2>/dev/null || echo unknown)"
  local cpu_model cpu_threads
  cpu_model="$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/  */ /g')"
  cpu_threads="$(nproc 2>/dev/null || echo '?')"
  [[ -z "$cpu_model" ]] && cpu_model="$(lscpu 2>/dev/null | awk -F': +' '/^Model name/ {print $2; exit}')"
  if [[ "$IS_JETSON_TX2" == true ]] && [[ -z "$cpu_model" || "$cpu_model" == ARMv8* ]]; then
    cpu_model="NVIDIA Denver 2 + ARM Cortex-A57"
  fi
  CPU_SUMMARY="${cpu_model:-Unknown CPU} (${cpu_threads} threads)"

  local nd=0 d
  for d in /sys/devices/system/node/node[0-9]*; do [[ -d "$d" ]] && ((nd++)); done
  NUMA_NODES=$(( nd > 0 ? nd : 1 ))
  local sk
  sk="$(cat /sys/devices/system/cpu/cpu[0-9]*/topology/physical_package_id 2>/dev/null | sort -u | wc -l || true)"
  [[ "$sk" =~ ^[0-9]+$ ]] && (( sk > 0 )) || sk="$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/ {gsub(/ /,"",$2); print $2}' || true)"
  CPU_SOCKETS="${sk:-1}"

  local dev cls ven did gn=0
  for dev in "$pci_dir"/*; do
    [[ -d "$dev" ]] || continue
    cls="$(cat "$dev/class" 2>/dev/null || true)"
    [[ "$cls" == 0x03* || "$cls" == 0x12* ]] || continue
    ven="$(tr '[:upper:]' '[:lower:]' < "$dev/vendor" 2>/dev/null || true)"
    if [[ "$ven" == "0x10de" || "$ven" == "0x1002" ]]; then
      ((gn++))
    elif [[ "$ven" == "0x8086" ]]; then
      did="$(tr '[:upper:]' '[:lower:]' < "$dev/device" 2>/dev/null || true)"
      _is_intel_discrete_pci_id "$did" && ((gn++))
    fi
  done
  DISCRETE_GPU_COUNT="$gn"
  (( DISCRETE_GPU_COUNT < ${#NVIDIA_GPU_INDICES[@]} )) && DISCRETE_GPU_COUNT="${#NVIDIA_GPU_INDICES[@]}"

  unit_exists nvidia-powerd.service && HAS_NVIDIA_POWERD=true
  if [[ -d /sys/class/power_supply/BAT0 || -d /sys/class/power_supply/BAT1 ]] || [[ "$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || true)" =~ ^(8|9|10|14)$ ]]; then
    IS_LAPTOP=true
  fi
  if [[ -d /sys/devices/platform/msi-ec ]] || ( [[ "$IS_LAPTOP" == true ]] && grep -qi "Micro-Star" <<< "$SYS_VENDOR" ); then
    HAS_MSI_EC=true
  fi
  [[ -f /sys/module/pcie_aspm/parameters/policy ]] && HAS_ASPM=true
  declare -F refresh_strata_bin >/dev/null 2>&1 && refresh_strata_bin
}

# ------------------------------------------------------------------------------
# Extra Helpers (kernel param values, sysctl snapshots, NVIDIA caches, PCIe diag)
# ------------------------------------------------------------------------------
kernel_param_value() {
  local name="$1" esc f v br="${STRATA_BOOT_ROOT:-}"
  esc="$(_escape_ere "$name")"
  v="$(tr ' ' '\n' <"${br}/proc/cmdline" 2>/dev/null | grep -m1 -E "^${esc}=" | cut -d= -f2- || true)"
  [[ -n "$v" ]] && { echo "$v"; return 0; }
  while IFS= read -r f; do
    [[ -r "$f" ]] || continue
    v="$(grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep -oE "(^|[[:space:]\"'])${esc}=[^ \"']+" | head -n1 | sed -E 's/^[[:space:]"'\'']+//' | cut -d= -f2- || true)"
    [[ -n "$v" ]] && { echo "$v"; return 0; }
  done < <(_kernel_param_files)
  return 1
}

# write_sysctl_with_prev FILE key=value...  (remembers previous runtime values as "# prev" lines)
write_sysctl_with_prev() {
  local file="$1"; shift
  local content="" kv key cur
  if [[ -f "$file" ]]; then
    content="$(grep '^# prev ' "$file" 2>/dev/null || true)"
    [[ -n "$content" ]] && content+=$'\n'
  else
    for kv in "$@"; do
      key="${kv%%=*}"
      cur="$(sysctl -n "$key" 2>/dev/null | tr '\t' ' ')"
      [[ -n "$cur" ]] && content+="# prev ${key}=${cur}"$'\n'
    done
  fi
  for kv in "$@"; do content+="${kv%%=*} = ${kv#*=}"$'\n'; done
  printf '%s' "$content" | run_root tee "$file" >/dev/null
  run_root sysctl --system >/dev/null 2>&1 || true
}
restore_sysctl_prev() {
  local file="$1" line kv
  if [[ -f "$file" ]]; then
    while IFS= read -r line; do
      kv="${line#\# prev }"
      run_root sysctl -w "${kv%%=*}=${kv#*=}" >/dev/null 2>&1 || true
    done < <(grep '^# prev ' "$file" 2>/dev/null || true)
  fi
  run_root rm -f "$file"
}

refresh_nvidia_power_limits() {
  local raw line g_idx g_cur i
  raw="$(nvidia-smi --query-gpu=index,power.limit --format=csv,noheader,nounits 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=',' read -r g_idx g_cur <<< "$line"
    g_idx="${g_idx//[[:space:]]/}"
    g_cur="$(awk '$1 ~ /^[0-9]+(\.[0-9]+)?$/ {printf "%.0f", $1}' <<<"$g_cur")"
    for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
      if [[ "${NVIDIA_GPU_INDICES[$i]}" == "$g_idx" ]]; then
        NVIDIA_GPU_CUR_PL[$i]="$g_cur"
        if [[ "${NVIDIA_GPU_PL_SUPPORTED[$i]}" == true ]] || [[ -n "${NVIDIA_GPU_MAX_PL[$i]}" && -n "${NVIDIA_GPU_DEF_PL[$i]}" && "${NVIDIA_GPU_MAX_PL[$i]}" -gt "${NVIDIA_GPU_DEF_PL[$i]}" ]]; then
          NVIDIA_CURRENT_PL="$g_cur"
        fi
      fi
    done
  done <<< "$raw"
}
refresh_nvidia_caps() {
  HAS_NVIDIA_PASSIVE=false HAS_NVIDIA_LEGACY_PSTATE_CARD=false
  HAS_NVIDIA_KEPLER=false HAS_NVIDIA_MAXWELL=false HAS_NVIDIA_PASCAL=false HAS_NVIDIA_VOLTA_SM70=false
  NVIDIA_DRIVER_VER="" NVIDIA_DRIVER_MAJOR=0
  local i
  for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
    NVIDIA_GPU_COMPUTE_CAP[$i]=""
    NVIDIA_GPU_MIN_PL[$i]=""
  done

  local -A fan_map=()
  local raw line g_idx val comb_ok=false c_cc c_min c_fan c_drv
  raw="$(nvidia-smi --query-gpu=index,compute_cap,power.min_limit,fan.speed,driver_version --format=csv,noheader,nounits 2>/dev/null || true)"
  if [[ -n "$raw" ]] && ! grep -qiE "not a valid|field.*not" <<<"$raw"; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      IFS=',' read -r g_idx c_cc c_min c_fan c_drv <<< "$line"
      g_idx="${g_idx//[[:space:]]/}"
      c_cc="${c_cc//[[:space:]]/}"
      c_min="${c_min#"${c_min%%[![:space:]]*}"}"; c_min="${c_min%"${c_min##*[![:space:]]}"}"
      c_fan="${c_fan#"${c_fan%%[![:space:]]*}"}"; c_fan="${c_fan%"${c_fan##*[![:space:]]}"}"
      c_drv="${c_drv//[[:space:]]/}"
      [[ "$g_idx" =~ ^[0-9]+$ && -n "$c_drv" && "$c_drv" == *.* ]] || continue
      comb_ok=true
      [[ -z "$NVIDIA_DRIVER_VER" ]] && NVIDIA_DRIVER_VER="$c_drv"
      fan_map["$g_idx"]="$c_fan"
      c_min="$(awk '$1 ~ /^[0-9]+(\.[0-9]+)?$/ {printf "%.0f", $1}' <<<"$c_min")"
      for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
        if [[ "${NVIDIA_GPU_INDICES[$i]}" == "$g_idx" ]]; then
          [[ "$c_cc" =~ ^[0-9]+\.[0-9]+$ ]] && NVIDIA_GPU_COMPUTE_CAP[$i]="$c_cc"
          [[ "$c_min" =~ ^[0-9]+$ ]] && NVIDIA_GPU_MIN_PL[$i]="$c_min"
        fi
      done
    done <<< "$raw"
  fi

  if [[ "$comb_ok" == false ]]; then
    raw="$(nvidia-smi --query-gpu=index,compute_cap --format=csv,noheader 2>/dev/null || true)"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      IFS=',' read -r g_idx val <<< "$line"
      g_idx="${g_idx//[[:space:]]/}"
      val="${val//[[:space:]]/}"
      [[ "$val" =~ ^[0-9]+\.[0-9]+$ ]] || continue
      for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
        [[ "${NVIDIA_GPU_INDICES[$i]}" == "$g_idx" ]] && NVIDIA_GPU_COMPUTE_CAP[$i]="$val"
      done
    done <<< "$raw"

    raw="$(nvidia-smi --query-gpu=index,power.min_limit --format=csv,noheader,nounits 2>/dev/null || true)"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      IFS=',' read -r g_idx val <<< "$line"
      g_idx="${g_idx//[[:space:]]/}"
      val="$(awk '$1 ~ /^[0-9]+(\.[0-9]+)?$/ {printf "%.0f", $1}' <<<"$val")"
      [[ "$val" =~ ^[0-9]+$ ]] || continue
      for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
        [[ "${NVIDIA_GPU_INDICES[$i]}" == "$g_idx" ]] && NVIDIA_GPU_MIN_PL[$i]="$val"
      done
    done <<< "$raw"

    raw="$(nvidia-smi --query-gpu=index,fan.speed --format=csv,noheader,nounits 2>/dev/null || true)"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      IFS=',' read -r g_idx val <<< "$line"
      g_idx="${g_idx//[[:space:]]/}"
      val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
      [[ "$g_idx" =~ ^[0-9]+$ ]] && fan_map["$g_idx"]="$val"
    done <<< "$raw"

    NVIDIA_DRIVER_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
  fi
  if [[ -z "$NVIDIA_DRIVER_VER" && -r /sys/module/nvidia/version ]]; then
    NVIDIA_DRIVER_VER="$(awk '{print $1; exit}' /sys/module/nvidia/version 2>/dev/null || true)"
  fi
  if [[ "$NVIDIA_DRIVER_VER" =~ ^([0-9]+)\. ]]; then
    NVIDIA_DRIVER_MAJOR="${BASH_REMATCH[1]}"
  fi

  local g_name cc is_dc is_passive fan_val
  for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
    g_idx="${NVIDIA_GPU_INDICES[$i]}"
    g_name="${NVIDIA_GPU_NAMES[$i]}"
    cc="${NVIDIA_GPU_COMPUTE_CAP[$i]}"
    is_dc="${NVIDIA_GPU_IS_DATACENTER[$i]}"
    fan_val="${fan_map[$g_idx]:-}"
    is_passive=false
    if [[ "$is_dc" == true ]]; then
      is_passive=true
    elif [[ "$fan_val" == *"Not Supported"* ]] && ! grep -qiE "GeForce|Laptop|Mobile|Max-Q" <<<"$g_name" && [[ "$IS_DGX_SPARK" == false ]]; then
      is_passive=true
    fi
    NVIDIA_GPU_IS_PASSIVE[$i]="$is_passive"
    [[ "$is_passive" == true ]] && HAS_NVIDIA_PASSIVE=true

    if [[ "$cc" == 3.* ]] || grep -qiE "\b(K80|K40|K20|K10)\b" <<<"$g_name"; then
      HAS_NVIDIA_KEPLER=true
    elif [[ "$cc" == 5.* ]] || grep -qiE "\b(M40|M60|M10|M6|M4)\b" <<<"$g_name"; then
      HAS_NVIDIA_MAXWELL=true
    elif [[ "$cc" == 6.0 || "$cc" == 6.1 ]] || grep -qiE "\b(P100|P40|P4|P6)\b|P10[246]-100" <<<"$g_name"; then
      HAS_NVIDIA_PASCAL=true
    elif [[ "$cc" == 7.0 ]] || grep -qiE "\bV100\b|Titan V" <<<"$g_name"; then
      HAS_NVIDIA_VOLTA_SM70=true
    fi

    if [[ "$is_dc" == true ]] && { [[ "$cc" =~ ^(5\.|6\.|7\.0$) ]] || grep -qiE "\b(M40|M60|M10|P4|P40|P100|V100)\b|CMP [0-9]+HX|P10[246]-100" <<<"$g_name"; }; then
      HAS_NVIDIA_LEGACY_PSTATE_CARD=true
    fi
  done
}
refresh_nvidia_mig() {
  NVIDIA_MIG_INDICES=() NVIDIA_GPU_MIG_CUR=() NVIDIA_GPU_MIG_PEND=()
  NVIDIA_MIG_ANY_ENABLED=false NVIDIA_MIG_ANY_PEND_ENABLED=false
  local raw line g_idx cur pend
  raw="$(nvidia-smi --query-gpu=index,mig.mode.current,mig.mode.pending --format=csv,noheader 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=',' read -r g_idx cur pend <<< "$line"
    g_idx="${g_idx//[[:space:]]/}"
    cur="${cur//[[:space:]]/}"
    pend="${pend//[[:space:]]/}"
    if [[ "$g_idx" =~ ^[0-9]+$ && ( "$cur" == "Enabled" || "$cur" == "Disabled" ) ]]; then
      NVIDIA_MIG_INDICES+=("$g_idx")
      NVIDIA_GPU_MIG_CUR+=("$cur")
      NVIDIA_GPU_MIG_PEND+=("$pend")
      [[ "$cur" == "Enabled" ]] && NVIDIA_MIG_ANY_ENABLED=true
      if [[ "$pend" == "Enabled" || ( "$pend" != "Disabled" && "$cur" == "Enabled" ) ]]; then
        NVIDIA_MIG_ANY_PEND_ENABLED=true
      fi
    fi
  done <<< "$raw"
}
refresh_nvidia_clocks() {
  NVIDIA_GPU_MAX_GFX_CLK=() NVIDIA_GPU_MAX_MEM_CLK=()
  NVIDIA_MAX_GFX_CLK="" NVIDIA_MAX_MEM_CLK=""
  local raw line g_idx g_gfx g_mem i
  for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
    NVIDIA_GPU_MAX_GFX_CLK+=("")
    NVIDIA_GPU_MAX_MEM_CLK+=("")
  done
  raw="$(nvidia-smi --query-gpu=index,clocks.max.graphics,clocks.max.memory --format=csv,noheader,nounits 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=',' read -r g_idx g_gfx g_mem <<< "$line"
    g_idx="${g_idx//[[:space:]]/}"
    g_gfx="${g_gfx//[[:space:]]/}"
    g_mem="${g_mem//[[:space:]]/}"
    [[ "$g_gfx" =~ ^[0-9]+$ ]] || g_gfx=""
    [[ "$g_mem" =~ ^[0-9]+$ ]] || g_mem=""
    for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
      if [[ "${NVIDIA_GPU_INDICES[$i]}" == "$g_idx" ]]; then
        NVIDIA_GPU_MAX_GFX_CLK[$i]="$g_gfx"
        NVIDIA_GPU_MAX_MEM_CLK[$i]="$g_mem"
      fi
    done
    if [[ -n "$g_gfx" ]] && (( g_gfx > ${NVIDIA_MAX_GFX_CLK:-0} )); then
      NVIDIA_MAX_GFX_CLK="$g_gfx"
    fi
    if [[ -n "$g_mem" ]] && (( g_mem > ${NVIDIA_MAX_MEM_CLK:-0} )); then
      NVIDIA_MAX_MEM_CLK="$g_mem"
    fi
  done <<< "$raw"
}
refresh_nvidia_ecc() {
  NVIDIA_ECC_INDICES=() NVIDIA_ECC_CUR="" NVIDIA_ECC_PEND=""
  local raw line g_idx cur pend any_cur_en=false any_pend_en=false
  raw="$(nvidia-smi --query-gpu=index,ecc.mode.current,ecc.mode.pending --format=csv,noheader 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=',' read -r g_idx cur pend <<< "$line"
    g_idx="${g_idx//[[:space:]]/}"
    cur="${cur//[[:space:]]/}"
    pend="${pend//[[:space:]]/}"
    if [[ "$cur" == "Enabled" || "$cur" == "Disabled" ]]; then
      NVIDIA_ECC_INDICES+=("$g_idx")
      [[ "$cur" == "Enabled" ]] && any_cur_en=true
      if [[ "$pend" == "Enabled" || ( "$pend" != "Disabled" && "$cur" == "Enabled" ) ]]; then
        any_pend_en=true
      fi
    fi
  done <<< "$raw"
  if (( ${#NVIDIA_ECC_INDICES[@]} > 0 )); then
    [[ "$any_cur_en" == true ]] && NVIDIA_ECC_CUR="Enabled" || NVIDIA_ECC_CUR="Disabled"
    [[ "$any_pend_en" == true ]] && NVIDIA_ECC_PEND="Enabled" || NVIDIA_ECC_PEND="Disabled"
  fi
}
refresh_nvidia_compute_mode() {
  NVIDIA_COMPUTE_MODE_NON_DEFAULT=false
  local raw line g_idx g_cmode i
  raw="$(nvidia-smi --query-gpu=index,compute_mode --format=csv,noheader 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=',' read -r g_idx g_cmode <<< "$line"
    g_idx="${g_idx//[[:space:]]/}"
    g_cmode="${g_cmode//[[:space:]]/}"
    for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
      if [[ "${NVIDIA_GPU_INDICES[$i]}" == "$g_idx" ]]; then
        NVIDIA_GPU_COMPUTE_MODE[$i]="$g_cmode"
      fi
    done
    [[ -n "$g_cmode" && "$g_cmode" != "Default" ]] && NVIDIA_COMPUTE_MODE_NON_DEFAULT=true
  done <<< "$raw"
}

pcie_gen_from_speed() {
  case "${1%% *}" in
    2.5) echo 1 ;; 5|5.0) echo 2 ;; 8|8.0) echo 3 ;; 16|16.0) echo 4 ;; 32|32.0) echo 5 ;; 64|64.0) echo 6 ;;
    *) echo "" ;;
  esac
}

detect_ram_health() {
  RAM_HEALTH_LINES=()
  [[ -z "$IS_VIRT" && -n "$DMI_MEM_CACHE" ]] || return 0
  local dimms count=0 type form spd conf slow=""
  dimms="$(awk 'BEGIN {RS=""; FS="\n"}
    /Memory Device/ {
      size=""; type=""; form=""; spd=""; conf=""
      for (i = 1; i <= NF; i++) {
        l = $i; sub(/^[ \t]+/, "", l)
        if (l ~ /^Size:/) size = l
        else if (l ~ /^Type:/) type = substr(l, 7)
        else if (l ~ /^Form Factor:/) form = substr(l, 14)
        else if (l ~ /^Speed:/) { spd = l; gsub(/[^0-9]/, "", spd) }
        else if (l ~ /^Configured (Memory|Clock) Speed:/) { conf = l; sub(/^[^:]*: */, "", conf); gsub(/[^0-9]/, "", conf) }
      }
      if (size != "" && size !~ /No Module/) print type "|" form "|" spd "|" conf
    }' <<<"$DMI_MEM_CACHE")"
  [[ -n "$dimms" ]] || return 0
  while IFS='|' read -r type form spd conf; do
    ((count++))
    if [[ "$spd" =~ ^[0-9]+$ && "$conf" =~ ^[0-9]+$ ]] && (( conf > 0 && conf < spd )); then
      slow="running ${conf} MT/s, rated ${spd} MT/s (enable XMP/EXPO in BIOS)"
    fi
  done <<<"$dimms"
  if (( count == 1 )) && [[ "$type" =~ ^DDR[345]$ && "$form" == *DIMM* ]]; then
    RAM_HEALTH_LINES+=("$(printf "%bRAM:    %b[!] single DIMM installed (single-channel, halves memory bandwidth)%b" "${C_DIM}" "${C_YELLOW}" "${C_RESET}")")
  fi
  if [[ -n "$slow" ]]; then
    RAM_HEALTH_LINES+=("$(printf "%bRAM:    %b[!] %s%b" "${C_DIM}" "${C_YELLOW}" "$slow" "${C_RESET}")")
  fi
}

detect_pcie_acs_enabled() {
  PCIE_ACS_CHECKED=false PCIE_ACS_ENABLED=false
  command -v lspci >/dev/null 2>&1 || return 0
  local acs_out="" can_read=false
  if [[ $EUID -eq 0 ]]; then
    acs_out="$(lspci -d ::0604 -vv 2>/dev/null || lspci -vv 2>/dev/null || true)"
    can_read=true
  elif sudo -n true >/dev/null 2>&1; then
    acs_out="$(sudo -n lspci -d ::0604 -vv 2>/dev/null || sudo -n lspci -vv 2>/dev/null || true)"
    can_read=true
  else
    acs_out="$(lspci -d ::0604 -vv 2>/dev/null || lspci -vv 2>/dev/null || true)"
    grep -qiE "Capabilities:|ACSCtl:" <<<"$acs_out" && can_read=true
  fi
  if [[ "$can_read" == true ]]; then
    PCIE_ACS_CHECKED=true
    if grep -qE "ACSCtl:.*(SrcValid\+|ReqRedir\+|CmpltRedir\+|UpstreamFwd\+)" <<<"$acs_out"; then
      PCIE_ACS_ENABLED=true
    fi
  fi
}

detect_gpu_topology() {
  GPU_TOPO_LINES=()
  HAS_FULL_GPU_INTERCONNECT=false
  PCIE_ACS_CHECKED=false PCIE_ACS_ENABLED=false
  local pci_dir="${STRATA_PCI_DIR:-/sys/bus/pci/devices}"
  local kfd_dir="${STRATA_KFD_NODES_DIR:-/sys/class/kfd/kfd/topology/nodes}"
  local dev cls ven did numa n_gpu=0 n_nv=0 n_amd=0 nodes=() distinct
  if [[ -d "$pci_dir" ]]; then
    for dev in "$pci_dir"/*; do
      [[ -d "$dev" ]] || continue
      cls="$(cat "$dev/class" 2>/dev/null || true)"
      [[ "$cls" == 0x03* || "$cls" == 0x12* ]] || continue
      ven="$(tr '[:upper:]' '[:lower:]' < "$dev/vendor" 2>/dev/null || true)"
      if [[ "$ven" == "0x10de" ]]; then
        ((n_nv++))
      elif [[ "$ven" == "0x1002" ]]; then
        ((n_amd++))
      elif [[ "$ven" == "0x8086" ]]; then
        did="$(tr '[:upper:]' '[:lower:]' < "$dev/device" 2>/dev/null || true)"
        _is_intel_discrete_pci_id "$did" || continue
      else
        continue
      fi
      ((n_gpu++))
      numa="$(cat "$dev/numa_node" 2>/dev/null || true)"
      [[ "$numa" =~ ^[0-9]+$ ]] && nodes+=("$numa")
    done
  fi
  if (( n_nv == 0 && ${#NVIDIA_GPU_INDICES[@]} > 0 )); then
    n_nv="${#NVIDIA_GPU_INDICES[@]}"
    (( n_gpu < n_nv )) && n_gpu="$n_nv"
  fi
  (( n_gpu >= 2 )) || return 0
  if (( ${#nodes[@]} > 1 )); then
    distinct="$(printf '%s\n' "${nodes[@]}" | sort -u | wc -l)"
    (( distinct > 1 )) && GPU_TOPO_LINES+=("$(printf "%bMulti-GPU: %b[!] GPUs sit on %s NUMA nodes (cross-socket traffic; keep a model on one node)%b" "${C_DIM}" "${C_YELLOW}" "$distinct" "${C_RESET}")")
  fi
  if (( n_nv >= 2 )) && command -v nvidia-smi >/dev/null 2>&1; then
    local nvlink_out="" topo_out=""
    nvlink_out="$(nvidia-smi nvlink -s 2>/dev/null || true)"
    topo_out="$(nvidia-smi topo -m 2>/dev/null || true)"
    if grep -q "GB/s" <<<"$nvlink_out" || grep -qE '\bNV[0-9]+\b' <<<"$topo_out"; then
      HAS_FULL_GPU_INTERCONNECT=true
      if [[ "$HAS_NVIDIA_NVSWITCH" == true ]]; then
        GPU_TOPO_LINES+=("$(printf "%bMulti-GPU: NVLink + NVSwitch active%b" "${C_DIM}" "${C_RESET}")")
      else
        GPU_TOPO_LINES+=("$(printf "%bMulti-GPU: NVLink active%b" "${C_DIM}" "${C_RESET}")")
      fi
    elif grep -qE '\b(PIX|PXB)\b' <<<"$topo_out"; then
      GPU_TOPO_LINES+=("$(printf "%bMulti-GPU: no NVLink (PCIe switch P2P: PIX/PXB)%b" "${C_DIM}" "${C_RESET}")")
    elif grep -qE '\b(PHB|NODE|SYS)\b' <<<"$topo_out"; then
      GPU_TOPO_LINES+=("$(printf "%bMulti-GPU: no NVLink (PCIe via CPU root/NUMA: PHB/NODE/SYS)%b" "${C_DIM}" "${C_RESET}")")
    else
      GPU_TOPO_LINES+=("$(printf "%bMulti-GPU: no NVLink (GPU-to-GPU traffic uses PCIe)%b" "${C_DIM}" "${C_RESET}")")
    fi
  fi
  if (( n_amd >= 2 )); then
    local has_xgmi=false io_p
    if [[ -d "$kfd_dir" ]]; then
      for io_p in "$kfd_dir"/*/io_links/*/properties; do
        [[ -r "$io_p" ]] || continue
        if grep -qE '^type[[:space:]]+11$' "$io_p" 2>/dev/null; then
          has_xgmi=true
          break
        fi
      done
    fi
    if [[ "$has_xgmi" == false ]] && command -v amd-smi >/dev/null 2>&1; then
      amd-smi topology --link-type 2>/dev/null | grep -qi "XGMI" && has_xgmi=true
    elif [[ "$has_xgmi" == false ]] && command -v rocm-smi >/dev/null 2>&1; then
      rocm-smi --showtopo 2>/dev/null | grep -qi "XGMI" && has_xgmi=true
    fi
    if [[ "$has_xgmi" == true ]]; then
      HAS_FULL_GPU_INTERCONNECT=true
      GPU_TOPO_LINES+=("$(printf "%bMulti-GPU: AMD XGMI / Infinity Fabric active%b" "${C_DIM}" "${C_RESET}")")
    else
      GPU_TOPO_LINES+=("$(printf "%bMulti-GPU: no XGMI (GPU-to-GPU traffic uses PCIe)%b" "${C_DIM}" "${C_RESET}")")
    fi
  fi
  if [[ "$HAS_FULL_GPU_INTERCONNECT" == false ]]; then
    detect_pcie_acs_enabled
    if [[ "$PCIE_ACS_ENABLED" == true ]]; then
      GPU_TOPO_LINES+=("$(printf "%bMulti-GPU: %b[!] PCIe ACS enabled on bridges (blocks direct GPU P2P; disable in BIOS or via PCIe ACS step)%b" "${C_DIM}" "${C_YELLOW}" "${C_RESET}")")
    fi
  fi
}

power_daemon_conflict_line() {
  [[ "$IS_MACOS" == true ]] && return 0
  local active=()
  unit_active tlp.service && active+=("TLP")
  unit_active auto-cpufreq.service && active+=("auto-cpufreq")
  if unit_active tuned.service && unit_active power-profiles-daemon.service; then active+=("tuned+power-profiles-daemon"); fi
  (( ${#active[@]} > 0 )) || return 0
  printf "%bPower:  %b[!] %s active (may override governor/EPP set by this tool)%b" "${C_DIM}" "${C_YELLOW}" "${active[*]}" "${C_RESET}"
}

# Appends one "PCIe:" diagnostic line per discrete/integrated GPU (link width/gen + Resizable BAR).
append_gpu_pcie_lines() {
  [[ "$IS_MACOS" == true ]] && return 0
  local pci_dir="${STRATA_PCI_DIR:-/sys/bus/pci/devices}"
  local dev cls ven did cs ms cw mw cg mg addr line rebar max_bar s e f size vt cap_out dev_desc
  for dev in "$pci_dir"/*; do
    [[ -d "$dev" ]] || continue
    cls="$(cat "$dev/class" 2>/dev/null || true)"
    [[ "$cls" == 0x03* || "$cls" == 0x12* ]] || continue
    ven="$(tr '[:upper:]' '[:lower:]' < "$dev/vendor" 2>/dev/null || true)"
    did="$(tr '[:upper:]' '[:lower:]' < "$dev/device" 2>/dev/null || true)"
    if [[ "$cls" == 0x12* ]]; then
      if [[ "$ven" != "0x1002" && "$ven" != "0x10de" ]] && ! { [[ "$ven" == "0x8086" ]] && _is_intel_discrete_pci_id "$did"; }; then
        continue
      fi
    else
      [[ "$ven" == "0x10de" || "$ven" == "0x1002" || "$ven" == "0x8086" ]] || continue
    fi
    cs="$(cat "$dev/current_link_speed" 2>/dev/null || true)"; ms="$(cat "$dev/max_link_speed" 2>/dev/null || true)"
    cw="$(cat "$dev/current_link_width" 2>/dev/null || true)"; mw="$(cat "$dev/max_link_width" 2>/dev/null || true)"
    cg="$(pcie_gen_from_speed "$cs")"; mg="$(pcie_gen_from_speed "$ms")"
    [[ -n "$cg" && -n "$mg" && "$cw" =~ ^[0-9]+$ && "$mw" =~ ^[0-9]+$ ]] || continue
    addr="$(basename "$dev")"; addr="${addr#0000:}"
    line="${addr} Gen${cg} x${cw}"
    if (( cw < mw )); then
      line+=" ${C_YELLOW}[!] card supports x${mw}${C_RESET}${C_DIM}"
    fi
    (( cg < mg )) && line+=" (max Gen${mg}; may downshift at idle)"

    rebar=""
    max_bar=0
    if [[ "$ven" == "0x10de" || "$ven" == "0x1002" ]] || { [[ "$ven" == "0x8086" ]] && _is_intel_discrete_pci_id "$did"; }; then
      while read -r s e f; do
        [[ "$s" =~ ^0x[0-9a-fA-F]+$ && "$e" =~ ^0x[0-9a-fA-F]+$ ]] || continue
        size=$(( e - s + 1 ))
        (( e > s && size > max_bar )) && max_bar=$size
      done < "$dev/resource" 2>/dev/null
      if (( max_bar > 0 )); then
        vt="$(cat "$dev/mem_info_vram_total" 2>/dev/null || true)"
        if [[ "$ven" == "0x1002" && "$vt" =~ ^[0-9]+$ ]] && (( vt > 0 )); then
          (( max_bar * 10 >= vt * 9 )) && rebar=on || rebar=off
        else
          (( max_bar > 536870912 )) && rebar=on || rebar=off
        fi
        if [[ "$rebar" == "off" ]]; then
          cap_out=""
          if command -v lspci >/dev/null 2>&1; then
            if [[ $EUID -eq 0 ]]; then
              cap_out="$(lspci -vv -s "$addr" 2>/dev/null || true)"
            elif sudo -n true >/dev/null 2>&1; then
              cap_out="$(sudo -n lspci -vv -s "$addr" 2>/dev/null || true)"
            else
              cap_out="$(lspci -vv -s "$addr" 2>/dev/null || true)"
            fi
          fi
          if grep -qiE "Capabilities:|Resizable BAR" <<<"$cap_out"; then
            grep -qi "Resizable BAR" <<<"$cap_out" || rebar="unsupported"
          else
            dev_desc="$(lspci -s "$addr" 2>/dev/null || echo "$GPU_RAW")"
            if grep -qiE "Tesla|\b(K80|K40|K20|M40|M60|M10|P4|P40|P100|V100|T4)\b|CMP [0-9]+HX|P10[246]-100" <<<"$dev_desc"; then
              rebar="unsupported"
            fi
          fi
        fi
      fi
    fi
    if [[ "$rebar" == "on" ]]; then
      line+=" | ReBAR: on"
    elif [[ "$rebar" == "off" ]]; then
      line+=" | ${C_YELLOW}[!] ReBAR: off${C_RESET}${C_DIM} (enable Resizable BAR in BIOS)"
    elif [[ "$rebar" == "unsupported" ]]; then
      line+=" | BAR1: $(( max_bar / 1048576 )) MiB"
    fi
    SYS_INFO_LINES+=("$(printf "PCIe:   %b%b%b" "${C_DIM}" "$line" "${C_RESET}")")
  done
}

# ------------------------------------------------------------------------------
# Plugin Loader & Registration API
# ------------------------------------------------------------------------------
_sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  elif has_working_python3; then
    python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$f" 2>/dev/null
  else
    return 1
  fi
}

_fetch_url() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url" 2>/dev/null
  else
    return 1
  fi
}

_registry_file() {
  local local_reg="${SCRIPT_DIR}/plugins/registry.tsv"
  if [[ -f "$local_reg" ]]; then
    echo "$local_reg"
    return 0
  fi
  local cached_reg="${PLUGIN_CACHE_DIR}/registry.tsv"
  if [[ "$REGISTRY_FETCHED" != true ]]; then
    REGISTRY_FETCHED=true
    mkdir -p "$PLUGIN_CACHE_DIR" 2>/dev/null || true
    local tmp_reg="${cached_reg}.tmp.$$"
    if _fetch_url "${PLUGIN_BASE_URL}/plugins/registry.tsv" "$tmp_reg"; then
      mv -f "$tmp_reg" "$cached_reg" 2>/dev/null || rm -f "$tmp_reg"
    else
      rm -f "$tmp_reg"
    fi
  fi
  [[ -f "$cached_reg" ]] && echo "$cached_reg"
}

_registry_sha256() {
  local category="$1" id="$2" reg=""
  reg="$(_registry_file || true)"
  [[ -n "$reg" && -f "$reg" ]] || return 0
  awk -F'\t' -v c="$category" -v i="$id" '$1==c && $2==i {print $6; exit}' "$reg" 2>/dev/null || true
}

discover_host_plugins() {
  local f id name desc reg=""
  if [[ -d "${SCRIPT_DIR}/plugins/hosts" ]]; then
    for f in "${SCRIPT_DIR}/plugins/hosts/"*.sh; do
      [[ -f "$f" ]] || continue
      id="$(basename "$f" .sh)"
      [[ "$id" == _* ]] && continue
      if ! _array_contains_val "$id" "${AVAILABLE_HOST_PLUGINS[@]}"; then
        AVAILABLE_HOST_PLUGINS+=("$id")
      fi
      if [[ -z "${HOST_PLUGIN_NAMES[$id]:-}" ]]; then
        name="$(awk -F': ' '/^# PLUGIN_NAME:/ {print $2; exit}' "$f" 2>/dev/null || true)"
        HOST_PLUGIN_NAMES[$id]="${name:-$id}"
      fi
      if [[ -z "${HOST_PLUGIN_DESCS[$id]:-}" ]]; then
        desc="$(awk -F': ' '/^# PLUGIN_DESC:/ {print $2; exit}' "$f" 2>/dev/null || true)"
        HOST_PLUGIN_DESCS[$id]="${desc:-LLM host plugin}"
      fi
    done
  fi
  reg="$(_registry_file || true)"
  if [[ -n "$reg" && -f "$reg" ]]; then
    while IFS=$'\t' read -r cat pid pname pdesc _pfile _psha; do
      [[ "$cat" == "hosts" && -n "$pid" && "$pid" != _* ]] || continue
      if ! _array_contains_val "$pid" "${AVAILABLE_HOST_PLUGINS[@]}"; then
        AVAILABLE_HOST_PLUGINS+=("$pid")
      fi
      [[ -n "$pname" ]] && HOST_PLUGIN_NAMES[$pid]="$pname"
      [[ -n "$pdesc" ]] && HOST_PLUGIN_DESCS[$pid]="$pdesc"
    done < "$reg"
  fi
}

register_host_plugin() {
  local id="" name="" desc=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) id="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --description|--desc) desc="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$id" ]] || return 1
  if ! _array_contains_val "$id" "${AVAILABLE_HOST_PLUGINS[@]}"; then
    AVAILABLE_HOST_PLUGINS+=("$id")
  fi
  [[ -n "$name" ]] && HOST_PLUGIN_NAMES[$id]="$name"
  [[ -n "$desc" ]] && HOST_PLUGIN_DESCS[$id]="$desc"
}

register_tweak() {
  local id="" stars="3" tier="recommended" os="linux" laptop_rec="true" vm_sup="true" exp_non_arch="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) id="$2"; shift 2 ;;
      --stars) stars="$2"; shift 2 ;;
      --tier) tier="$2"; shift 2 ;;
      --os) os="$2"; shift 2 ;;
      --laptop-recommended) laptop_rec="$2"; shift 2 ;;
      --vm-supported) vm_sup="$2"; shift 2 ;;
      --experimental-non-arch) exp_non_arch="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$id" ]] || return 1
  if [[ -z "${TWEAK_REGISTERED[$id]:-}" ]]; then
    ALL_STEPS+=("$id")
    TWEAK_REGISTERED[$id]=1
  fi
  STEP_GAIN_PTS[$id]="$stars"
  STEP_TIER[$id]="$tier"
  STEP_OS[$id]="$os"
  STEP_LAPTOP_REC[$id]="$laptop_rec"
  STEP_VM_SUPPORTED[$id]="$vm_sup"
  STEP_EXP_NON_ARCH[$id]="$exp_non_arch"
}

load_plugin() {
  local category="$1" id="$2"
  if [[ "$category" == "hosts" && -n "${HOST_PLUGIN_LOADED[$id]:-}" ]]; then
    return 0
  elif [[ "$category" == "tweaks" && -n "${TWEAK_PACK_LOADED[$id]:-}" ]]; then
    return 0
  fi

  local local_file="${SCRIPT_DIR}/plugins/${category}/${id}.sh"
  local cache_file="${PLUGIN_CACHE_DIR}/${category}/${id}.sh"
  local target_file="" expected_sha="" actual_sha=""

  if [[ -f "$local_file" ]]; then
    target_file="$local_file"
  else
    expected_sha="$(_registry_sha256 "$category" "$id")"
    if [[ -f "$cache_file" ]]; then
      if [[ -z "$expected_sha" ]]; then
        target_file="$cache_file"
      else
        actual_sha="$(_sha256_file "$cache_file" || true)"
        [[ "$actual_sha" == "$expected_sha" ]] && target_file="$cache_file"
      fi
    fi
    if [[ -z "$target_file" ]]; then
      mkdir -p "${PLUGIN_CACHE_DIR}/${category}" 2>/dev/null || return 1
      local tmp_file="${cache_file}.tmp.$$"
      if ! _fetch_url "${PLUGIN_BASE_URL}/plugins/${category}/${id}.sh" "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
      fi
      if [[ -n "$expected_sha" ]]; then
        actual_sha="$(_sha256_file "$tmp_file" || true)"
        if [[ "$actual_sha" != "$expected_sha" ]]; then
          rm -f "$tmp_file"
          echo -e "${C_RED}Checksum mismatch for plugin ${category}/${id}.sh — refusing to load.${C_RESET}" >&2
          return 1
        fi
      fi
      mv -f "$tmp_file" "$cache_file"
      target_file="$cache_file"
    fi
  fi

  # shellcheck source=/dev/null
  source "$target_file"
  if [[ "$category" == "hosts" ]]; then
    HOST_PLUGIN_LOADED[$id]=1
    LOADED_HOST_PLUGINS+=("$id")
    if declare -F "${id}_init" >/dev/null 2>&1; then
      "${id}_init"
    fi
  else
    TWEAK_PACK_LOADED[$id]=1
    LOADED_TWEAK_PACKS+=("$id")
  fi
}

load_applicable_tweak_packs() {
  [[ "$NO_PLUGINS" == true ]] && return 0
  load_plugin tweaks common || true
  if [[ "$IS_MACOS" == true ]]; then
    load_plugin tweaks macos || true
    return 0
  fi
  load_plugin tweaks linux-core || true
  if [[ "$IS_LAPTOP" == true || "$IS_APPLE_LINUX" == true ]]; then
    load_plugin tweaks linux-laptop || true
  fi
  if [[ "$HAS_NVIDIA" == true ]]; then
    load_plugin tweaks nvidia || true
  fi
  if [[ "$HAS_AMD" == true || "${CPU_SUMMARY:-}" == *AMD* || "${CPU_SUMMARY:-}" == *Ryzen* || "${CPU_SUMMARY:-}" == *EPYC* ]]; then
    load_plugin tweaks amd || true
  fi
  if [[ "$HAS_INTEL_GPU" == true || "${CPU_SUMMARY:-}" == *Intel* || -d /sys/class/powercap/intel-rapl ]]; then
    load_plugin tweaks intel || true
  fi
  if [[ "$IS_JETSON" == true ]]; then
    load_plugin tweaks jetson || true
  fi
}

load_all_local_plugins() {
  local f id
  if [[ -d "${SCRIPT_DIR}/plugins/tweaks" ]]; then
    for f in "${SCRIPT_DIR}/plugins/tweaks/"*.sh; do
      [[ -f "$f" ]] || continue
      id="$(basename "$f" .sh)"
      [[ "$id" == _* ]] && continue
      load_plugin tweaks "$id" || true
    done
  fi
  if [[ -d "${SCRIPT_DIR}/plugins/hosts" ]]; then
    for f in "${SCRIPT_DIR}/plugins/hosts/"*.sh; do
      [[ -f "$f" ]] || continue
      id="$(basename "$f" .sh)"
      [[ "$id" == _* ]] && continue
      load_plugin hosts "$id" || true
    done
  fi
}

run_host_hook() {
  local hook="$1"; shift
  local pid
  for pid in "${LOADED_HOST_PLUGINS[@]}"; do
    if declare -F "${pid}_${hook}" >/dev/null 2>&1; then
      "${pid}_${hook}" "$@"
    fi
  done
}

# ------------------------------------------------------------------------------
# Step Registry (populated dynamically by register_tweak)
# ------------------------------------------------------------------------------
ALL_STEPS=()
ACTIVE_STEPS=()
declare -A STEP_GAIN_PTS=()

build_active_steps() {
  local step candidates=() pts os_scope
  for step in "${ALL_STEPS[@]}"; do
    os_scope="${STEP_OS[$step]:-linux}"
    if [[ "$IS_MACOS" == true ]]; then
      [[ "$os_scope" == "macos" || "$os_scope" == "both" ]] || continue
    else
      [[ "$os_scope" == "linux" || "$os_scope" == "both" ]] || continue
    fi
    if [[ -n "$IS_VIRT" && "${STEP_VM_SUPPORTED[$step]:-true}" == "false" ]]; then
      continue
    fi
    "applicable_${step}" && candidates+=("$step")
  done
  ACTIVE_STEPS=()
  for (( pts = 5; pts >= 1; pts-- )); do
    for step in "${candidates[@]}"; do
      (( ${STEP_GAIN_PTS[$step]:-1} == pts )) && ACTIVE_STEPS+=("$step")
    done
  done
}

is_experimental_step() {
  if [[ "${STEP_EXP_NON_ARCH[$1]:-false}" == "true" ]]; then
    [[ "$DISTRO_FAMILY" != "arch" ]]
    return $?
  fi
  [[ "${STEP_TIER[$1]:-recommended}" == "experimental" ]]
}

is_opt_in_step() {
  [[ "${STEP_TIER[$1]:-recommended}" == "opt_in" ]]
}

is_high_idle_step() {
  [[ "${STEP_TIER[$1]:-recommended}" == "high_idle" ]]
}

is_recommended_step() {
  is_experimental_step "$1" && return 1
  is_opt_in_step "$1" && return 1
  is_high_idle_step "$1" && return 1
  return 0
}

is_laptop_recommended_step() {
  is_recommended_step "$1" || return 1
  [[ "${STEP_LAPTOP_REC[$1]:-true}" == "true" ]]
}

run_recommended_batch() {
  local mode="$1" scope="${2:-all}" step targets=() out_of_scope=()
  local filter_fn="is_recommended_step"
  local scope_title="Recommended" scope_label="recommended"
  if [[ "$scope" == "laptop" ]]; then
    filter_fn="is_laptop_recommended_step"
    scope_title="Laptop-Recommended"
    scope_label="laptop-recommended"
  fi

  for step in "${ACTIVE_STEPS[@]}"; do
    if "$filter_fn" "$step"; then
      if [[ "$mode" == "apply" ]]; then
        "status_${step}" || targets+=("$step")
      else
        "status_${step}" && targets+=("$step")
      fi
    elif [[ "$mode" == "apply" ]] && "status_${step}"; then
      out_of_scope+=("$step")
    fi
  done

  print_header
  if [[ "$mode" == "apply" ]]; then
    echo -e "${C_BOLD}Apply ${scope_title} Performance Optimizations${C_RESET}"
  else
    echo -e "${C_BOLD}Revert ${scope_title} Performance Optimizations${C_RESET}"
  fi
  local has_warn_ex=false has_opt_ex=false has_exp_ex=false
  local -a batch_excl=()
  for step in "${ACTIVE_STEPS[@]}"; do
    is_high_idle_step "$step" && has_warn_ex=true
    is_experimental_step "$step" && has_exp_ex=true
    is_opt_in_step "$step" && has_opt_ex=true
  done
  if [[ "$scope" == "laptop" ]]; then
    [[ "$has_warn_ex" == true ]] && batch_excl+=("high-idle-power options ([!])")
    [[ "$has_opt_ex" == true ]] && batch_excl+=("opt-in trade-offs ([OPT])")
    [[ "$has_exp_ex" == true ]] && batch_excl+=("experimental options ([EXP])")
    batch_excl+=("prevent sleep" "GPU high-idle-clock/persistence" "platform & vendor performance profiles" "Strata setup")
  else
    [[ "$has_warn_ex" == true ]] && batch_excl+=("high-idle-power options ([!]: CPU Performance, PCIe ASPM, CPU C-State Limit, NVIDIA Clock Lock, tuned profile)")
    [[ "$has_opt_ex" == true ]] && batch_excl+=("opt-in trade-offs ([OPT])")
    [[ "$has_exp_ex" == true ]] && batch_excl+=("experimental options ([EXP])")
    batch_excl+=("Strata setup")
  fi
  local batch_excl_str="" _bi=0
  for (( _bi = 0; _bi < ${#batch_excl[@]}; _bi++ )); do
    (( _bi > 0 )) && batch_excl_str+=", "
    batch_excl_str+="${batch_excl[$_bi]}"
  done
  echo -e "${C_DIM}Excluded: ${batch_excl_str}.${C_RESET}\n"

  if [[ ${#targets[@]} -eq 0 && ${#out_of_scope[@]} -eq 0 ]]; then
    if [[ "$mode" == "apply" ]]; then
      echo -e "${C_GREEN}All ${scope_label} optimizations for this machine are already applied.${C_RESET}"
    else
      echo -e "${C_YELLOW}No applied ${scope_label} optimizations found to revert.${C_RESET}"
    fi
    pause_prompt
    return 0
  fi

  local i=1
  if (( ${#targets[@]} > 0 )); then
    for step in "${targets[@]}"; do
      echo -e "  $i) $("title_${step}")"
      ((i++))
    done
    echo ""
  elif [[ "$mode" == "apply" ]]; then
    echo -e "${C_GREEN}All ${scope_label} optimizations for this machine are already applied.${C_RESET}\n"
  fi

  if [[ "$mode" == "apply" ]] && (( ${#out_of_scope[@]} > 0 )); then
    echo -e "${C_YELLOW}Currently applied option(s) outside the ${scope_label} scope:${C_RESET}"
    i=1
    for step in "${out_of_scope[@]}"; do
      echo -e "  $i) $("title_${step}")"
      ((i++))
    done
    echo ""
  fi

  local prompt_verb="Apply" revert_out_of_scope=false
  [[ "$mode" == "revert" ]] && prompt_verb="Revert"

  if (( ${#targets[@]} > 0 )); then
    if ! confirm_yn "${prompt_verb} these ${#targets[@]} ${scope_label} optimization(s)? [y/N]: " "N"; then
      echo -e "${C_DIM}Cancelled.${C_RESET}"
      pause_prompt
      return 0
    fi
    if [[ "$mode" == "apply" ]] && (( ${#out_of_scope[@]} > 0 )); then
      if confirm_yn "Also revert the ${#out_of_scope[@]} out-of-scope optimization(s) listed above (default: leave as is)? [y/N]: " "N"; then
        revert_out_of_scope=true
      fi
    fi
  elif [[ "$mode" == "apply" ]] && (( ${#out_of_scope[@]} > 0 )); then
    if confirm_yn "Revert these ${#out_of_scope[@]} out-of-scope optimization(s) (default: leave as is)? [y/N]: " "N"; then
      revert_out_of_scope=true
    else
      echo -e "${C_DIM}Left out-of-scope optimizations as is.${C_RESET}"
      pause_prompt
      return 0
    fi
  fi

  for step in "${targets[@]}"; do
    if [[ "$mode" == "apply" && "$step" == "nvidia_power_limit" ]] && status_nvidia_power_cap && [[ "$revert_out_of_scope" == false ]]; then
      echo -e "\n${C_YELLOW}Skipping NVIDIA Persistent Max GPU Power Limit because NVIDIA Thermal Power Cap ([OPT]) was kept active.${C_RESET}"
      continue
    fi
    echo -e "\n${C_BOLD}${C_CYAN}>>> ${prompt_verb}ing: $("title_${step}")${C_RESET}"
    "${mode}_${step}" || echo -e "${C_YELLOW}Step '${step}' exited with a warning or was skipped.${C_RESET}"
  done
  if [[ "$revert_out_of_scope" == true ]]; then
    for step in "${out_of_scope[@]}"; do
      echo -e "\n${C_BOLD}${C_YELLOW}>>> Reverting out-of-scope: $("title_${step}")${C_RESET}"
      "revert_${step}" || echo -e "${C_YELLOW}Step '${step}' exited with a warning or was skipped.${C_RESET}"
    done
  fi
  echo -e "\n${C_GREEN}Finished ${mode}ing ${scope_label} optimizations.${C_RESET}"
  prompt_reboot_if_needed
  pause_prompt
}

_pmset_ac_val() {
  local key="$1" val=""
  val="$(pmset -g custom 2>/dev/null | awk -v k="$key" '
    /^AC Power:/ { in_ac=1; next }
    /^[A-Za-z].*:/ { in_ac=0 }
    in_ac && $1 == k { print $2; found=1; exit }
    END { if (!found) exit 1 }
  ')" || val="$(pmset -g 2>/dev/null | awk -v k="$key" '$1 == k { print $2; exit }')"
  printf '%s' "$val"
}


_parse_macos_powermetrics() {
  local fmt="${1:-%.2f}" pm_out="$2"
  awk -v fmt="$fmt" '
    /GPU (HW )?active residency:/ { if (match($0, /[0-9]+(\.[0-9]+)?%/)) { gres = sprintf("%.0f", substr($0, RSTART, RLENGTH-1)+0) } }
    /GPU Power:/ { if (match($0, /[0-9]+(\.[0-9]+)?[[:space:]]*m?W/)) { s=substr($0,RSTART,RLENGTH); v=s+0; gp=(s~/mW/)?v/1000.0:v } }
    /CPU Power:/ { if (match($0, /[0-9]+(\.[0-9]+)?[[:space:]]*m?W/)) { s=substr($0,RSTART,RLENGTH); v=s+0; cp=(s~/mW/)?v/1000.0:v } }
    /ANE Power:/ { if (match($0, /[0-9]+(\.[0-9]+)?[[:space:]]*m?W/)) { s=substr($0,RSTART,RLENGTH); v=s+0; anep=(s~/mW/)?v/1000.0:v } }
    /Combined Power/ { if (match($0, /[0-9]+(\.[0-9]+)?[[:space:]]*m?W/)) { s=substr($0,RSTART,RLENGTH); v=s+0; sp=(s~/mW/)?v/1000.0:v } }
    /Current pressure level:/ { thr=$NF }
    END {
      if (sp == "" && gp != "" && cp != "") sp = gp + cp + anep
      printf "%s|%s|%s|%s|%s", gres, (gp!=""?sprintf(fmt,gp):""), (cp!=""?sprintf(fmt,cp):""), (sp!=""?sprintf(fmt,sp):""), thr
    }' <<< "$pm_out"
}

_read_sysfs_bat_watts() {
  local fmt="${1:-%.2f}" bat_d bat_st cur_ua volt_uv uw
  for bat_d in /sys/class/power_supply/BAT*; do
    [[ -d "$bat_d" ]] || continue
    if [[ -r "$bat_d/power_now" ]]; then
      uw="$(cat "$bat_d/power_now" 2>/dev/null || echo 0)"
      [[ "$uw" =~ ^[0-9]+$ ]] && (( uw > 0 )) && { awk -v fmt="$fmt" -v u="$uw" 'BEGIN{printf fmt, u/1000000.0}'; return 0; }
    elif [[ -r "$bat_d/current_now" && -r "$bat_d/voltage_now" ]]; then
      bat_st="$(cat "$bat_d/status" 2>/dev/null || true)"
      cur_ua="$(cat "$bat_d/current_now" 2>/dev/null || echo 0)"
      volt_uv="$(cat "$bat_d/voltage_now" 2>/dev/null || echo 0)"
      if [[ "$bat_st" == "Discharging" && "$cur_ua" =~ ^[0-9]+$ && "$volt_uv" =~ ^[0-9]+$ ]] && (( cur_ua > 0 && volt_uv > 0 )); then
        awk -v fmt="$fmt" -v c="$cur_ua" -v v="$volt_uv" 'BEGIN{printf fmt, (c/1000000.0)*(v/1000000.0)}'
        return 0
      fi
    fi
  done
  return 1
}

_read_sysfs_psu_watts() {
  local fmt="${1:-%.2f}" hm_dir hm_name pf uw
  for hm_dir in "${STRATA_HWMON_DIR:-/sys/class/hwmon}"/hwmon*; do
    [[ -r "$hm_dir/name" ]] || continue
    hm_name="$(cat "$hm_dir/name" 2>/dev/null || true)"
    case "$hm_name" in
      corsair-psu|acpi_power_meter|power_meter)
        for pf in "$hm_dir"/power1_input "$hm_dir"/power1_average; do
          if [[ -r "$pf" ]]; then
            uw="$(cat "$pf" 2>/dev/null || echo 0)"
            [[ "$uw" =~ ^[0-9]+$ ]] && (( uw > 0 )) && { awk -v fmt="$fmt" -v u="$uw" 'BEGIN{printf fmt, u/1000000.0}'; return 0; }
          fi
        done
        ;;
    esac
  done
  _read_sysfs_bat_watts "$fmt"
}

start_bench_power_sampler() {
  local out_file="$1"
  (
    local n=0 gpu_sum="0" cpu_sum="0" sys_sum="0" gpu_n=0 cpu_n=0 sys_n=0
    local stop=false
    trap 'stop=true' TERM INT USR1
    if [[ "$IS_MACOS" == true ]]; then
      local can_pm=false pm_prefix=()
      if command -v powermetrics >/dev/null 2>&1; then
        if [[ $EUID -eq 0 ]]; then
          can_pm=true
        elif sudo -n true >/dev/null 2>&1; then
          can_pm=true
          pm_prefix=(sudo -n)
        fi
      fi
      while [[ "$stop" == false ]]; do
        if [[ "$can_pm" == true ]]; then
          local pm_out pm_parsed pg pc ps
          pm_out="$("${pm_prefix[@]}" powermetrics -n 1 -i 250 --samplers cpu_power,gpu_power 2>/dev/null || true)"
          if [[ -n "$pm_out" ]]; then
            pm_parsed="$(_parse_macos_powermetrics "%.2f" "$pm_out")"
            IFS='|' read -r _ pg pc ps _ <<< "$pm_parsed"
            if [[ -n "$pg" ]]; then
              gpu_sum="$(awk -v a="$gpu_sum" -v b="$pg" 'BEGIN{printf "%.2f", a + b}')"
              ((gpu_n++))
            fi
            if [[ -n "$pc" ]]; then
              cpu_sum="$(awk -v a="$cpu_sum" -v b="$pc" 'BEGIN{printf "%.2f", a + b}')"
              ((cpu_n++))
            fi
            if [[ -n "$ps" ]]; then
              sys_sum="$(awk -v a="$sys_sum" -v b="$ps" 'BEGIN{printf "%.2f", a + b}')"
              ((sys_n++))
            fi
          fi
          ((n++))
          (sleep 0.1 2>/dev/null || sleep 1) &
          wait $! 2>/dev/null || true
        else
          ((n++))
          (sleep 0.5 2>/dev/null || sleep 1) &
          wait $! 2>/dev/null || true
        fi
      done
    else
      local prev_uj="" prev_us="" rapl_f="/sys/class/powercap/intel-rapl:0/energy_uj" rapl_mode="none"
      local -A prev_intel_uj=() prev_intel_us=()
      if [[ -r "$rapl_f" ]]; then
        rapl_mode="direct"
      elif [[ -e "$rapl_f" ]] && sudo -n true >/dev/null 2>&1; then
        rapl_mode="sudo"
      fi
      while [[ "$stop" == false ]]; do
        local gw="0" has_g=false
        if [[ "$HAS_NVIDIA" == true ]] && command -v nvidia-smi >/dev/null 2>&1; then
          local nv_p
          nv_p="$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | awk '{if($1~/^[0-9]+(\.[0-9]+)?$/){s+=$1; c++}} END{if(c>0) printf "%.2f", s}')"
          if [[ -n "$nv_p" ]]; then gw="$nv_p"; has_g=true; fi
        fi
        if [[ "$HAS_AMD" == true ]]; then
          local drm_dir="${STRATA_DRM_DIR:-/sys/class/drm}" card_dir hwmon_dir pa ven
          for card_dir in "${drm_dir}"/card[0-9]*/device; do
            [[ -d "$card_dir" ]] || continue
            if [[ -r "$card_dir/vendor" ]]; then
              ven="$(tr '[:upper:]' '[:lower:]' < "$card_dir/vendor" 2>/dev/null || true)"
              [[ "$ven" == "0x1002" ]] || continue
            fi
            for hwmon_dir in "$card_dir"/hwmon/hwmon*; do
              if [[ -r "$hwmon_dir/power1_average" ]]; then
                pa="$(cat "$hwmon_dir/power1_average" 2>/dev/null || echo 0)"
                if [[ "$pa" =~ ^[0-9]+$ ]] && (( pa > 0 )); then
                  gw="$(awk -v a="$gw" -v b="$pa" 'BEGIN{printf "%.2f", a + b/1000000.0}')"
                  has_g=true
                  break
                fi
              fi
            done
          done
        fi
        if [[ "$HAS_INTEL_ARC" == true ]]; then
          local drm_dir="${STRATA_DRM_DIR:-/sys/class/drm}" card_dir hwmon_dir ven did pa e_uj e_us de dt_us
          for card_dir in "${drm_dir}"/card[0-9]*/device; do
            [[ -r "$card_dir/vendor" && -r "$card_dir/device" ]] || continue
            ven="$(tr '[:upper:]' '[:lower:]' < "$card_dir/vendor" 2>/dev/null || true)"
            [[ "$ven" == "0x8086" ]] || continue
            did="$(tr '[:upper:]' '[:lower:]' < "$card_dir/device" 2>/dev/null || true)"
            _is_intel_discrete_pci_id "$did" || continue
            for hwmon_dir in "$card_dir"/hwmon/hwmon*; do
              if [[ -r "$hwmon_dir/power1_average" ]]; then
                pa="$(cat "$hwmon_dir/power1_average" 2>/dev/null || echo 0)"
                if [[ "$pa" =~ ^[0-9]+$ ]] && (( pa > 0 )); then
                  gw="$(awk -v a="$gw" -v b="$pa" 'BEGIN{printf "%.2f", a + b/1000000.0}')"
                  has_g=true
                  break
                fi
              elif [[ -r "$hwmon_dir/energy1_input" ]]; then
                e_uj="$(cat "$hwmon_dir/energy1_input" 2>/dev/null || true)"
                e_us="$(date +%s%6N 2>/dev/null || true)"
                if [[ "$e_uj" =~ ^[0-9]+$ && "$e_us" =~ ^[0-9]+$ ]]; then
                  if [[ -n "${prev_intel_uj[$hwmon_dir]:-}" && -n "${prev_intel_us[$hwmon_dir]:-}" ]]; then
                    de=$(( e_uj - prev_intel_uj[$hwmon_dir] ))
                    dt_us=$(( e_us - prev_intel_us[$hwmon_dir] ))
                    if (( de >= 0 && dt_us > 0 )); then
                      gw="$(awk -v a="$gw" -v de="$de" -v dt="$dt_us" 'BEGIN{printf "%.2f", a + (de/dt)}')"
                      has_g=true
                    fi
                  fi
                  prev_intel_uj[$hwmon_dir]="$e_uj"
                  prev_intel_us[$hwmon_dir]="$e_us"
                  break
                fi
              fi
            done
          done
        fi
        if [[ "$has_g" == true ]]; then
          gpu_sum="$(awk -v a="$gpu_sum" -v b="$gw" 'BEGIN{printf "%.2f", a + b}')"
          ((gpu_n++))
        fi
        if [[ "$IS_JETSON" == true ]]; then
          local j_sw="" j_gw="" j_cw=""
          IFS='|' read -r j_sw j_gw j_cw <<< "$(read_jetson_ina3221_watts)"
          if [[ "$has_g" == false && -n "$j_gw" ]]; then
            gpu_sum="$(awk -v a="$gpu_sum" -v b="$j_gw" 'BEGIN{printf "%.2f", a + b}')"
            ((gpu_n++))
          fi
          if [[ -n "$j_cw" ]]; then
            cpu_sum="$(awk -v a="$cpu_sum" -v b="$j_cw" 'BEGIN{printf "%.2f", a + b}')"
            ((cpu_n++))
          fi
          if [[ -n "$j_sw" ]]; then
            sys_sum="$(awk -v a="$sys_sum" -v b="$j_sw" 'BEGIN{printf "%.2f", a + b}')"
            ((sys_n++))
          fi
        fi

        if [[ "$rapl_mode" != "none" ]]; then
          local uj us
          if [[ "$rapl_mode" == "direct" ]]; then
            uj="$(cat "$rapl_f" 2>/dev/null || true)"
          else
            uj="$(sudo -n cat "$rapl_f" 2>/dev/null || true)"
          fi
          us="$(date +%s%6N 2>/dev/null || true)"
          if [[ "$uj" =~ ^[0-9]+$ && "$us" =~ ^[0-9]+$ ]]; then
            if [[ -n "$prev_uj" && -n "$prev_us" ]]; then
              local de=$((uj - prev_uj)) dt=$((us - prev_us))
              if (( de >= 0 && dt > 0 )); then
                cpu_sum="$(awk -v a="$cpu_sum" -v de="$de" -v dt="$dt" 'BEGIN{printf "%.2f", a + (de/dt)}')"
                ((cpu_n++))
              fi
            fi
            prev_uj="$uj"; prev_us="$us"
          fi
        fi

        local sw=""
        sw="$(_read_sysfs_psu_watts "%.2f" || true)"
        if [[ -n "$sw" ]]; then
          sys_sum="$(awk -v a="$sys_sum" -v b="$sw" 'BEGIN{printf "%.2f", a + b}')"
          ((sys_n++))
        fi

        ((n++))
        (sleep 0.25 2>/dev/null || sleep 1) &
        wait $! 2>/dev/null || true
      done
    fi

    local avg_g="" avg_c="" avg_s=""
    (( gpu_n > 0 )) && avg_g="$(awk -v s="$gpu_sum" -v c="$gpu_n" 'BEGIN{printf "%.1f", s/c}')"
    (( cpu_n > 0 )) && avg_c="$(awk -v s="$cpu_sum" -v c="$cpu_n" 'BEGIN{printf "%.1f", s/c}')"
    if (( sys_n > 0 )); then
      avg_s="$(awk -v s="$sys_sum" -v c="$sys_n" 'BEGIN{printf "%.1f", s/c}')"
    elif [[ -n "$avg_g" && -n "$avg_c" ]]; then
      avg_s="$(awk -v g="$avg_g" -v c="$avg_c" 'BEGIN{printf "~%.1f", g+c}')"
    fi
    printf "%s|%s|%s|%d\n" "$avg_s" "$avg_g" "$avg_c" "$n" > "$out_file"
  ) &
  BENCH_POWER_SAMPLER_PID=$!
}

stop_bench_power_sampler() {
  if [[ -n "$BENCH_POWER_SAMPLER_PID" ]]; then
    kill -TERM "$BENCH_POWER_SAMPLER_PID" 2>/dev/null || true
    wait "$BENCH_POWER_SAMPLER_PID" 2>/dev/null || true
    BENCH_POWER_SAMPLER_PID=""
  fi
}


# ------------------------------------------------------------------------------
# TUI Wizard Engine
# ------------------------------------------------------------------------------
print_logo() {
  local rule_w="${1:-70}"
  local logo_w=50
  local pad=$(( (rule_w - logo_w) / 2 ))
  (( pad < 0 )) && pad=0
  local indent=""
  printf -v indent "%*s" "$pad" ""
  if [[ -t 1 ]]; then
    echo -e "${indent}\033[1;96m███████╗████████╗██████╗  █████╗ ████████╗ █████╗ \033[0m"
    echo -e "${indent}\033[0;96m██╔════╝╚══██╔══╝██╔══██╗██╔══██╗╚══██╔══╝██╔══██╗\033[0m"
    echo -e "${indent}\033[0;36m███████╗   ██║   ██████╔╝███████║   ██║   ███████║\033[0m"
    echo -e "${indent}\033[1;34m╚════██║   ██║   ██╔══██╗██╔══██║   ██║   ██╔══██║\033[0m"
    echo -e "${indent}\033[0;35m███████║   ██║   ██║  ██║██║  ██║   ██║   ██║  ██║\033[0m"
    echo -e "${indent}\033[2;35m╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝\033[0m"
    echo -e "${indent}\033[0;36m═══════ \033[1;96mP E R F O R M A N C E   \033[1;35mS E T U P \033[0;35m════════\033[0m\n"
  else
    echo "${indent}STRATA - PERFORMANCE SETUP"
  fi
}

render_bar() {
  local pct="$1" width="${2:-40}"
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local color="$C_GREEN"
  if (( pct >= 85 )); then color="$C_RED"
  elif (( pct >= 60 )); then color="$C_YELLOW"
  fi
  local bar_fill="" bar_empty="" i
  for ((i=0; i<filled; i++)); do bar_fill+="█"; done
  for ((i=0; i<empty; i++)); do bar_empty+="░"; done
  printf "%b%s%b%s%b" "$color" "$bar_fill" "$C_DIM" "$bar_empty" "$C_RESET"
}

format_temp() {
  local t="$1" color="$C_GREEN"
  if (( t >= 85 )); then color="$C_RED"
  elif (( t >= 70 )); then color="$C_YELLOW"
  fi
  printf "%b%d°C%b" "$color" "$t" "$C_RESET"
}

print_live_stats() {
  local inplace="${1:-false}" eol=""
  [[ "$inplace" == true ]] && eol=$'\033[K'

  local cpu_pct="" ram_pct="" ram_used_gib="" ram_tot_gib=""
  local gpu_pct="" vram_pct="" vram_used_gib="" vram_tot_gib=""
  local pwr_w="" pwr_lim_w="" pwr_pct="" pwr_label="Power"
  local gpu_pcts=() vram_pcts=() vram_useds=() vram_tots=() vram_labels=() pwr_ws=() pwr_lim_ws=() pwr_pcts=() gpu_temps=() gpu_notes=() gpu_thr_tags=()
  local total_gpu_pwr_w="" cpu_temp="" sys_pwr_w="" cpu_pwr_w=""
  local rapl_file="/sys/class/powercap/intel-rapl:0/energy_uj" rapl_can_read=false pm_attempted=false

  if [[ "$IS_MACOS" == true ]]; then
    # CPU usage (Mach host_statistics ticks delta, fallback ps aggregate)
    if [[ "${PREV_CPU_TOTAL:-}" != "unavailable" ]] && has_working_python3; then
      local _py_cpu_cmd tot_now="" idle_now=""
      _py_cpu_cmd='import ctypes
libc = ctypes.CDLL("/usr/lib/libc.dylib")
class H(ctypes.Structure):
    _fields_ = [("t", ctypes.c_uint * 4)]
i = H(); c = ctypes.c_uint(4)
if libc.host_statistics(libc.mach_host_self(), 3, ctypes.byref(i), ctypes.byref(c)) == 0:
    u, s, idle, nice = i.t
    print(f"{u + s + idle + nice} {idle}")'
      if [[ -z "$PREV_CPU_TOTAL" ]]; then
        read -r PREV_CPU_TOTAL PREV_CPU_IDLE <<< "$(python3 -c "$_py_cpu_cmd" 2>/dev/null || true)"
        if [[ -n "$PREV_CPU_TOTAL" ]]; then
          sleep 0.15
        else
          PREV_CPU_TOTAL="unavailable"
        fi
      fi
      if [[ "$PREV_CPU_TOTAL" != "unavailable" ]]; then
        read -r tot_now idle_now <<< "$(python3 -c "$_py_cpu_cmd" 2>/dev/null || true)"
        if [[ "$tot_now" =~ ^[0-9]+$ && "$idle_now" =~ ^[0-9]+$ && "$PREV_CPU_TOTAL" =~ ^[0-9]+$ && "$PREV_CPU_IDLE" =~ ^[0-9]+$ ]]; then
          local dt=$((tot_now - PREV_CPU_TOTAL)) di=$((idle_now - PREV_CPU_IDLE))
          if (( dt > 0 )); then
            cpu_pct=$(( (dt - di) * 100 / dt ))
            (( cpu_pct < 0 )) && cpu_pct=0
            (( cpu_pct > 100 )) && cpu_pct=100
            PREV_CPU_TOTAL="$tot_now"
            PREV_CPU_IDLE="$idle_now"
          fi
        fi
      fi
    fi
    if [[ -z "$cpu_pct" ]]; then
      local _ncpu
      _ncpu="${STRATA_MACOS_THREADS:-${MACOS_CPU_THREADS:-$(sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)}}"
      [[ "$_ncpu" =~ ^[0-9]+$ && "$_ncpu" -gt 0 ]] || _ncpu=1
      cpu_pct="$(ps -A -o %cpu= 2>/dev/null | awk -v n="$_ncpu" '{s+=$1} END {p=int(s/n+0.5); if(p<0)p=0; if(p>100)p=100; print p}')"
    fi

    # RAM usage (vm_stat + hw.memsize)
    local mem_bytes vm_out
    mem_bytes="${STRATA_MACOS_RAM_BYTES:-${MACOS_RAM_BYTES:-0}}"
    if ! [[ "$mem_bytes" =~ ^[0-9]+$ ]] || (( mem_bytes == 0 )); then
      mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    fi
    vm_out="$(vm_stat 2>/dev/null || true)"
    if [[ "$mem_bytes" =~ ^[0-9]+$ && "$mem_bytes" -gt 0 && -n "$vm_out" ]]; then
      local mem_stats def_ps=4096
      [[ "$IS_APPLE_SILICON" == true ]] && def_ps=16384
      mem_stats="$(awk -v tot_b="$mem_bytes" -v def_ps="$def_ps" '
        /page size of [0-9]+ bytes/ { for(i=1;i<=NF;i++) if($i~/^[0-9]+$/){ps=$i; break} }
        /^Anonymous pages:/ { gsub(/\./,"",$NF); anon=$NF; has_anon=1 }
        /^Pages purgeable:/ { gsub(/\./,"",$NF); pur=$NF }
        /^Pages wired down:/ { gsub(/\./,"",$NF); wired=$NF }
        /^Pages occupied by compressor:/ { gsub(/\./,"",$NF); comp=$NF }
        /^Pages active:/ { gsub(/\./,"",$NF); active=$NF }
        END {
          if (ps <= 0) ps = def_ps
          used_p = has_anon ? ((anon - pur) + wired + comp) : (active + wired + comp)
          if (used_p < 0) used_p = 0
          u = used_p * ps
          if (u > tot_b) u = tot_b
          printf "%d %.1f %.1f", int(u * 100 / tot_b + 0.5), u / 1073741824, tot_b / 1073741824
        }' <<< "$vm_out")"
      [[ -n "$mem_stats" ]] && read -r ram_pct ram_used_gib ram_tot_gib <<< "$mem_stats"
    fi

    # Apple Silicon GPU utilization, unified memory allocation, powermetrics wattage & thermal pressure
    if [[ "$IS_APPLE_SILICON" == true ]]; then
      local g_pct="" v_pct="" v_used="" v_tot="" pw="" g_note="" g_thr="" ioreg_out="" in_use_b=""
      if command -v ioreg >/dev/null 2>&1; then
        ioreg_out="$(ioreg -r -d 1 -w 0 -c IOAccelerator 2>/dev/null || true)"
        if [[ -n "$ioreg_out" ]]; then
          local _re_du='"Device Utilization %"[[:space:]]*=[[:space:]]*([0-9]+)'
          local _re_ru='"Renderer Utilization %"[[:space:]]*=[[:space:]]*([0-9]+)'
          local _re_mem='"In use system memory"[[:space:]]*=[[:space:]]*([0-9]+)'
          local _re_amem='"Alloc system memory"[[:space:]]*=[[:space:]]*([0-9]+)'
          if [[ "$ioreg_out" =~ $_re_du ]]; then
            g_pct="${BASH_REMATCH[1]}"
          elif [[ "$ioreg_out" =~ $_re_ru ]]; then
            g_pct="${BASH_REMATCH[1]}"
          fi
          if [[ "$ioreg_out" =~ $_re_mem ]]; then
            in_use_b="${BASH_REMATCH[1]}"
          elif [[ "$ioreg_out" =~ $_re_amem ]]; then
            in_use_b="${BASH_REMATCH[1]}"
          fi
        fi
      fi
      local pm_out="" pm_cmd=()
      if command -v powermetrics >/dev/null 2>&1; then
        if [[ $EUID -eq 0 ]]; then
          pm_cmd=(powermetrics)
        elif sudo -n true >/dev/null 2>&1; then
          pm_cmd=(sudo -n powermetrics)
        fi
      fi
      if (( ${#pm_cmd[@]} > 0 )); then
        pm_attempted=true
        pm_out="$("${pm_cmd[@]}" -n 1 -i 200 --samplers cpu_power,gpu_power,thermal 2>/dev/null || true)"
        if [[ -n "$pm_out" ]]; then
          local pm_res pm_gp pm_cp pm_sp pm_thr
          pm_res="$(_parse_macos_powermetrics "%.0f" "$pm_out")"
          IFS='|' read -r pm_res pm_gp pm_cp pm_sp pm_thr <<< "$pm_res"
          [[ -n "$pm_res" ]] && g_pct="$pm_res"
          [[ -n "$pm_gp" ]] && { pw="$pm_gp"; total_gpu_pwr_w="$pm_gp"; }
          [[ -n "$pm_cp" ]] && cpu_pwr_w="$pm_cp"
          [[ -n "$pm_sp" ]] && sys_pwr_w="$pm_sp"
          case "$pm_thr" in
            Heavy|Trapping|Sleeping) g_thr=" ${C_RED}[THROTTLE]${C_RESET}" ;;
            Moderate) g_note="Thermal: Moderate" ;;
          esac
        fi
      fi
      if [[ "$in_use_b" =~ ^[0-9]+$ && "$RAM_GB" -gt 0 ]]; then
        local wl_mb cap_gib
        wl_mb="${STRATA_MACOS_WIRED_LIMIT_MB:-${MACOS_WIRED_LIMIT_MB:-}}"
        if ! [[ "$wl_mb" =~ ^[0-9]+$ ]]; then
          wl_mb="$(_macos_wired_limit_cur_mb)"
        fi
        if (( wl_mb > 0 )); then
          cap_gib="$(awk -v m="$wl_mb" 'BEGIN{printf "%.1f", m/1024.0}')"
        else
          cap_gib="$(awk -v r="$RAM_GB" 'BEGIN{printf "%.1f", r*0.75}')"
        fi
        read -r v_pct v_used v_tot <<< "$(awk -v u="$in_use_b" -v c="$cap_gib" 'BEGIN{ug=u/1073741824.0; p=(c>0)?int((ug/c)*100+0.5):0; if(p>100)p=100; printf "%d %.1f %.1f", p, ug, c}')"
      fi
      if [[ -n "$g_pct" || -n "$v_pct" || -n "$pw" || -n "$g_note" || -n "$g_thr" ]]; then
        gpu_pcts+=("$g_pct")
        vram_pcts+=("$v_pct")
        vram_useds+=("$v_used")
        vram_tots+=("$v_tot")
        vram_labels+=("Unified")
        pwr_ws+=("$pw")
        pwr_lim_ws+=("")
        pwr_pcts+=("")
        gpu_temps+=("")
        gpu_notes+=("$g_note")
        gpu_thr_tags+=("$g_thr")
      fi
    fi
  else
    if [[ -r "$rapl_file" ]]; then
      rapl_can_read=true
    elif [[ -e "$rapl_file" ]] && sudo -n true >/dev/null 2>&1; then
      rapl_can_read=true
    fi

    # CPU usage (/proc/stat delta; 150ms sample only on first call)
    if [[ -r /proc/stat ]]; then
      local u1 n1 s1 i1 w1 q1 sq1 st1 idle_now tot_now
      if [[ -z "$PREV_CPU_TOTAL" ]]; then
        read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
        PREV_CPU_IDLE=$((i1 + w1))
        PREV_CPU_TOTAL=$((u1 + n1 + s1 + PREV_CPU_IDLE + q1 + sq1 + st1))
        if [[ "$rapl_can_read" == true ]]; then
          if [[ -r "$rapl_file" ]]; then
            PREV_RAPL_UJ="$(cat "$rapl_file" 2>/dev/null || true)"
          else
            PREV_RAPL_UJ="$(sudo -n cat "$rapl_file" 2>/dev/null || true)"
          fi
          PREV_RAPL_US="$(date +%s%6N 2>/dev/null || true)"
        fi
        sleep 0.15
      fi
      read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
      idle_now=$((i1 + w1))
      tot_now=$((u1 + n1 + s1 + idle_now + q1 + sq1 + st1))
      local dt=$((tot_now - PREV_CPU_TOTAL)) di=$((idle_now - PREV_CPU_IDLE))
      if (( dt > 0 )); then
        cpu_pct=$(( (dt - di) * 100 / dt ))
        PREV_CPU_TOTAL="$tot_now"
        PREV_CPU_IDLE="$idle_now"
      fi
    fi

    # RAM usage (/proc/meminfo)
    if [[ -r /proc/meminfo ]]; then
      local mem_stats
      mem_stats="$(awk '
        /^MemTotal:/ {t=$2}
        /^MemAvailable:/ {a=$2}
        END {
          if (t > 0) {
            u = t - a
            printf "%d %.1f %.1f", int(u * 100 / t + 0.5), u / 1048576, t / 1048576
          }
        }' /proc/meminfo 2>/dev/null || true)"
      if [[ -n "$mem_stats" ]]; then
        read -r ram_pct ram_used_gib ram_tot_gib <<< "$mem_stats"
      fi
    fi

    # GPU, VRAM, Power, and Temp (supports NVIDIA, AMD, Intel Arc, and Jetson)
    if [[ "$HAS_NVIDIA" == true ]] && command -v nvidia-smi >/dev/null 2>&1; then
      local nv_lines nv_parsed nv_line
      nv_lines="$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,power.draw,power.limit,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || true)"
      if [[ -n "$nv_lines" ]]; then
        local -a nv_pstates=() nv_thr_active=()
        local nv_extra="" eline ei_pstate ei_hw ei_sw
        if [[ -z "$NVIDIA_LIVE_EXTRA_FIELDS" ]]; then
          nv_extra="$(nvidia-smi --query-gpu=pstate,clocks_event_reasons.hw_thermal_slowdown,clocks_event_reasons.sw_thermal_slowdown --format=csv,noheader 2>/dev/null || true)"
          if [[ -n "$nv_extra" ]] && ! grep -qiE "not a valid|field.*not" <<<"$nv_extra"; then
            NVIDIA_LIVE_EXTRA_FIELDS="pstate,clocks_event_reasons.hw_thermal_slowdown,clocks_event_reasons.sw_thermal_slowdown"
          else
            nv_extra="$(nvidia-smi --query-gpu=pstate,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_thermal_slowdown --format=csv,noheader 2>/dev/null || true)"
            if [[ -n "$nv_extra" ]] && ! grep -qiE "not a valid|field.*not" <<<"$nv_extra"; then
              NVIDIA_LIVE_EXTRA_FIELDS="pstate,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_thermal_slowdown"
            else
              NVIDIA_LIVE_EXTRA_FIELDS="pstate"
              nv_extra="$(nvidia-smi --query-gpu=pstate --format=csv,noheader 2>/dev/null || true)"
            fi
          fi
        else
          nv_extra="$(nvidia-smi --query-gpu="$NVIDIA_LIVE_EXTRA_FIELDS" --format=csv,noheader 2>/dev/null || true)"
        fi
        while IFS= read -r eline; do
          [[ -n "$eline" ]] || continue
          ei_pstate="" ei_hw="" ei_sw=""
          IFS=',' read -r ei_pstate ei_hw ei_sw <<< "$eline"
          ei_pstate="${ei_pstate//[[:space:]]/}"
          ei_hw="${ei_hw//[[:space:]]/}"
          ei_sw="${ei_sw//[[:space:]]/}"
          [[ "$ei_pstate" =~ ^P[0-9]+$ ]] || ei_pstate=""
          nv_pstates+=("$ei_pstate")
          if [[ "$ei_hw" == "Active" || "$ei_sw" == "Active" ]]; then
            nv_thr_active+=("true")
          else
            nv_thr_active+=("false")
          fi
        done <<< "$nv_extra"

        nv_parsed="$(awk -F', *' '
          function isnum(s) { return s ~ /^[0-9]+(\.[0-9]+)?$/ }
          {
            for (i=1; i<=6; i++) gsub(/ /, "", $i)
            gp = isnum($1) ? sprintf("%.0f", $1) : ""
            gt = isnum($6) ? sprintf("%.0f", $6) : ""
            vp = ""; vu = ""; vt = ""
            if (isnum($2) && isnum($3) && ($3 + 0) > 0) {
              vp = sprintf("%.0f", ($2 / $3) * 100)
              vu = sprintf("%.1f", $2 / 1024)
              vt = sprintf("%.1f", $3 / 1024)
            }
            pw = ""; plw = ""; pp = ""
            if (isnum($4)) {
              pw = sprintf("%.0f", $4)
              if (isnum($5) && ($5 + 0) > 0) {
                plw = sprintf("%.0f", $5)
                pp = sprintf("%.0f", ($4 / $5) * 100)
              }
            }
            printf "%s|%s|%s|%s|%s|%s|%s|%s\n", gp, vp, vu, vt, pw, plw, pp, gt
          }
        ' <<< "$nv_lines")"
        local nv_ri=0
        while IFS= read -r nv_line; do
          [[ -n "$nv_line" ]] || continue
          local g_pct="" v_pct="" v_used="" v_tot="" pw="" plw="" ppct="" gtmp="" v_lbl_tag="" g_note="" g_thr=""
          IFS='|' read -r g_pct v_pct v_used v_tot pw plw ppct gtmp <<< "$nv_line"
          if [[ "$IS_DGX_SPARK" == true && -z "$v_pct" && -n "$ram_pct" ]]; then
            v_pct="$ram_pct"
            v_used="$ram_used_gib"
            v_tot="$ram_tot_gib"
            v_lbl_tag="Unified"
          fi
          if [[ "$HAS_NVIDIA_DATACENTER" == true && -n "${nv_pstates[$nv_ri]:-}" ]]; then
            g_note="${nv_pstates[$nv_ri]}"
          fi
          if [[ "${nv_thr_active[$nv_ri]:-false}" == true ]]; then
            g_thr=" ${C_RED}[THROTTLE]${C_RESET}"
          fi
          [[ -n "$pw" ]] && total_gpu_pwr_w=$(( ${total_gpu_pwr_w:-0} + pw ))
          gpu_pcts+=("$g_pct")
          vram_pcts+=("$v_pct")
          vram_useds+=("$v_used")
          vram_tots+=("$v_tot")
          vram_labels+=("$v_lbl_tag")
          pwr_ws+=("$pw")
          pwr_lim_ws+=("$plw")
          pwr_pcts+=("$ppct")
          gpu_temps+=("$gtmp")
          gpu_notes+=("$g_note")
          gpu_thr_tags+=("$g_thr")
          ((nv_ri++))
        done <<< "$nv_parsed"
      fi
    fi
    if [[ "$HAS_AMD" == true ]]; then
      local drm_dir="${STRATA_DRM_DIR:-/sys/class/drm}" card_node card_dir ven
      for card_node in "$drm_dir"/card[0-9]*; do
        [[ -e "$card_node" ]] || continue
        [[ "$(basename "$card_node")" == *-* ]] && continue
        card_dir="$card_node/device"
        if [[ -r "$card_dir/vendor" ]]; then
          ven="$(tr '[:upper:]' '[:lower:]' < "$card_dir/vendor" 2>/dev/null || true)"
          [[ "$ven" == "0x1002" ]] || continue
        fi
        [[ -r "$card_dir/gpu_busy_percent" ]] || continue
        local g_pct="" v_pct="" v_used="" v_tot="" pw="" plw="" ppct="" gtmp=""
        g_pct="$(cat "$card_dir/gpu_busy_percent" 2>/dev/null || true)"
        if [[ -r "$card_dir/mem_info_vram_used" && -r "$card_dir/mem_info_vram_total" ]]; then
          local vu vt gu gt
          vu="$(cat "$card_dir/mem_info_vram_used" 2>/dev/null || echo 0)"
          vt="$(cat "$card_dir/mem_info_vram_total" 2>/dev/null || echo 0)"
          if _is_drm_card_amd_apu "$card_dir" && [[ -r "$card_dir/mem_info_gtt_used" && -r "$card_dir/mem_info_gtt_total" ]]; then
            gu="$(cat "$card_dir/mem_info_gtt_used" 2>/dev/null || echo 0)"
            gt="$(cat "$card_dir/mem_info_gtt_total" 2>/dev/null || echo 0)"
            if [[ "$vt" =~ ^[0-9]+$ && "$gt" =~ ^[0-9]+$ && "$vu" =~ ^[0-9]+$ && "$gu" =~ ^[0-9]+$ ]]; then
              vu=$((vu + gu))
              vt=$((vt + gt))
            fi
          fi
          if [[ "$vt" =~ ^[0-9]+$ && "$vu" =~ ^[0-9]+$ ]] && (( vt > 0 )); then
            read -r v_pct v_used v_tot <<< "$(awk "BEGIN {printf \"%.0f %.1f %.1f\", ($vu/$vt)*100, $vu/1073741824, $vt/1073741824}")"
          fi
        fi
        local hwmon_dir
        for hwmon_dir in "$card_dir"/hwmon/hwmon*; do
          if [[ -z "$gtmp" && -r "$hwmon_dir/temp1_input" ]]; then
            local mc
            mc="$(cat "$hwmon_dir/temp1_input" 2>/dev/null || echo 0)"
            [[ "$mc" =~ ^[0-9]+$ ]] && (( mc > 0 )) && gtmp=$((mc / 1000))
          fi
          if [[ -z "$pw" && -r "$hwmon_dir/power1_average" ]]; then
            local pa pc
            pa="$(cat "$hwmon_dir/power1_average" 2>/dev/null || echo 0)"
            if [[ "$pa" =~ ^[0-9]+$ ]] && (( pa > 0 )); then
              pw=$((pa / 1000000))
              total_gpu_pwr_w=$(( ${total_gpu_pwr_w:-0} + pw ))
              if [[ -r "$hwmon_dir/power1_cap" ]]; then
                pc="$(cat "$hwmon_dir/power1_cap" 2>/dev/null || echo 0)"
                if [[ "$pc" =~ ^[0-9]+$ ]] && (( pc > 0 )); then
                  plw=$((pc / 1000000))
                  ppct=$((pa * 100 / pc))
                fi
              fi
            fi
          fi
        done
        gpu_pcts+=("$g_pct")
        vram_pcts+=("$v_pct")
        vram_useds+=("$v_used")
        vram_tots+=("$v_tot")
        vram_labels+=("")
        pwr_ws+=("$pw")
        pwr_lim_ws+=("$plw")
        pwr_pcts+=("$ppct")
        gpu_temps+=("$gtmp")
        gpu_notes+=("")
        gpu_thr_tags+=("")
      done
    fi
    if [[ "$HAS_INTEL_ARC" == true ]]; then
      local drm_dir="${STRATA_DRM_DIR:-/sys/class/drm}" card_node card_dir ven did hwmon_dir
      for card_node in "$drm_dir"/card[0-9]*; do
        [[ -e "$card_node" ]] || continue
        [[ "$(basename "$card_node")" == *-* ]] && continue
        card_dir="$card_node/device"
        [[ -r "$card_dir/vendor" && -r "$card_dir/device" ]] || continue
        ven="$(tr '[:upper:]' '[:lower:]' < "$card_dir/vendor" 2>/dev/null || true)"
        [[ "$ven" == "0x8086" ]] || continue
        did="$(tr '[:upper:]' '[:lower:]' < "$card_dir/device" 2>/dev/null || true)"
        _is_intel_discrete_pci_id "$did" || continue
        local pw="" gtmp="" mc="" pa="" e_uj="" e_us="" de="" dt_us=""
        for hwmon_dir in "$card_dir"/hwmon/hwmon*; do
          [[ -d "$hwmon_dir" ]] || continue
          if [[ -z "$gtmp" ]]; then
            local tf
            for tf in "$hwmon_dir/temp2_input" "$hwmon_dir/temp1_input"; do
              if [[ -r "$tf" ]]; then
                mc="$(cat "$tf" 2>/dev/null || echo 0)"
                [[ "$mc" =~ ^[0-9]+$ ]] && (( mc > 0 )) && { gtmp=$((mc / 1000)); break; }
              fi
            done
          fi
          if [[ -z "$pw" && -r "$hwmon_dir/power1_average" ]]; then
            pa="$(cat "$hwmon_dir/power1_average" 2>/dev/null || echo 0)"
            if [[ "$pa" =~ ^[0-9]+$ ]] && (( pa > 0 )); then
              pw=$((pa / 1000000))
              total_gpu_pwr_w=$(( ${total_gpu_pwr_w:-0} + pw ))
            fi
          elif [[ -z "$pw" && -r "$hwmon_dir/energy1_input" ]]; then
            e_uj="$(cat "$hwmon_dir/energy1_input" 2>/dev/null || true)"
            e_us="$(date +%s%6N 2>/dev/null || true)"
            if [[ "$e_uj" =~ ^[0-9]+$ && "$e_us" =~ ^[0-9]+$ ]]; then
              if [[ -n "${PREV_INTEL_GPU_UJ_MAP[$card_dir]:-}" && -n "${PREV_INTEL_GPU_US_MAP[$card_dir]:-}" ]]; then
                de=$(( e_uj - PREV_INTEL_GPU_UJ_MAP[$card_dir] ))
                dt_us=$(( e_us - PREV_INTEL_GPU_US_MAP[$card_dir] ))
                if (( de >= 0 && dt_us > 0 )); then
                  pw=$(( de / dt_us ))
                  total_gpu_pwr_w=$(( ${total_gpu_pwr_w:-0} + pw ))
                fi
              fi
              PREV_INTEL_GPU_UJ_MAP[$card_dir]="$e_uj"
              PREV_INTEL_GPU_US_MAP[$card_dir]="$e_us"
            fi
          fi
        done
        if [[ -n "$gtmp" || -n "$pw" ]]; then
          gpu_pcts+=("")
          vram_pcts+=("")
          vram_useds+=("")
          vram_tots+=("")
          vram_labels+=("")
          pwr_ws+=("$pw")
          pwr_lim_ws+=("")
          pwr_pcts+=("")
          gpu_temps+=("$gtmp")
          gpu_notes+=("")
          gpu_thr_tags+=("")
        fi
      done
    fi

    if [[ "$IS_JETSON" == true && ${#gpu_pcts[@]} -eq 0 ]]; then
      local j_load_f="" j_load="" j_gp="" j_gt="" tz_d tz_t j_mc
      for j_load_f in /sys/devices/platform/17000000.ga10b/load /sys/devices/platform/*.ga10b/load /sys/devices/platform/*.gv11b/load /sys/devices/platform/gpu.0/load /sys/devices/gpu.0/load /sys/devices/*.gp10b/load /sys/devices/platform/host1x/*.gp10b/load; do
        if [[ -r "$j_load_f" ]]; then
          j_load="$(cat "$j_load_f" 2>/dev/null || true)"
          [[ "$j_load" =~ ^[0-9]+$ ]] && { j_gp=$(( j_load / 10 )); break; }
        fi
      done
      for tz_d in /sys/class/thermal/thermal_zone*; do
        [[ -r "$tz_d/type" && -r "$tz_d/temp" ]] || continue
        tz_t="$(cat "$tz_d/type" 2>/dev/null || true)"
        if [[ "$tz_t" == "GPU-therm" || "$tz_t" == "gpu-thermal" || "$tz_t" == "tj-thermal" ]]; then
          j_mc="$(cat "$tz_d/temp" 2>/dev/null || echo 0)"
          [[ "$j_mc" =~ ^[0-9]+$ ]] && (( j_mc > 0 )) && { j_gt=$(( j_mc / 1000 )); break; }
        fi
      done
      if [[ -n "$j_gp" || -n "$j_gt" ]]; then
        gpu_pcts+=("${j_gp:-0}")
        vram_pcts+=("")
        vram_useds+=("")
        vram_tots+=("")
        vram_labels+=("")
        pwr_ws+=("")
        pwr_lim_ws+=("")
        pwr_pcts+=("")
        gpu_temps+=("$j_gt")
        gpu_notes+=("")
        gpu_thr_tags+=("")
      fi
    fi

    # Total system power & CPU temperature (hwmon)
    local hm_dir hm_name
    for hm_dir in /sys/class/hwmon/hwmon*; do
      [[ -r "$hm_dir/name" ]] || continue
      hm_name="$(cat "$hm_dir/name" 2>/dev/null || true)"
      case "$hm_name" in
        coretemp|k10temp|zenpower*)
          if [[ -z "$cpu_temp" && -r "$hm_dir/temp1_input" ]]; then
            local mc
            mc="$(cat "$hm_dir/temp1_input" 2>/dev/null || echo 0)"
            [[ "$mc" =~ ^[0-9]+$ ]] && (( mc > 0 )) && cpu_temp=$((mc / 1000))
          fi
          ;;
        applesmc)
          if [[ -z "$cpu_temp" ]]; then
            local _tf _tl _mc=""
            for _tf in "$hm_dir"/temp*_input; do
              [[ -r "$_tf" ]] || continue
              _tl="$(cat "${_tf%_input}_label" 2>/dev/null || true)"
              if [[ "$_tl" =~ ^(TC0[PDEFHc]|TC[01X][Cc]|TCSA)$ ]]; then
                _mc="$(cat "$_tf" 2>/dev/null || echo 0)"
                [[ "$_mc" =~ ^[0-9]+$ ]] && (( _mc > 0 )) && { cpu_temp=$((_mc / 1000)); break; }
              fi
            done
          fi
          ;;
        corsair-psu|acpi_power_meter|power_meter)
          if [[ -z "$sys_pwr_w" ]]; then
            local pf="" uw=0
            for pf in "$hm_dir"/power1_input "$hm_dir"/power1_average; do
              if [[ -r "$pf" ]]; then
                uw="$(cat "$pf" 2>/dev/null || echo 0)"
                [[ "$uw" =~ ^[0-9]+$ ]] && (( uw > 0 )) && { sys_pwr_w=$((uw / 1000000)); break; }
              fi
            done
          fi
          ;;
      esac
    done
    if [[ -z "$cpu_temp" ]]; then
      local tz_dir tz_type
      for tz_dir in /sys/class/thermal/thermal_zone*; do
        [[ -r "$tz_dir/type" && -r "$tz_dir/temp" ]] || continue
        tz_type="$(cat "$tz_dir/type" 2>/dev/null || true)"
        if [[ "$tz_type" == "x86_pkg_temp" || "$tz_type" == "cpu"* || "$tz_type" == "CPU-therm" || "$tz_type" == "BCPU-therm" || "$tz_type" == "MCPU-therm" ]]; then
          local mc
          mc="$(cat "$tz_dir/temp" 2>/dev/null || echo 0)"
          [[ "$mc" =~ ^[0-9]+$ ]] && (( mc > 0 )) && { cpu_temp=$((mc / 1000)); break; }
        fi
      done
    fi
    if [[ -z "$sys_pwr_w" ]]; then
      sys_pwr_w="$(_read_sysfs_bat_watts "%.0f" || true)"
    fi

    if [[ "$IS_JETSON" == true ]]; then
      local j_sw="" j_gw="" j_cw=""
      IFS='|' read -r j_sw j_gw j_cw <<< "$(read_jetson_ina3221_watts)"
      [[ -n "$j_sw" && -z "$sys_pwr_w" ]] && sys_pwr_w="$(awk -v w="$j_sw" 'BEGIN{printf "%.0f", w}')"
      [[ -n "$j_cw" && -z "$cpu_pwr_w" ]] && cpu_pwr_w="$(awk -v w="$j_cw" 'BEGIN{printf "%.0f", w}')"
      if [[ -n "$j_gw" && "${#gpu_pcts[@]}" -gt 0 && -z "${pwr_ws[0]:-}" ]]; then
        pwr_ws[0]="$(awk -v w="$j_gw" 'BEGIN{printf "%.0f", w}')"
      fi
    fi
    if [[ "$rapl_can_read" == true ]]; then
      local rapl_now us_now
      if [[ -r "$rapl_file" ]]; then
        rapl_now="$(cat "$rapl_file" 2>/dev/null || true)"
      else
        rapl_now="$(sudo -n cat "$rapl_file" 2>/dev/null || true)"
      fi
      us_now="$(date +%s%6N 2>/dev/null || true)"
      if [[ "$rapl_now" =~ ^[0-9]+$ && "$us_now" =~ ^[0-9]+$ ]]; then
        if [[ -n "$PREV_RAPL_UJ" && -n "$PREV_RAPL_US" ]]; then
          local de=$((rapl_now - PREV_RAPL_UJ)) dt_us=$((us_now - PREV_RAPL_US))
          (( de >= 0 && dt_us > 0 )) && cpu_pwr_w=$(( de / dt_us ))
        fi
        PREV_RAPL_UJ="$rapl_now"
        PREV_RAPL_US="$us_now"
      fi
    fi
  fi

  LIVE_STAT_LINES=()
  LIVE_STAT_LINES+=("$(printf "%bLive System Usage:%b" "${C_BOLD}" "${C_RESET}")")
  if [[ -n "$cpu_pct" ]]; then
    local cpu_t_str=""
    [[ -n "$cpu_temp" ]] && cpu_t_str=" ($(format_temp "$cpu_temp"))"
    LIVE_STAT_LINES+=("$(printf "  %-8s [%s] %3d%%%s" "CPU:" "$(render_bar "$cpu_pct")" "$cpu_pct" "$cpu_t_str")")
  fi
  if [[ -n "$ram_pct" ]]; then
    LIVE_STAT_LINES+=("$(printf "  %-8s [%s] %3d%% (%s / %s GiB)" "RAM:" "$(render_bar "$ram_pct")" "$ram_pct" "$ram_used_gib" "$ram_tot_gib")")
  fi
  local gpu_count="${#gpu_pcts[@]}" gi=0
  local pwr_parts=()
  for ((gi=0; gi<gpu_count; gi++)); do
    local g_lbl="GPU:" v_lbl="VRAM:" p_lbl="GPU"
    if (( gpu_count > 1 )); then
      g_lbl="GPU${gi}:" v_lbl="VRAM${gi}:" p_lbl="GPU${gi}"
    fi
    if [[ "${vram_labels[$gi]:-}" == "Unified" ]]; then
      v_lbl="Unified:"
      (( gpu_count > 1 )) && v_lbl="Unif${gi}:"
    fi
    if [[ -n "${gpu_pcts[$gi]}" ]]; then
      local gpu_t_str=""
      if [[ -n "${gpu_temps[$gi]}" ]]; then
        gpu_t_str=" ($(format_temp "${gpu_temps[$gi]}")${gpu_notes[$gi]:+, ${gpu_notes[$gi]}})"
      elif [[ -n "${gpu_notes[$gi]:-}" ]]; then
        gpu_t_str=" (${gpu_notes[$gi]})"
      fi
      [[ -n "${gpu_thr_tags[$gi]:-}" ]] && gpu_t_str+="${gpu_thr_tags[$gi]}"
      LIVE_STAT_LINES+=("$(printf "  %-8s [%s] %3d%%%s" "$g_lbl" "$(render_bar "${gpu_pcts[$gi]}")" "${gpu_pcts[$gi]}" "$gpu_t_str")")
    elif [[ -n "${gpu_temps[$gi]}" ]]; then
      LIVE_STAT_LINES+=("$(printf "  %-8s %s" "$g_lbl" "$(format_temp "${gpu_temps[$gi]}")${gpu_thr_tags[$gi]:-}")")
    fi
    if [[ -n "${vram_pcts[$gi]}" ]]; then
      LIVE_STAT_LINES+=("$(printf "  %-8s [%s] %3d%% (%s / %s GiB)" "$v_lbl" "$(render_bar "${vram_pcts[$gi]}")" "${vram_pcts[$gi]}" "${vram_useds[$gi]}" "${vram_tots[$gi]}")")
    fi
    if [[ -n "${pwr_ws[$gi]}" ]]; then
      if [[ -n "${pwr_pcts[$gi]}" && -n "${pwr_lim_ws[$gi]}" ]]; then
        pwr_parts+=("${p_lbl} ${pwr_ws[$gi]}/${pwr_lim_ws[$gi]}W (${pwr_pcts[$gi]}%)")
      else
        pwr_parts+=("${p_lbl} ${pwr_ws[$gi]}W")
      fi
    fi
  done
  if [[ -n "$cpu_pwr_w" ]]; then
    pwr_parts+=("CPU ${cpu_pwr_w}W")
  elif [[ "$IS_MACOS" == true && "$IS_APPLE_SILICON" == true && "$pm_attempted" == false ]]; then
    pwr_parts+=("$(printf "%bGPU/CPU/Sys n/a (sudo needed for powermetrics)%b" "${C_DIM}" "${C_RESET}")")
  elif [[ "$IS_MACOS" == false && -e "$rapl_file" && "$rapl_can_read" == false ]]; then
    pwr_parts+=("$(printf "%bCPU/Sys n/a (sudo needed for RAPL)%b" "${C_DIM}" "${C_RESET}")")
  fi
  if [[ -n "$sys_pwr_w" ]]; then
    pwr_parts+=("Sys ${sys_pwr_w}W")
  elif [[ -n "$cpu_pwr_w" && -n "$total_gpu_pwr_w" ]]; then
    pwr_parts+=("Sys ~$((cpu_pwr_w + total_gpu_pwr_w))W")
  fi
  if (( ${#pwr_parts[@]} > 0 )); then
    local pwr_line="" pi=0
    for ((pi=0; pi<${#pwr_parts[@]}; pi++)); do
      (( pi > 0 )) && pwr_line+=" | "
      pwr_line+="${pwr_parts[$pi]}"
    done
    LIVE_STAT_LINES+=("$(printf "  %-8s %s" "Power:" "$pwr_line")")
  fi

  local _cparts=()
  [[ -n "$cpu_pct" ]] && _cparts+=("CPU ${cpu_pct}%${cpu_temp:+ (${cpu_temp}°C)}")
  [[ -n "$ram_pct" ]] && _cparts+=("RAM ${ram_pct}%")
  for ((gi=0; gi<gpu_count; gi++)); do
    local _gl="GPU"; (( gpu_count > 1 )) && _gl="GPU${gi}"
    if [[ -n "${gpu_pcts[$gi]}" ]]; then
      _cparts+=("${_gl} ${gpu_pcts[$gi]}%${gpu_temps[$gi]:+ (${gpu_temps[$gi]}°C)}")
    elif [[ -n "${gpu_temps[$gi]}" ]]; then
      _cparts+=("${_gl} ${gpu_temps[$gi]}°C")
    fi
  done
  local _cpwr=()
  [[ -n "$total_gpu_pwr_w" ]] && _cpwr+=("GPU ${total_gpu_pwr_w}W")
  [[ -n "$cpu_pwr_w" ]] && _cpwr+=("CPU ${cpu_pwr_w}W")
  [[ -n "$sys_pwr_w" ]] && _cpwr+=("Sys ${sys_pwr_w}W")
  if (( ${#_cpwr[@]} > 0 )); then
    local _ps="" _pi=0
    for ((_pi=0; _pi<${#_cpwr[@]}; _pi++)); do
      (( _pi > 0 )) && _ps+="/"
      _ps+="${_cpwr[$_pi]}"
    done
    _cparts+=("Pwr ${_ps}")
  fi
  LIVE_COMPACT_SYS=""
  local _ci=0
  for ((_ci=0; _ci<${#_cparts[@]}; _ci++)); do
    (( _ci > 0 )) && LIVE_COMPACT_SYS+=" | "
    LIVE_COMPACT_SYS+="${_cparts[$_ci]}"
  done
}

build_sys_info_lines() {
  SYS_INFO_LINES=()
  SYS_INFO_LINES+=("$(printf "%bSystem Information:%b" "${C_BOLD}" "${C_RESET}")")
  SYS_INFO_LINES+=("$(printf "OS:     %b%s (%s) | Kernel: %s | Laptop: %s%b" "${C_DIM}" "${OS_PRETTY:-$DISTRO_ID}" "$DISTRO_FAMILY" "$KERNEL_VER" "$IS_LAPTOP" "${C_RESET}")")
  if [[ "$IS_JETSON" == true ]]; then
    SYS_INFO_LINES+=("$(printf "Jetson: %b%s (L4T %s%s)%b" "${C_DIM}" "${JETSON_MODEL:-Jetson}" "${JETSON_L4T_REL:-unknown}" "${JETSON_SOC:+, ${JETSON_SOC}}" "${C_RESET}")")
  fi
  SYS_INFO_LINES+=("$(printf "CPU:    %b%s%b" "${C_DIM}" "$CPU_SUMMARY" "${C_RESET}")")
  SYS_INFO_LINES+=("$(printf "RAM:    %b%s GiB%s%b" "${C_DIM}" "$RAM_GB" "$RAM_DETAILS" "${C_RESET}")")
  SYS_INFO_LINES+=("$(printf "GPU(s): %b%s%b" "${C_DIM}" "$GPU_SUMMARY" "${C_RESET}")")
  if [[ "$IS_MACOS" == true && "$IS_APPLE_SILICON" == true ]]; then
    local _mwl _mwl_txt
    _mwl="$(_macos_wired_limit_cur_mb)"
    if (( _mwl > 0 )); then
      _mwl_txt="$(awk -v m="$_mwl" 'BEGIN{printf "%.1f GiB wired limit (%d MiB)", m/1024.0, m}')"
    else
      _mwl_txt="$(awk -v r="$RAM_GB" 'BEGIN{printf "Metal default ~75%% (~%.1f GiB wired cap)", r*0.75}')"
    fi
    SYS_INFO_LINES+=("$(printf "VRAM:   %b%s GiB unified (%s)%b" "${C_DIM}" "$RAM_GB" "$_mwl_txt" "${C_RESET}")")
  elif [[ "$IS_DGX_SPARK" == true || ( "$HAS_NVIDIA_UNIFIED_MEM" == true && "$TOTAL_VRAM_MB" -eq 0 ) ]]; then
    SYS_INFO_LINES+=("$(printf "VRAM:   %b%s GiB unified (GB10)%b" "${C_DIM}" "$RAM_GB" "${C_RESET}")")
  elif (( TOTAL_VRAM_MB > 0 )) || [[ "$HAS_AMD_APU" == true && "$AMD_GTT_TOTAL_MB" -gt 0 ]]; then
    local total_vram_gb="" gtt_gb=""
    if (( TOTAL_VRAM_MB > 0 )); then
      total_vram_gb="$(awk "BEGIN {g=$TOTAL_VRAM_MB/1024; if (g == int(g)) printf \"%d\", g; else printf \"%.1f\", g}")"
    fi
    if [[ "$HAS_AMD_APU" == true && "$AMD_GTT_TOTAL_MB" -gt 0 ]]; then
      gtt_gb="$(awk "BEGIN {g=$AMD_GTT_TOTAL_MB/1024; if (g == int(g)) printf \"%d\", g; else printf \"%.1f\", g}")"
      if [[ -n "$total_vram_gb" ]]; then
        SYS_INFO_LINES+=("$(printf "VRAM:   %b%s GiB dedicated + %s GiB GTT unified%b" "${C_DIM}" "$total_vram_gb" "$gtt_gb" "${C_RESET}")")
      else
        SYS_INFO_LINES+=("$(printf "VRAM:   %b%s GiB GTT unified%b" "${C_DIM}" "$gtt_gb" "${C_RESET}")")
      fi
    elif [[ -n "$total_vram_gb" ]]; then
      SYS_INFO_LINES+=("$(printf "VRAM:   %b%s GiB%b" "${C_DIM}" "$total_vram_gb" "${C_RESET}")")
    fi
  fi
  if [[ "$HAS_AMD" == true && -n "$AMD_GFX_SUMMARY" ]] && { [[ "$HAS_AMD_PREBUILT_GFX" == true ]] || (( ${#AMD_MISSING_GFX_ARCHS[@]} > 0 )) || [[ "$HAS_NVIDIA" == false && "$HAS_INTEL_ARC" == false ]]; }; then
    local hip_st="display / non-target iGPU" hip_col="${C_DIM}"
    if (( ${#AMD_MISSING_GFX_ARCHS[@]} > 0 )); then
      if status_strata_build_hip; then
        hip_st="local Strata HIP engine built"
        hip_col="${C_GREEN}"
      elif [[ "$HAS_NVIDIA" == true || "$HAS_AMD_PREBUILT_GFX" == true || "$HAS_INTEL_ARC" == true ]]; then
        hip_st="no prebuilt engine; optional build in [STRATA]"
        hip_col="${C_DIM}"
      else
        hip_st="[!] no prebuilt Strata engine — build in [STRATA]"
        hip_col="${C_YELLOW}"
      fi
    elif [[ "$HAS_AMD_PREBUILT_GFX" == true ]]; then
      hip_st="official Strata engine"
    fi
    SYS_INFO_LINES+=("$(printf "AMD HIP: %b%s (%s)%b" "${hip_col}" "$AMD_GFX_SUMMARY" "$hip_st" "${C_RESET}")")
  fi
  if [[ "$HAS_NVIDIA" == true && -n "$NVIDIA_CURRENT_PL" ]]; then
    SYS_INFO_LINES+=("$(printf "NVIDIA Power Limit: %b%sW (Default: %sW, Max: %sW)%b" "${C_DIM}" "$NVIDIA_CURRENT_PL" "$NVIDIA_DEFAULT_PL" "$NVIDIA_MAX_PL" "${C_RESET}")")
  fi
  append_gpu_pcie_lines
  [[ -n "$IS_VIRT" ]] && SYS_INFO_LINES+=("$(printf "Virt:   %b%s (hardware-specific steps hidden)%b" "${C_DIM}" "$IS_VIRT" "${C_RESET}")")
  local rl pdl
  for rl in "${RAM_HEALTH_LINES[@]}" "${GPU_TOPO_LINES[@]}"; do [[ -n "$rl" ]] && SYS_INFO_LINES+=("$rl"); done
  pdl="$(power_daemon_conflict_line)"
  [[ -n "$pdl" ]] && SYS_INFO_LINES+=("$pdl")
  if grep -qiE "PowerEdge|ProLiant|ThinkSystem|Supermicro|PRIMERGY|SYS-[0-9]" <<<"${SYS_VENDOR} ${PRODUCT_NAME}"; then
    SYS_INFO_LINES+=("$(printf "Server: %bset the BIOS/BMC system power profile to 'Performance' (not automated)%b" "${C_DIM}" "${C_RESET}")")
  fi
  local _si
  for (( _si = 1; _si < ${#SYS_INFO_LINES[@]}; _si++ )); do
    SYS_INFO_LINES[$_si]="  ${SYS_INFO_LINES[$_si]}"
  done
}

shopt -s extglob
pad_ansi_col() {
  local str="$1" width="$2"
  local vis="${str//$'\033'\[*([0-9;])m/}"
  local pad=$(( width - ${#vis} ))
  if (( pad > 0 )); then
    printf "%s%*s" "$str" "$pad" ""
  else
    printf "%s" "$str"
  fi
}

truncate_ansi_col() {
  local str="$1" max_w="$2"
  (( max_w <= 0 )) && return 0
  local vis="${str//$'\033'\[*([0-9;])m/}"
  if (( ${#vis} <= max_w )); then
    printf "%s" "$str"
    return 0
  fi
  local limit=$(( max_w > 3 ? max_w - 3 : max_w ))
  awk -v lim="$limit" -v ell="$( (( max_w > 3 )) && echo "..." || echo "" )" '
  {
    n = length($0); vis_n = 0; out = ""; i = 1; had_esc = 0
    while (i <= n) {
      ch = substr($0, i, 1)
      if (ch == "\033" && substr($0, i + 1, 1) == "[") {
        rest = substr($0, i)
        if (match(rest, /^\033\[[0-9;]*m/)) {
          out = out substr(rest, 1, RLENGTH)
          i += RLENGTH
          had_esc = 1
          continue
        }
      }
      if (vis_n >= lim) break
      out = out ch
      vis_n++
      i++
    }
    if (had_esc) out = out "\033[0m"
    printf "%s%s", out, ell
  }' <<< "$str"
}

print_stats_and_info_grid() {
  local inplace="${1:-false}" eol=""
  [[ "$inplace" == true ]] && eol=$'\033[K'

  print_live_stats "$inplace" || true
  local term_cols="${TERM_COLS_CACHED:-117}"
  if [[ -t 1 ]]; then
    term_cols="$(tput cols 2>/dev/null || echo 117)"
    TERM_COLS_CACHED="$term_cols"
  fi
  local max_grid_w=$(( term_cols > 117 ? 117 : term_cols ))

  local out="${eol}" total_lines=1
  _append_grid_section() {
    (( $# == 0 )) && return 0
    if (( total_lines > 1 )); then
      out+=$'\n'"${eol}"
      total_lines=$((total_lines + 1))
    fi
    local _sec_line
    for _sec_line in "$@"; do
      (( total_lines > 0 )) && out+=$'\n'
      out+="$(truncate_ansi_col "$_sec_line" "$max_grid_w")${eol}"
      total_lines=$((total_lines + 1))
    done
  }
  run_host_hook live_stats
  _append_grid_section "${SYS_INFO_LINES[@]}"
  _append_grid_section "${LIVE_STAT_LINES[@]}"
  _append_grid_section "${STRATA_STAT_LINES[@]}"
  unset -f _append_grid_section
  LIVE_STATS_COUNT="$total_lines"
  printf "%s\n" "$out"
}

format_stats_toggle_row() {
  local selected="${1:-false}"
  local ptr=" " tag="[STATS]" title="View Live System & Strata Statistics" sub="(CPU / RAM / GPU / Power / Live tok/s)"
  if [[ "$selected" == true ]]; then
    ptr="${C_CYAN}>${C_RESET}"
    printf "%b %b%s%b  %b%s%b  %b%s%b" "$ptr" "${C_BGREEN}${C_BOLD}" "$tag" "${C_RESET}" "${C_CYAN}${C_BOLD}" "$title" "${C_RESET}" "${C_CYAN}" "$sub" "${C_RESET}"
  else
    printf "%b %b%s%b  %b%s%b  %b%s%b" "$ptr" "${C_YELLOW}${C_BOLD}" "$tag" "${C_RESET}" "${C_BOLD}" "$title" "${C_RESET}" "${C_DIM}" "$sub" "${C_RESET}"
  fi
}

format_host_plugin_row() {
  local pid="$1" selected="${2:-false}"
  if [[ -n "${HOST_PLUGIN_LOADED[$pid]:-}" ]] && declare -F "${pid}_menu_row" >/dev/null 2>&1; then
    "${pid}_menu_row" "$selected"
    return 0
  fi
  local pname="${HOST_PLUGIN_NAMES[$pid]:-$pid}"
  local pdesc="${HOST_PLUGIN_DESCS[$pid]:-LLM host plugin}"
  local tag_upper="${pid^^}"
  local prefix="  "
  [[ "$selected" == true ]] && prefix="▶ "
  if [[ "$selected" == true ]]; then
    printf "%b%s[%s]  %s — %s (not loaded — press Enter to load)%b" "${C_BOLD}${C_CYAN}" "$prefix" "$tag_upper" "$pname" "$pdesc" "$C_RESET"
  else
    printf "%s%b[%s]%b  %b%s — %s (not loaded)%b" "$prefix" "${C_MAGENTA}" "$tag_upper" "${C_RESET}" "${C_DIM}" "$pname" "$pdesc" "${C_RESET}"
  fi
}

print_header() {
  local hdr_mode="${1:-none}" skip_rule="${2:-false}"
  clear 2>/dev/null || true
  local _rule_w=120 _hdr_eq="" _hdr_rule=""
  [[ -t 1 ]] && _rule_w="$(tput cols 2>/dev/null || echo 117)"
  (( _rule_w > 117 )) && _rule_w=117
  print_logo "$_rule_w"
  printf -v _hdr_eq "%*s" "$_rule_w" ""
  _hdr_eq="${_hdr_eq// /=}"
  local _title="Strata Host Performance Optimizer & Setup Wizard"
  local _title_pad=$(( (_rule_w - ${#_title}) / 2 ))
  (( _title_pad < 0 )) && _title_pad=0
  echo -e "${C_BOLD}${C_CYAN}${_hdr_eq}${C_RESET}"
  printf "${C_BOLD}${C_CYAN}%*s%s${C_RESET}\n" "$_title_pad" "" "$_title"
  echo -e "${C_BOLD}${C_CYAN}${_hdr_eq}${C_RESET}"
  declare -F load_strata_update_state >/dev/null 2>&1 && load_strata_update_state
  if [[ "$hdr_mode" == "toggle" ]]; then
    LIVE_STATS_COUNT=0
    LIVE_STAT_LINES=()
    echo ""
    local _tgl_sel=false
    (( INDEX_SELECTED == 0 )) && _tgl_sel=true
    printf "%s\n" "$(format_stats_toggle_row "$_tgl_sel")"
    echo ""
    local _hdr_lines=3
    if [[ "$NO_PLUGINS" != true ]]; then
      local _hi _pid _hsel
      for (( _hi = 0; _hi < ${#AVAILABLE_HOST_PLUGINS[@]}; _hi++ )); do
        _pid="${AVAILABLE_HOST_PLUGINS[$_hi]}"
        _hsel=false
        (( INDEX_SELECTED == _hi + 1 )) && _hsel=true
        printf "%s\n" "$(format_host_plugin_row "$_pid" "$_hsel")"
        echo ""
        (( _hdr_lines += 2 ))
      done
    fi
    POST_HEADER_LINES=$_hdr_lines
    UPDATE_BANNER_OFFSET=$_hdr_lines
  elif [[ "$hdr_mode" == "stats" ]]; then
    declare -F refresh_strata_running >/dev/null 2>&1 && refresh_strata_running
    build_sys_info_lines
    print_stats_and_info_grid false
    POST_HEADER_LINES=2
    UPDATE_BANNER_OFFSET=1
  else
    LIVE_STATS_COUNT=0
    LIVE_STAT_LINES=()
    POST_HEADER_LINES=2
    UPDATE_BANNER_OFFSET=1
  fi
  if [[ "$skip_rule" != true ]]; then
    printf -v _hdr_rule "%*s" "$_rule_w" ""
    echo -e "${C_DIM}${_hdr_rule// /─}${C_RESET}"
  else
    POST_HEADER_LINES=$((POST_HEADER_LINES - 1))
    UPDATE_BANNER_OFFSET=$((UPDATE_BANNER_OFFSET - 1))
  fi
  if [[ "$STRATA_UPDATE_AVAILABLE" == true ]] && declare -F format_strata_update_banner >/dev/null 2>&1; then
    printf "%s\n" "$(format_strata_update_banner "$_rule_w")"
  else
    echo ""
  fi
  ((POST_HEADER_LINES += 1))
  if [[ "$REBOOT_REQUIRED" == true ]]; then
    echo -e "\n${C_YELLOW}[!] Reboot pending: newly added kernel parameters require a reboot to take effect.${C_RESET}"
    ((POST_HEADER_LINES += 2))
  fi
  echo ""
}

_can_live_stats() {
  local lines_up="${1:-0}" term_lines="${2:-40}"
  (( lines_up > 0 && (lines_up + 1 <= term_lines || (lines_up + 1 - term_lines) < ${#LIVE_STAT_LINES[@]}) ))
}

format_compact_live_bar() {
  local max_w="${TERM_COLS_CACHED:-120}"
  local txt=""
  [[ -n "$LIVE_COMPACT_SYS" ]] && txt="$LIVE_COMPACT_SYS"
  if [[ -n "$LIVE_COMPACT_STRATA" ]]; then
    [[ -n "$txt" ]] && txt+=" | "
    txt+="$LIVE_COMPACT_STRATA"
  fi
  [[ -n "$txt" ]] || return 0
  local prefix="  [Live] "
  local avail=$(( max_w - ${#prefix} - 1 ))
  if (( avail > 10 && ${#txt} > avail )); then
    txt="${txt:0:$((avail - 3))}..."
  fi
  printf "%b%s%b%s%b" "${C_CYAN}${C_BOLD}" "  [Live] " "${C_RESET}${C_DIM}" "$txt" "${C_RESET}"
}

_render_live_bar_inplace() {
  local bar_line="$1"
  [[ -n "$bar_line" ]] || return 0
  printf "\033[?2026h\033[?25l\033[s\033[1A\r\033[2K%s\033[u\033[?25h\033[?2026l" "$bar_line"
}

_render_live_stats_inplace() {
  local lines_up="$1" term_lines="$2" stats_block="$3"
  local up="$lines_up" block="$stats_block"
  if (( lines_up + 1 > term_lines )); then
    local skip=$(( lines_up + 1 - term_lines ))
    up=$(( term_lines - 1 ))
    (( up > 0 )) || return 0
    block="$(awk -v s="$((skip + 1))" 'NR >= s' <<< "$stats_block")"
    [[ -n "$block" ]] || return 0
  fi
  block="${block//$'\n'/$'\r\n'}"
  printf "\033[?2026h\033[?25l\033[s\033[%dA\r%s\033[u\033[?25h\033[?2026l" "$up" "$block"
}

_tui_start_live_stats_sampler() {
  local -n _tmp_ref="$1" _pid_ref="$2"
  _tmp_ref="" _pid_ref=""
  (( LIVE_STATS_COUNT > 0 )) || return 0
  _tmp_ref="$(mktemp /tmp/strata-stats.XXXXXX 2>/dev/null || echo "")"
  [[ -n "$_tmp_ref" ]] || return 0
  (
    trap 'exit 0' TERM INT
    while true; do
      sleep 1 &
      wait $! 2>/dev/null || exit 0
      declare -F refresh_strata_running >/dev/null 2>&1 && refresh_strata_running
      if print_stats_and_info_grid true > "${_tmp_ref}.tmp" 2>/dev/null; then
        format_compact_live_bar > "${_tmp_ref}.bar.tmp" 2>/dev/null || true
        mv -f "${_tmp_ref}.bar.tmp" "${_tmp_ref}.bar" 2>/dev/null || true
        printf "%s\n" "$LIVE_STATS_COUNT" > "${_tmp_ref}.meta.tmp" 2>/dev/null || true
        mv -f "${_tmp_ref}.meta.tmp" "${_tmp_ref}.meta" 2>/dev/null || true
        mv -f "${_tmp_ref}.tmp" "$_tmp_ref" 2>/dev/null || true
      fi
    done
  ) &
  _pid_ref=$!
  ACTIVE_SAMPLER_PID="$_pid_ref"
  ACTIVE_SAMPLER_TMP="$_tmp_ref"
}

_tui_stop_live_stats_sampler() {
  local pid="${1:-}" tmp="${2:-}"
  [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  [[ -n "$tmp" ]] && rm -f "$tmp" "${tmp}.tmp" "${tmp}.bar" "${tmp}.bar.tmp" "${tmp}.meta" "${tmp}.meta.tmp" 2>/dev/null || true
  ACTIVE_SAMPLER_PID="" ACTIVE_SAMPLER_TMP=""
}

_tui_restore_tty() {
  local saved_tty="${1:-}"
  if [[ -n "$saved_tty" ]]; then
    stty "$saved_tty" 2>/dev/null || stty echo 2>/dev/null || true
  else
    stty echo 2>/dev/null || true
  fi
}

_tui_read_esc_seq() {
  local -n _esc_out="$1"
  _esc_out=""
  IFS= read -rsn2 -t 0.01 _esc_out || true
  if [[ -n "$_esc_out" ]] && [[ "$_esc_out" == \[* || "$_esc_out" == O* ]] && [[ ! "$_esc_out" =~ [A-Za-z~]$ ]]; then
    local _ec="" _en=0
    while (( _en++ < 8 )) && IFS= read -rsn1 -t 0.01 _ec; do
      [[ "$_ec" =~ [A-Za-z~] ]] && break
    done
  fi
}

_tui_prepare_compact_bar() {
  local lines_up="$1" term_lines="$2"
  if (( LIVE_STATS_COUNT > 0 )) && ! _can_live_stats "$lines_up" "$term_lines"; then
    local _bar0
    _bar0="$(format_compact_live_bar)"
    if [[ -n "$_bar0" ]]; then
      printf "%s\n" "$_bar0"
      local _hi
      for (( _hi = 0; _hi < ${#HIST_HDR_LINES[@]}; _hi++ )); do
        HIST_HDR_LINES[$_hi]=$(( HIST_HDR_LINES[_hi] + 1 ))
      done
    fi
    return 0
  fi
  return 1
}

_tui_poll_live_stats_tick() {
  local lines_up="$1" term_lines="$2" compact_bar="$3" tmp_file="$4" buf="$5"
  local prev_upd="$STRATA_UPDATE_AVAILABLE" new_lines stats_block
  declare -F load_strata_update_state >/dev/null 2>&1 && load_strata_update_state
  if [[ "$prev_upd" == false && "$STRATA_UPDATE_AVAILABLE" == true ]]; then
    local _b_up=$(( lines_up - LIVE_STATS_COUNT - UPDATE_BANNER_OFFSET ))
    if ! _render_update_banner_inplace "$_b_up" "$term_lines" && [[ -z "$buf" ]]; then
      return 1
    fi
  fi
  new_lines="$LIVE_STATS_COUNT"
  [[ -n "$tmp_file" && -s "${tmp_file}.meta" ]] && read -r new_lines < "${tmp_file}.meta" || true
  if [[ "$compact_bar" == true ]]; then
    [[ -n "$tmp_file" && -s "${tmp_file}.bar" ]] && _render_live_bar_inplace "$(<"${tmp_file}.bar")"
  elif [[ "$new_lines" =~ ^[0-9]+$ ]] && (( new_lines != LIVE_STATS_COUNT )); then
    [[ -z "$buf" ]] && return 1
  elif [[ -n "$tmp_file" && -s "$tmp_file" ]]; then
    stats_block="$(<"$tmp_file")"
    _render_live_stats_inplace "$lines_up" "$term_lines" "$stats_block"
  fi
  return 0
}

read_line_with_live_stats() {
  local -n _line_out="$1"
  local prompt_str="${2:-Select action: }"
  local lines_up="${3:-0}"
  local total_rows="${4:-0}"
  if [[ ! -t 0 || ! -t 1 ]]; then
    read -r -p "$prompt_str" _line_out || exit 0
    return 0
  fi

  local term_lines=40 compact_bar=false tmp_file="" sampler_pid="" saved_tty=""
  term_lines="$(tput lines 2>/dev/null || echo 40)"
  _tui_prepare_compact_bar "$lines_up" "$term_lines" && compact_bar=true
  _tui_start_live_stats_sampler tmp_file sampler_pid

  saved_tty="$(stty -g 2>/dev/null || true)"
  stty -echo 2>/dev/null || true
  _cleanup_line_live() {
    _tui_stop_live_stats_sampler "$sampler_pid" "$tmp_file"
    sampler_pid="" tmp_file=""
    _tui_restore_tty "$saved_tty"
  }
  trap '_cleanup_line_live; exit 0' INT TERM

  local buf="" ch="" rc=0 _esc=""
  printf "%s" "$prompt_str"
  while true; do
    rc=0
    IFS= read -rsn1 -t 1 ch || rc=$?
    if (( rc == 0 )); then
      if [[ -z "$ch" ]]; then
        _cleanup_line_live; trap - INT TERM; printf "\n"
        _line_out="$buf"; return 0
      elif [[ "$ch" == $'\177' || "$ch" == $'\b' ]]; then
        if [[ -n "$buf" ]]; then
          buf="${buf%?}"; printf "\b \b"
        fi
      elif [[ "$ch" == $'\e' ]]; then
        _tui_read_esc_seq _esc
        if [[ -z "$_esc" ]]; then
          _cleanup_line_live; trap - INT TERM; printf "\n"
          _line_out="__esc__"; return 0
        fi
        if (( total_rows > 0 )) && [[ "$_esc" == "[A" || "$_esc" == "OA" || "$_esc" == "[B" || "$_esc" == "OB" ]]; then
          local old_idx="$HIST_SELECTED" new_idx="$HIST_SELECTED"
          if [[ "$_esc" == "[A" || "$_esc" == "OA" ]]; then
            new_idx=$(( (old_idx - 1 + total_rows) % total_rows ))
          else
            new_idx=$(( (old_idx + 1) % total_rows ))
          fi
          if (( new_idx != old_idx )); then
            HIST_SELECTED="$new_idx"
            local old_up="${HIST_HDR_LINES[$old_idx]:-0}" new_up="${HIST_HDR_LINES[$new_idx]:-0}"
            if (( old_up > 0 && new_up > 0 && old_up < term_lines && new_up < term_lines )); then
              printf "\033[?2026h\033[?25l\033[s\033[%dA\r\033[2K%s\033[u\033[s\033[%dA\r\033[2K%s\033[u\033[?25h\033[?2026l" \
                "$old_up" "${HIST_HDR_PLAIN[$old_idx]}" "$new_up" "${HIST_HDR_SEL[$new_idx]}"
            else
              _cleanup_line_live; trap - INT TERM; printf "\n"
              _line_out="__refresh__"; return 0
            fi
          fi
        fi
      else
        if (( total_rows > 0 )) && [[ -z "$buf" && ( "$ch" == "e" || "$ch" == "E" || "$ch" == " " ) ]]; then
          _cleanup_line_live; trap - INT TERM; printf "\n"
          _line_out="__toggle__"; return 0
        fi
        local _accept=false
        if [[ -z "$buf" && "$ch" =~ ^[bBqQ]$ ]]; then
          _accept=true
        elif [[ "$ch" =~ ^[0-9]$ ]] && [[ -z "$buf" || "$buf" =~ ^[0-9]+$ ]]; then
          local _cand="${buf}${ch}"
          (( total_rows == 0 || (10#_cand >= 1 && 10#_cand <= total_rows) )) && _accept=true
        fi
        if [[ "$_accept" == true ]]; then
          buf+="$ch"; printf "%s" "$ch"
        fi
      fi
    elif (( rc > 128 )); then
      if ! _tui_poll_live_stats_tick "$lines_up" "$term_lines" "$compact_bar" "$tmp_file" "$buf"; then
        _cleanup_line_live; trap - INT TERM; printf "\n"
        _line_out="__refresh__"; return 0
      fi
    else
      _cleanup_line_live; trap - INT TERM; printf "\n"; exit 0
    fi
  done
}

read_step_action() {
  local -n _act_out="$1"
  local lines_up="${2:-0}"
  if [[ ! -t 0 || ! -t 1 ]]; then
    read -r -p "Select action: " _act_out || exit 0
    return 0
  fi

  local term_lines=40 compact_bar=false tmp_file="" sampler_pid="" saved_tty=""
  term_lines="$(tput lines 2>/dev/null || echo 40)"
  _tui_prepare_compact_bar "$lines_up" "$term_lines" && compact_bar=true
  _tui_start_live_stats_sampler tmp_file sampler_pid

  saved_tty="$(stty -g 2>/dev/null || true)"
  stty -echo 2>/dev/null || true
  _restore_step_tty() {
    _tui_stop_live_stats_sampler "$sampler_pid" "$tmp_file"
    sampler_pid="" tmp_file=""
    _tui_restore_tty "$saved_tty"
  }
  trap '_restore_step_tty; exit 0' INT TERM

  local buf="" ch="" esc_seq="" rc=0
  printf "Select action: "
  while true; do
    rc=0
    IFS= read -rsn1 -t 1 ch || rc=$?
    if (( rc == 0 )); then
      if [[ -z "$ch" ]]; then
        _restore_step_tty; trap - INT TERM; printf "\n"
        _act_out="$buf"; return 0
      elif [[ "$ch" == $'\177' || "$ch" == $'\b' ]]; then
        if [[ -n "$buf" ]]; then
          buf="${buf%?}"; printf "\b \b"
        fi
      elif [[ "$ch" == $'\e' ]]; then
        _tui_read_esc_seq esc_seq
        if [[ -z "$esc_seq" ]]; then
          _restore_step_tty; trap - INT TERM; printf "\n"
          _act_out="__esc__"; return 0
        fi
      elif [[ -z "$buf" && "$ch" =~ ^[aArRuUhHnNbBiIqQ]$ ]]; then
        buf="$ch"; printf "%s" "$ch"
      fi
    elif (( rc > 128 )); then
      if ! _tui_poll_live_stats_tick "$lines_up" "$term_lines" "$compact_bar" "$tmp_file" "$buf"; then
        _restore_step_tty; trap - INT TERM; printf "\n"
        _act_out="__refresh__"; return 0
      fi
    else
      _restore_step_tty; trap - INT TERM; printf "\n"; exit 0
    fi
  done
}

run_step_view() {
  local idx="$1" mode="${2:-wizard}" total="${#ACTIVE_STEPS[@]}" step applied action
  while true; do
    step="${ACTIVE_STEPS[$idx]}"
    print_header
    applied=false
    "status_${step}" && applied=true

    local body=""
    body+="$(echo -e "${C_BOLD}Step $((idx + 1)) of ${total}: $("title_${step}")${C_RESET}")"$'\n'
    if [[ "$applied" == true ]]; then
      body+="$(echo -e "Status: ${C_GREEN}[APPLIED]${C_RESET}")"$'\n'
    else
      body+="$(echo -e "Status: ${C_YELLOW}[NOT APPLIED]${C_RESET}")"$'\n'
    fi
    body+="$(echo -e "${C_DIM}----------------------------------------------------------------------${C_RESET}")"$'\n'
    body+="$("explain_${step}")"$'\n'
    body+="$(echo -e "${C_DIM}----------------------------------------------------------------------${C_RESET}")"$'\n\n'

    if [[ "$applied" == true ]]; then
      body+="$(echo -e "  ${C_RED}[r]${C_RESET} Revert this optimization")"$'\n'
    else
      body+="$(echo -e "  ${C_GREEN}[a]${C_RESET} Apply this optimization")"$'\n'
    fi

    [[ "$STRATA_UPDATE_AVAILABLE" == true ]] && body+="$(echo -e "  ${C_BGREEN}[u]${C_RESET} Install Strata update (${STRATA_UPDATE_SUMMARY})")"$'\n'
    body+="$(echo -e "  ${C_DIM}[n]${C_RESET} Next step (Skip)   ${C_DIM}[b]${C_RESET} Previous step   ${C_DIM}[i/Esc]${C_RESET} Back to Index   ${C_DIM}[q]${C_RESET} Quit")"$'\n\n'

    printf "%s" "$body"
    local body_lines lines_up
    body_lines="$(printf "%s" "$body" | wc -l | tr -d '[:space:]')"
    lines_up=$(( LIVE_STATS_COUNT + POST_HEADER_LINES + body_lines ))
    read_step_action action "$lines_up"
    case "$action" in
      __refresh__) ;;
      __esc__|i|I) return 0 ;;
      u|U)
        if [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
          run_strata_option "update" true
        else
          echo -e "${C_YELLOW}No Strata update available.${C_RESET}"; sleep 1
        fi
        ;;
      a|A)
        if [[ "$applied" == true ]]; then
          echo -e "${C_YELLOW}This optimization is already applied.${C_RESET}"; sleep 1
        else
          echo ""; "apply_${step}"; prompt_reboot_if_needed; pause_prompt
          [[ "$mode" == "single" ]] && return 0
        fi
        ;;
      r|R)
        if [[ "$applied" == true ]]; then
          echo ""; "revert_${step}"; prompt_reboot_if_needed; pause_prompt
          [[ "$mode" == "single" ]] && return 0
        else
          echo -e "${C_YELLOW}Nothing to revert for this step.${C_RESET}"; sleep 1
        fi
        ;;
      n|N|"")
        mode="wizard"
        (( idx + 1 < total )) && ((idx++)) || return 0
        ;;
      b|B)
        mode="wizard"
        (( idx > 0 )) && ((idx--))
        ;;
      q|Q) exit 0 ;;
      *) echo -e "${C_RED}Invalid action '${action}'.${C_RESET}"; sleep 1 ;;
    esac
  done
}

render_any_index_row() {
  local idx="$1" selected="${2:-false}"
  local host_rows=0
  [[ "$NO_PLUGINS" != true ]] && host_rows=${#AVAILABLE_HOST_PLUGINS[@]}
  local top_rows=$(( 1 + host_rows ))
  if (( idx == 0 )); then
    format_stats_toggle_row "$selected"
  elif (( idx >= 1 && idx < top_rows )); then
    format_host_plugin_row "${AVAILABLE_HOST_PLUGINS[$((idx - 1))]}" "$selected"
  else
    format_index_row "$((idx - top_rows))" "$selected"
  fi
}

index_row_up_offset() {
  local idx="$1" n_opt="$2" _unused="$3" footer_menu_lines="$4" toggle_up="${5:-0}"
  local host_rows=0
  [[ "$NO_PLUGINS" != true ]] && host_rows=${#AVAILABLE_HOST_PLUGINS[@]}
  local top_rows=$(( 1 + host_rows ))
  if (( idx == 0 )); then
    echo "$toggle_up"
  elif (( idx >= 1 && idx < top_rows )); then
    echo $(( toggle_up - (2 * idx) ))
  else
    local o_idx=$(( idx - top_rows ))
    local leg_lines=$(( INDEX_LEGEND_LINES > 0 ? INDEX_LEGEND_LINES + 1 : 0 ))
    echo $(( (n_opt - o_idx) + leg_lines + footer_menu_lines ))
  fi
}

read_choice_with_live_stats() {
  local -n _out_var="$1"
  local footer_lines="${2:-0}"
  local toggle_up="${3:-0}"
  local term_lines=40
  if [[ ! -t 1 || ! -t 0 ]]; then
    read -r -p "Select action: " _out_var || exit 0
    return 0
  fi

  term_lines="$(tput lines 2>/dev/null || echo 40)"

  local saved_tty=""
  saved_tty="$(stty -g 2>/dev/null || true)"
  stty -echo 2>/dev/null || true

  _restore_index_tty() { _tui_restore_tty "$saved_tty"; }
  trap '_restore_index_tty; exit 0' INT TERM

  local buf="" ch="" rc=0 init_upd="$STRATA_UPDATE_AVAILABLE"
  printf "Select action: "
  while true; do
    rc=0
    IFS= read -rsn1 -t 1 ch || rc=$?
    if (( rc == 0 )); then
      if [[ -z "$ch" ]]; then
        _restore_index_tty
        trap - INT TERM
        printf "\n"
        _out_var="$buf"
        return 0
      elif [[ "$ch" == $'\177' || "$ch" == $'\b' ]]; then
        if [[ -n "$buf" ]]; then
          buf="${buf%?}"
          printf "\b \b"
        fi
      elif [[ "$ch" == $'\e' ]]; then
        local esc_seq=""
        _tui_read_esc_seq esc_seq
        if [[ -z "$esc_seq" && -n "$buf" ]]; then
          while [[ -n "$buf" ]]; do
            buf="${buf%?}"
            printf "\b \b"
          done
          continue
        fi
        local n_opt="${#ACTIVE_STEPS[@]}"
        local host_rows=0
        [[ "$NO_PLUGINS" != true ]] && host_rows=${#AVAILABLE_HOST_PLUGINS[@]}
        local total_rows=$(( 1 + host_rows + n_opt ))
        if (( footer_lines > 0 && total_rows > 0 )); then
          local old_idx="$INDEX_SELECTED" new_idx="$INDEX_SELECTED"
          if [[ "$esc_seq" == "[A" || "$esc_seq" == "OA" ]]; then
            new_idx=$(( (old_idx - 1 + total_rows) % total_rows ))
          elif [[ "$esc_seq" == "[B" || "$esc_seq" == "OB" ]]; then
            new_idx=$(( (old_idx + 1) % total_rows ))
          fi
          if (( new_idx != old_idx )); then
            INDEX_SELECTED="$new_idx"
            local old_up new_up
            old_up="$(index_row_up_offset "$old_idx" "$n_opt" 0 "$footer_lines" "$toggle_up")"
            new_up="$(index_row_up_offset "$new_idx" "$n_opt" 0 "$footer_lines" "$toggle_up")"
            if (( old_up < term_lines && new_up < term_lines )); then
              local old_row new_row
              old_row="$(render_any_index_row "$old_idx" false)"
              new_row="$(render_any_index_row "$new_idx" true)"
              printf "\033[?2026h\033[?25l\033[s\033[%dA\r\033[2K%s\033[u\033[s\033[%dA\r\033[2K%s\033[u\033[?25h\033[?2026l" \
                "$old_up" "$old_row" "$new_up" "$new_row"
            else
              _restore_index_tty
              trap - INT TERM
              printf "\n"
              _out_var="__refresh__"
              return 0
            fi
          fi
        fi
      else
        local accept=false
        if [[ -z "$buf" ]]; then
          if [[ "$ch" =~ ^[wWcCuUhHaAlLxXrRqQ]$ ]] || [[ "$ch" =~ ^[1-9]$ ]]; then
            accept=true
          fi
        elif [[ "$buf" =~ ^[0-9]{1,2}$ ]] && [[ "$ch" =~ ^[0-9]$ ]]; then
          local cand="${buf}${ch}"
          (( 10#$cand <= ${#ACTIVE_STEPS[@]} )) && accept=true
        fi
        if [[ "$accept" == true ]]; then
          buf+="$ch"
          printf "%s" "$ch"
        fi
      fi
    elif (( rc > 128 )); then
      declare -F load_strata_update_state >/dev/null 2>&1 && load_strata_update_state
      if [[ "$init_upd" == false && "$STRATA_UPDATE_AVAILABLE" == true ]]; then
        local _b_up=$(( toggle_up - UPDATE_BANNER_OFFSET ))
        if _render_update_banner_inplace "$_b_up" "$term_lines"; then
          init_upd=true
        elif [[ -z "$buf" ]]; then
          _restore_index_tty
          trap - INT TERM
          printf "\n"
          _out_var="__refresh__"
          return 0
        fi
      fi
    else
      _restore_index_tty
      trap - INT TERM
      printf "\n"
      exit 0
    fi
  done
}

INDEX_SELECTED=0

render_gain_stars() {
  local pts="${1:-0}"
  if (( pts <= 0 )); then
    printf "         "
    return 0
  fi
  (( pts > 5 )) && pts=5
  local full="$pts" empty=$(( 5 - pts ))
  local filled_str="" empty_str="" i
  for ((i=0; i<full; i++)); do filled_str+="★"; done
  for ((i=0; i<empty; i++)); do empty_str+="☆"; done
  printf "%b%s%b%b%s%b    " "${C_YELLOW}" "$filled_str" "${C_RESET}" "${C_DIM}" "$empty_str" "${C_RESET}"
}

format_index_row() {
  local idx="$1" selected="${2:-false}"
  local step="${ACTIVE_STEPS[$idx]}"
  local num=$(( idx + 1 ))
  local badge note_txt title_txt gain_txt ptr row_num
  "status_${step}" && badge="${C_GREEN}[APPLIED]    ${C_RESET}" || badge="${C_YELLOW}[NOT APPLIED]${C_RESET}"
  if [[ "$IS_LAPTOP" == true ]] && is_laptop_recommended_step "$step"; then
    note_txt="${C_CYAN}[L]${C_RESET}"
  elif declare -F "note_${step}" >/dev/null 2>&1; then
    note_txt="$("note_${step}")"
  else
    note_txt="${C_DIM}-${C_RESET}"
  fi
  gain_txt="$(render_gain_stars "${STEP_GAIN_PTS[$step]:-0}")"
  local raw_title
  raw_title="$("title_${step}")"
  (( ${#raw_title} > 74 )) && raw_title="${raw_title:0:71}..."
  title_txt="$(printf "%-74s" "$raw_title")"
  if [[ "$selected" == true ]]; then
    ptr="${C_CYAN}>${C_RESET}"
    row_num="${C_CYAN}${C_BOLD}$(printf "%2d" "$num")${C_RESET}"
    title_txt="${C_CYAN}${C_BOLD}${title_txt}${C_RESET}"
  else
    ptr=" "
    row_num="$(printf "%2d" "$num")"
  fi
  printf "%b %b  | %b | %b | %b | %b" "$ptr" "$row_num" "$badge" "$title_txt" "$gain_txt" "$note_txt"
}

show_stats_page() {
  while true; do
    print_header stats
    local body=""
    body+="$(echo -e "  ${C_DIM}Live-updating every 1s. Press ${C_BOLD}[i / b / Enter / Esc]${C_RESET}${C_DIM} to return to Index, or ${C_BOLD}[q]${C_RESET}${C_DIM} to Quit.${C_RESET}")"$'\n\n'
    printf "%s" "$body"
    local body_lines lines_up action=""
    body_lines="$(printf "%s" "$body" | wc -l | tr -d '[:space:]')"
    lines_up=$(( LIVE_STATS_COUNT + POST_HEADER_LINES + body_lines ))
    read_step_action action "$lines_up"
    case "$action" in
      __refresh__) ;;
      __esc__|""|b|B|i|I) return 0 ;;
      q|Q) exit 0 ;;
      u|U)
        if [[ "$STRATA_UPDATE_AVAILABLE" == true ]] && declare -F run_strata_option >/dev/null 2>&1; then
          run_strata_option "update" true
        fi
        ;;
      *) ;;
    esac
  done
}

STRATA_PAGE_SELECTED=0

show_index() {
  discover_host_plugins
  while true; do
    declare -F refresh_strata_bin >/dev/null 2>&1 && refresh_strata_bin
    build_active_steps
    local host_rows=0
    [[ "$NO_PLUGINS" != true ]] && host_rows=${#AVAILABLE_HOST_PLUGINS[@]}
    local top_rows=$(( 1 + host_rows ))
    local total_rows=$(( top_rows + ${#ACTIVE_STEPS[@]} ))
    if (( total_rows == 0 )); then
      INDEX_SELECTED=0
    elif (( INDEX_SELECTED >= total_rows )); then
      INDEX_SELECTED=$(( total_rows - 1 ))
    elif (( INDEX_SELECTED < 0 )); then
      INDEX_SELECTED=0
    fi
    print_header toggle

    local body="" hw_warns=""
    hw_warns="$(run_host_hook hw_warnings)"
    if [[ -n "$hw_warns" ]]; then
      body+="${hw_warns}"$'\n'
      body+="$(echo -e "${C_DIM}          You can still apply any host optimizations applicable to this machine below.${C_RESET}")"$'\n\n'
    fi

    body+="$(echo -e "${C_BOLD}Optimization Index (Applicable to this machine):${C_RESET}")"$'\n\n'
    body+="$(printf "  ${C_BOLD}%-3s | %-13s | %-74s | %-9s | %s${C_RESET}" "#" "Status" "Optimization" "Potential" "")"$'\n'
    body+="$(printf "  %s" "----+---------------+----------------------------------------------------------------------------+-----------+-----")"$'\n'
    local idx
    for (( idx = 0; idx < ${#ACTIVE_STEPS[@]}; idx++ )); do
      if (( idx + top_rows == INDEX_SELECTED )); then
        body+="$(format_index_row "$idx" true)"$'\n'
      else
        body+="$(format_index_row "$idx" false)"$'\n'
      fi
    done
    local step has_warn_flag=false has_opt_flag=false has_exp_flag=false
    for step in "${ACTIVE_STEPS[@]}"; do
      is_high_idle_step "$step" && has_warn_flag=true
      is_opt_in_step "$step" && has_opt_flag=true
      is_experimental_step "$step" && has_exp_flag=true
    done

    local -a legend_items=()
    local opt_desc="Opt-in trade-off (power cap / partitioning / RAM reserve)"
    [[ "$IS_MACOS" == true ]] && opt_desc="Opt-in trade-off (wired RAM cap / Metal switches)"
    [[ "$has_warn_flag" == true ]] && legend_items+=("$(echo -e "${C_YELLOW}[!]${C_RESET} ${C_DIM}Higher idle power, minimal gain${C_RESET}")")
    [[ "$has_opt_flag" == true ]] && legend_items+=("$(echo -e "${C_BLUE}[OPT]${C_RESET} ${C_DIM}${opt_desc}${C_RESET}")")
    [[ "$has_exp_flag" == true ]] && legend_items+=("$(echo -e "${C_MAGENTA}[EXP]${C_RESET} ${C_DIM}Experimental / third-party or hardware-dependent${C_RESET}")")
    [[ "$IS_LAPTOP" == true ]] && legend_items+=("$(echo -e "${C_CYAN}[L]${C_RESET} ${C_DIM}Laptop-recommended (low idle battery impact)${C_RESET}")")

    INDEX_LEGEND_LINES=0
    if (( ${#legend_items[@]} > 0 )); then
      local leg_single="  " li_idx leg_vis
      for (( li_idx = 0; li_idx < ${#legend_items[@]}; li_idx++ )); do
        (( li_idx > 0 )) && leg_single+="   "
        leg_single+="${legend_items[$li_idx]}"
      done
      leg_vis="${leg_single//$'\033'\[*([0-9;])m/}"
      if (( ${#leg_vis} <= 108 )) || (( ${#legend_items[@]} <= 1 )); then
        INDEX_LEGEND_LINES=1
        body+=$'\n'"${leg_single}"$'\n'
      else
        local leg_line1="  ${legend_items[0]}   ${legend_items[1]}"
        local leg_line2="  ${legend_items[2]}"
        for (( li_idx = 3; li_idx < ${#legend_items[@]}; li_idx++ )); do
          leg_line2+="   ${legend_items[$li_idx]}"
        done
        INDEX_LEGEND_LINES=2
        body+=$'\n'"${leg_line1}"$'\n'"${leg_line2}"$'\n'
      fi
    fi

    local footer_lines=9 hist_count=0
    declare -F count_bench_history >/dev/null 2>&1 && hist_count="$(count_bench_history)"
    body+=$'\n'"$(echo -e "  ${C_BOLD}[w]${C_RESET} Start guided wizard from Step 1")"$'\n'
    body+="$(echo -e "  ${C_CYAN}[c]${C_RESET} Check / detection summary (read-only)")"$'\n'
    if [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
      body+="$(echo -e "  ${C_BGREEN}[u]${C_RESET} Install Strata update (${STRATA_UPDATE_SUMMARY})")"$'\n'
      ((footer_lines++))
    fi
    if (( hist_count > 0 )); then
      body+="$(echo -e "  ${C_CYAN}[h]${C_RESET} Benchmark history & restore coupled options (${hist_count})")"$'\n'
      ((footer_lines++))
    fi
    local -a excl_parts=()
    [[ "$has_warn_flag" == true ]] && excl_parts+=("high-idle-power options")
    [[ "$has_opt_flag" == true ]] && excl_parts+=("opt-in trade-offs")
    [[ "$has_exp_flag" == true ]] && excl_parts+=("experimental options")
    local rec_excl="none"
    if (( ${#excl_parts[@]} == 1 )); then
      rec_excl="${excl_parts[0]}"
    elif (( ${#excl_parts[@]} == 2 )); then
      rec_excl="${excl_parts[0]} and ${excl_parts[1]}"
    elif (( ${#excl_parts[@]} == 3 )); then
      rec_excl="${excl_parts[0]}, ${excl_parts[1]}, and ${excl_parts[2]}"
    fi
    body+="$(echo -e "  ${C_GREEN}[a]${C_RESET} Apply all recommended optimizations (excludes ${rec_excl})")"$'\n'
    if [[ "$IS_LAPTOP" == true ]]; then
      body+="$(echo -e "  ${C_CYAN}[l]${C_RESET} Apply laptop-recommended optimizations (minimal idle battery impact)")"$'\n'
      ((footer_lines++))
    fi
    body+="$(echo -e "  ${C_RED}[x]${C_RESET} Revert all recommended optimizations")"$'\n'
    body+="$(echo -e "  ${C_BOLD}[1-${#ACTIVE_STEPS[@]} / ↑↓+Enter]${C_RESET} Select an option")"$'\n'
    body+="$(echo -e "  ${C_BOLD}[r]${C_RESET} Reboot system")"$'\n'
    body+="$(echo -e "  ${C_BOLD}[q]${C_RESET} Quit")"$'\n\n'

    printf "%s" "$body"
    local body_lines toggle_up
    body_lines="$(printf "%s" "$body" | wc -l | tr -d '[:space:]')"
    toggle_up=$(( 1 + POST_HEADER_LINES + body_lines ))
    read_choice_with_live_stats choice "$footer_lines" "$toggle_up"

    case "$choice" in
      __refresh__) ;;
      "")
        if (( INDEX_SELECTED == 0 )); then
          show_stats_page
        elif (( INDEX_SELECTED >= 1 && INDEX_SELECTED < top_rows )); then
          local _sel_pid="${AVAILABLE_HOST_PLUGINS[$(( INDEX_SELECTED - 1 ))]}"
          if [[ -z "${HOST_PLUGIN_LOADED[$_sel_pid]:-}" ]]; then
            echo -e "\n${C_CYAN}Loading ${_sel_pid} plugin...${C_RESET}"
            if ! load_plugin hosts "$_sel_pid"; then
              echo -e "${C_RED}Failed to load plugin '${_sel_pid}'.${C_RESET}"
              sleep 2
              continue
            fi
          fi
          if declare -F "${_sel_pid}_open" >/dev/null 2>&1; then
            "${_sel_pid}_open"
          else
            echo -e "${C_RED}Plugin '${_sel_pid}' does not define ${_sel_pid}_open.${C_RESET}"
            sleep 2
          fi
        else
          run_step_view $(( INDEX_SELECTED - top_rows )) "single"
        fi
        ;;
      c|C) show_check_page ;;
      u|U)
        if [[ "$STRATA_UPDATE_AVAILABLE" == true ]] && declare -F run_strata_option >/dev/null 2>&1; then
          run_strata_option "update" true
        else
          echo -e "${C_YELLOW}No Strata update available.${C_RESET}"; sleep 1
        fi
        ;;
      h|H)
        if declare -F show_benchmark_history >/dev/null 2>&1; then
          show_benchmark_history
        else
          echo -e "${C_YELLOW}Load the Strata plugin first to view benchmark history.${C_RESET}"; sleep 1
        fi
        ;;
      w|W) run_step_view 0 "wizard" ;;
      a|A) run_recommended_batch "apply" ;;
      l|L)
        if [[ "$IS_LAPTOP" == true ]]; then
          run_recommended_batch "apply" "laptop"
        else
          echo -e "${C_RED}Invalid choice '${choice}'. Cancelled.${C_RESET}"; sleep 1
        fi
        ;;
      x|X) run_recommended_batch "revert" ;;
      r|R)
        confirm_yn "Reboot this system now? [y/N]: " "N" && { if [[ "$HAS_SYSTEMD" == true ]]; then run_root systemctl reboot; elif [[ "$IS_MACOS" == true ]]; then run_root shutdown -r now; else run_root reboot; fi; exit 0; }
        sleep 1
        ;;
      q|Q) exit 0 ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( ${#choice} <= 3 && 10#$choice >= 1 && 10#$choice <= ${#ACTIVE_STEPS[@]} )); then
          run_step_view $((10#$choice - 1)) "single"
        else
          echo -e "${C_RED}Invalid choice '${choice}'. Cancelled.${C_RESET}"; sleep 1
        fi
        ;;
    esac
  done
}

cleanup_all_on_exit() {
  run_host_hook cleanup
  stop_bench_power_sampler
  [[ -n "$BENCH_POWER_TMP_FILE" ]] && rm -f "$BENCH_POWER_TMP_FILE" 2>/dev/null || true
  if [[ -n "$ACTIVE_SAMPLER_PID" ]]; then
    kill "$ACTIVE_SAMPLER_PID" 2>/dev/null || true
    wait "$ACTIVE_SAMPLER_PID" 2>/dev/null || true
    ACTIVE_SAMPLER_PID=""
  fi
  if [[ -n "$ACTIVE_SAMPLER_TMP" ]]; then
    rm -f "$ACTIVE_SAMPLER_TMP" "${ACTIVE_SAMPLER_TMP}.tmp" "${ACTIVE_SAMPLER_TMP}.bar" "${ACTIVE_SAMPLER_TMP}.bar.tmp" "${ACTIVE_SAMPLER_TMP}.meta" "${ACTIVE_SAMPLER_TMP}.meta.tmp" 2>/dev/null || true
    ACTIVE_SAMPLER_TMP=""
  fi
  if [[ -t 1 ]]; then
    stty echo 2>/dev/null || true
    printf "\033[?25h\033[?2026l" 2>/dev/null || true
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Interactive TUI wizard to inspect, apply, and revert host-level performance
optimizations for LLM inference, with lazy-loaded host & hardware plugins.

Options:
  --check                 Run hardware, OS, and step-applicability detection in
                          read-only mode, print a summary, and exit without
                          modifying the system or prompting for sudo.
  --plugin, --with LIST   Pre-load one or more comma-separated LLM host plugins
                          on startup (e.g. --plugin strata).
  --no-plugins            Run in pure host-tuning mode without loading plugins.
  --list-plugins          List available host and tweak plugins and exit.
  --download-plugins      Pre-download all plugins from the registry into cache
                          for offline use and exit.
  --strata-api-key KEY    API key used for all requests to Strata (live /metrics
                          polling, 'strata bench run' benchmarking, and Strata
                          CLI calls); overrides STRATA_API_KEY if set.
  -h, --help              Show this help message and exit.

Environment:
  STRATA_API_KEY          Fallback API key used for Strata requests.
  STRATA_PLUGIN_BASE_URL  Override base URL for remote plugin downloads.
EOF
}

is_step_managed_by_wizard() {
  case "$1" in
    cpu_performance)     service_installed strata-cpu-perf.service ;;
    memlock_realtime)    [[ -n "$STRATA_DOCKER_CONTAINER" || -f /etc/security/limits.d/99-strata-memlock.conf || -f /etc/security/limits.d/99-realtime-privileges.conf ]] ;;
    numa_balancing)      [[ -f /etc/sysctl.d/99-strata-numa.conf ]] ;;
    amd_gpu_perf)        service_installed strata-amd-gpu-perf.service ;;
    intel_gpu_perf)      service_installed strata-intel-gpu-perf.service ;;
    nvidia_persistenced) unit_exists nvidia-persistenced.service || service_installed strata-nvidia-persistenced.service ;;
    cstate_limit)        service_installed strata-cstate-limit.service ;;
    pcie_aspm)           service_installed strata-pcie-aspm.service || has_kernel_param "pcie_aspm.policy=performance" ;;
    macos_wired_limit)   service_installed strata-macos-wired-limit.service ;;
    *)                   return 0 ;;
  esac
}

print_check_summary() {
  build_active_steps

  local init_desc="systemd"
  if [[ "$HAS_LAUNCHD" == true ]]; then
    init_desc="launchd"
  elif [[ "$HAS_SYSTEMD" != true ]]; then
    init_desc="non-systemd"
  fi
  local platform_tags=()
  if [[ "$IS_MACOS" == true ]]; then
    if [[ "$IS_APPLE_SILICON" == true ]]; then
      platform_tags+=("macOS Apple Silicon")
    else
      platform_tags+=("macOS Intel")
    fi
  fi
  if [[ "$IS_ASAHI_LINUX" == true ]]; then
    platform_tags+=("Apple Silicon / Asahi Linux")
  elif [[ "$IS_APPLE_LINUX" == true ]]; then
    platform_tags+=("Apple Mac Linux")
  fi
  [[ "$IS_UNRAID" == true ]] && platform_tags+=("Unraid")
  [[ "$IS_TRUENAS" == true ]] && platform_tags+=("TrueNAS")
  [[ "$IS_SYNOLOGY" == true ]] && platform_tags+=("Synology")
  [[ "$IS_JETSON" == true ]] && platform_tags+=("Jetson")
  [[ "$IS_LAPTOP" == true ]] && platform_tags+=("laptop")
  [[ -n "$IS_VIRT" ]] && platform_tags+=("VM:${IS_VIRT}")
  local tag_str="" _tag_joined=""
  if (( ${#platform_tags[@]} > 0 )); then
    printf -v _tag_joined ', %s' "${platform_tags[@]}"
    tag_str=" (${_tag_joined:2})"
  fi

  echo -e "${C_BOLD}System:${C_RESET}"
  echo "  OS:       ${OS_PRETTY:-Unknown} (family: ${DISTRO_FAMILY}, kernel: ${KERNEL_VER:-unknown})"
  echo "  Init:     ${init_desc}${tag_str}"
  echo "  CPU:      ${CPU_SUMMARY:-Unknown} (sockets: ${CPU_SOCKETS}, NUMA nodes: ${NUMA_NODES})"
  echo "  RAM:      ${RAM_GB} GiB${RAM_DETAILS}"
  echo "  GPU(s):   ${GPU_SUMMARY:-Unknown}"
  if [[ "$IS_MACOS" == true && "$IS_APPLE_SILICON" == true ]]; then
    echo "    Platform: Apple Silicon (${MACOS_CHIP:-Apple}, ${MACOS_MODEL_ID:-Mac}, macOS ${MACOS_VER:-unknown})"
  fi
  if [[ "$HAS_NVIDIA" == true && ${#NVIDIA_GPU_INDICES[@]} -gt 0 ]]; then
    local i mi mig_info cc_info vram_info
    for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
      local pl_info="PL n/a"
      if [[ "${NVIDIA_GPU_PL_SUPPORTED[$i]}" == true || -n "${NVIDIA_GPU_CUR_PL[$i]}" ]]; then
        pl_info="PL ${NVIDIA_GPU_CUR_PL[$i]:-?}W (default ${NVIDIA_GPU_DEF_PL[$i]:-?}W, max ${NVIDIA_GPU_MAX_PL[$i]:-?}W)"
      fi
      vram_info="unified memory (GB10)"
      if [[ "${NVIDIA_GPU_VRAM[$i]}" =~ ^[0-9]+$ ]] && (( NVIDIA_GPU_VRAM[$i] > 0 )); then
        vram_info="${NVIDIA_GPU_VRAM[$i]} MiB"
      elif [[ "$IS_DGX_SPARK" == false ]]; then
        vram_info="${NVIDIA_GPU_VRAM[$i]:-n/a}"
      fi
      cc_info=""
      [[ -n "${NVIDIA_GPU_COMPUTE_CAP[$i]:-}" ]] && cc_info=", cc=${NVIDIA_GPU_COMPUTE_CAP[$i]}"
      mig_info=""
      for (( mi = 0; mi < ${#NVIDIA_MIG_INDICES[@]}; mi++ )); do
        if [[ "${NVIDIA_MIG_INDICES[$mi]}" == "${NVIDIA_GPU_INDICES[$i]}" && "${NVIDIA_GPU_MIG_CUR[$mi]}" == "Enabled" ]]; then
          mig_info=", MIG=Enabled"
        fi
      done
      echo "    NVIDIA[${NVIDIA_GPU_INDICES[$i]}]: ${NVIDIA_GPU_NAMES[$i]} (${vram_info}, ${pl_info}, compute=${NVIDIA_GPU_COMPUTE_MODE[$i]}${cc_info}${mig_info})"
    done
  fi
  if [[ "$IS_DGX_SPARK" == true ]]; then
    echo "    Platform: NVIDIA DGX Spark (GB10 unified memory)"
  fi
  if [[ "$HAS_AMD" == true && ${#AMD_GFX_ARCHS[@]} -gt 0 ]]; then
    local _ag _ast _agtt=""
    if [[ "$HAS_AMD_APU" == true && "$AMD_GTT_TOTAL_MB" -gt 0 ]]; then
      _agtt="$(awk "BEGIN {g=$AMD_GTT_TOTAL_MB/1024; if (g == int(g)) printf \", %d GiB GTT unified\", g; else printf \", %.1f GiB GTT unified\", g}")"
    fi
    for _ag in "${AMD_GFX_ARCHS[@]}"; do
      if amd_gfx_has_prebuilt "$_ag"; then
        _ast="official prebuilt Strata engine"
      elif amd_gfx_is_missing_target "$_ag"; then
        if declare -F _amd_gfx_covered_by_local_hip >/dev/null 2>&1 && _amd_gfx_covered_by_local_hip "$_ag"; then
          _ast="local Strata HIP engine installed"
        else
          _ast="no prebuilt Strata Linux engine — build locally via [STRATA]"
        fi
      else
        _ast="display / non-target iGPU"
      fi
      echo "    AMD[${_ag}]: $(amd_gfx_label "$_ag") (${_ast}${_agtt})"
      _agtt=""
    done
  fi
  local _hl
  for _hl in "${RAM_HEALTH_LINES[@]}" "${GPU_TOPO_LINES[@]}"; do
    [[ -n "$_hl" ]] && printf "  %s\n" "$_hl"
  done
  if (( ${#LOADED_HOST_PLUGINS[@]} > 0 )); then
    run_host_hook check_summary
  elif [[ "$NO_PLUGINS" == true ]]; then
    echo "  Plugins:  disabled (--no-plugins)"
  else
    echo "  Plugins:  none pre-loaded (lazy-loaded on demand, or pass --plugin strata)"
  fi
  local _hw_warns _hw_line
  _hw_warns="$(run_host_hook hw_warnings)"
  if [[ -n "$_hw_warns" ]]; then
    while IFS= read -r _hw_line; do
      [[ -n "$_hw_line" ]] && echo "  ${_hw_line}"
    done <<< "$_hw_warns"
  fi
  echo ""
  echo -e "${C_BOLD}Applicable Steps (${#ACTIVE_STEPS[@]}):${C_RESET}"

  local applied_count=0 rec_pending=0 opt_pending=0
  local idx=1 step pts title status_lbl note_lbl
  for step in "${ACTIVE_STEPS[@]}"; do
    pts="${STEP_GAIN_PTS[$step]:-1}"
    title="$("title_${step}")"
    note_lbl=""
    if is_experimental_step "$step"; then
      note_lbl=" [EXP]"
    elif is_opt_in_step "$step"; then
      note_lbl=" [OPT]"
    elif is_high_idle_step "$step"; then
      note_lbl=" [!]"
    elif [[ "$IS_LAPTOP" == true ]] && is_laptop_recommended_step "$step"; then
      note_lbl=" [L]"
    fi
    [[ "$step" == "nvidia_power_limit" ]] && note_lbl+=" (no measured speedup at default PL)"
    [[ "$step" == "numa_balancing" ]] && note_lbl+=" (no measured throughput gain on containerised host)"

    if "status_${step}"; then
      status_lbl="${C_GREEN}[APPLIED]${C_RESET}    "
      ((applied_count++))
      is_step_managed_by_wizard "$step" || note_lbl+=" (already active on host)"
    elif is_recommended_step "$step"; then
      status_lbl="${C_YELLOW}[WOULD APPLY]${C_RESET}"
      ((rec_pending++))
    else
      status_lbl="${C_DIM}[SKIPPED]${C_RESET}    "
      ((opt_pending++))
    fi

    echo -e "  $(printf '%2d' "$idx")) ${status_lbl} [${pts}★] ${title}${C_DIM}${note_lbl}${C_RESET}"
    ((idx++))
  done

  echo ""
  echo "Summary: ${applied_count} applied, ${rec_pending} recommended to apply, ${opt_pending} optional/excluded."
}

run_check_mode() {
  echo -e "${C_BOLD}Strata Host Performance Setup — Read-Only Check${C_RESET}"
  echo ""
  print_check_summary
  echo -e "${C_DIM}Read-only check complete. No changes were made to the system.${C_RESET}"
}

show_check_page() {
  while true; do
  if declare -F refresh_strata_bin >/dev/null 2>&1; then
    refresh_strata_bin
  fi
    print_header
    local body=""
    body+="$(echo -e "${C_BOLD}Read-Only Detection & Applicability Summary${C_RESET}")"$'\n\n'
    body+="$(print_check_summary)"$'\n\n'
    body+="$(echo -e "  ${C_DIM}Read-only summary. Press ${C_BOLD}[i / b / Enter / Esc]${C_RESET}${C_DIM} to return to Index, or ${C_BOLD}[q]${C_RESET}${C_DIM} to Quit.${C_RESET}")"$'\n\n'
    printf "%s" "$body"
    local body_lines lines_up action=""
    body_lines="$(printf "%s" "$body" | wc -l | tr -d '[:space:]')"
    lines_up=$(( LIVE_STATS_COUNT + POST_HEADER_LINES + body_lines ))
    read_step_action action "$lines_up"
    case "$action" in
      __refresh__) ;;
      __esc__|""|b|B|i|I) return 0 ;;
      q|Q) exit 0 ;;
      u|U)
        if [[ "$STRATA_UPDATE_AVAILABLE" == true ]] && declare -F run_strata_option >/dev/null 2>&1; then
          run_strata_option "update" true
        fi
        ;;
      *) ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  LIST_PLUGINS=false
  DOWNLOAD_PLUGINS=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check) CHECK_ONLY=true ;;
      --no-plugins) NO_PLUGINS=true ;;
      --list-plugins) LIST_PLUGINS=true ;;
      --download-plugins) DOWNLOAD_PLUGINS=true ;;
      --plugin|--with)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then
          echo "Error: $1 requires a plugin name." >&2
          usage >&2
          exit 2
        fi
        IFS=',' read -ra _p_list <<< "$2"
        for _p_item in "${_p_list[@]}"; do
          [[ -n "$_p_item" ]] && REQUESTED_HOST_PLUGINS+=("$_p_item")
        done
        shift
        ;;
      --plugin=*|--with=*)
        _p_val="${1#*=}"
        if [[ -z "$_p_val" ]]; then
          echo "Error: ${1%%=*} requires a plugin name." >&2
          usage >&2
          exit 2
        fi
        IFS=',' read -ra _p_list <<< "$_p_val"
        for _p_item in "${_p_list[@]}"; do
          [[ -n "$_p_item" ]] && REQUESTED_HOST_PLUGINS+=("$_p_item")
        done
        ;;
      --strata-api-key)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then
          echo "Error: --strata-api-key requires a non-empty value." >&2
          usage >&2
          exit 2
        fi
        STRATA_API_KEY="$2"
        export STRATA_API_KEY
        shift
        ;;
      --strata-api-key=*)
        STRATA_API_KEY="${1#*=}"
        if [[ -z "$STRATA_API_KEY" ]]; then
          echo "Error: --strata-api-key requires a non-empty value." >&2
          usage >&2
          exit 2
        fi
        export STRATA_API_KEY
        ;;
      -h|--help) usage; exit 0 ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done

  if [[ "$LIST_PLUGINS" == true ]]; then
    discover_host_plugins
    echo "Host plugins:"
    for _pid in "${AVAILABLE_HOST_PLUGINS[@]}"; do
      printf "  %-16s %s\n" "$_pid" "${HOST_PLUGIN_DESCS[$_pid]:-}"
    done
    _reg="$(_registry_file || true)"
    if [[ -n "$_reg" && -f "$_reg" ]]; then
      echo ""
      echo "Tweak packs:"
      awk -F'\t' '$1=="tweaks" {printf "  %-16s %s\n", $2, $4}' "$_reg"
    fi
    exit 0
  fi

  if [[ "$DOWNLOAD_PLUGINS" == true ]]; then
    _reg="$(_registry_file || true)"
    if [[ -z "$_reg" || ! -f "$_reg" ]]; then
      echo "Error: could not locate or download plugins/registry.tsv." >&2
      exit 1
    fi
    while IFS=$'\t' read -r _rcat _rid _rname _rdesc _rfile _rsha; do
      [[ -n "$_rcat" && -n "$_rid" ]] || continue
      echo "Caching ${_rcat}/${_rid}.sh..."
      load_plugin "$_rcat" "$_rid" || exit 1
    done < "$_reg"
    echo "All plugins cached in ${PLUGIN_CACHE_DIR}."
    exit 0
  fi

  trap 'cleanup_all_on_exit' EXIT
  if [[ "$CHECK_ONLY" == true ]]; then
    detect_environment
    load_applicable_tweak_packs
    for _req_p in "${REQUESTED_HOST_PLUGINS[@]}"; do
      load_plugin hosts "$_req_p" || exit 1
    done
    run_check_mode
    exit 0
  fi

  if [[ $EUID -ne 0 && -t 0 ]] && command -v sudo >/dev/null 2>&1 && ! sudo -n true >/dev/null 2>&1; then
    if [[ "$IS_MACOS" == true ]]; then
      echo -e "${C_DIM}Sudo access is used for hardware sensors (powermetrics GPU/CPU power) and applying optimizations.${C_RESET}"
    else
      echo -e "${C_DIM}Sudo access is used for hardware sensors (RAPL CPU power, DMI RAM info) and applying optimizations.${C_RESET}"
    fi
    sudo -v || true
  fi
  detect_platform_basics
  ensure_script_tools
  detect_environment
  load_applicable_tweak_packs
  for _req_p in "${REQUESTED_HOST_PLUGINS[@]}"; do
    load_plugin hosts "$_req_p" || true
  done
  show_index
fi
