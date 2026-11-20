#!/usr/bin/env bash
# ==============================================================================
# Strata Host Performance Optimizer & Setup Wizard
# ==============================================================================
# Interactive TUI wizard to apply, inspect, and revert host-level performance
# optimizations for running Strata LLM inference (and install/manage Strata).
#
# Supported distributions:
#   - Arch-based (CachyOS, Arch Linux, EndeavourOS, Manjaro)
#   - Fedora-based (Fedora, Nobara)
#   - Debian-based (Debian, Ubuntu, Pop!_OS, Linux Mint)
#   - openSUSE-based (Tumbleweed, Leap, SLE)
# ==============================================================================

set -uo pipefail

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
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
[[ -n "$TARGET_HOME" ]] || TARGET_HOME="$HOME"
STRATA_BIN="" STRATA_VERSION="" STRATA_RUNNING_PRESET="" STRATA_RUNNING_URL="" STRATA_DOCKER_CONTAINER="" STRATA_DOCKER_IMAGE=""
STRATA_API_KEY="${STRATA_API_KEY:-}"
[[ -n "$STRATA_API_KEY" ]] && export STRATA_API_KEY
CHECK_ONLY=false
DISTRO_FAMILY="unknown" DISTRO_ID="unknown" OS_PRETTY="" KERNEL_VER="" AUR_HELPER="" HAS_SYSTEMD=true IS_UNRAID=false IS_TRUENAS=false IS_SYNOLOGY=false
HAS_NVIDIA=false HAS_NVIDIA_POWERD=false HAS_AMD=false HAS_INTEL_GPU=false HAS_INTEL_ARC=false
HAS_AMD_APU=false HAS_AMD_PREBUILT_GFX=false AMD_GTT_TOTAL_MB=0
HAS_AMD_INSTINCT=false HAS_AMD_NON_INSTINCT=false
HAS_NVIDIA_TESLA=false HAS_NVIDIA_NON_TESLA=false NVIDIA_COMPUTE_MODE_NON_DEFAULT=false
HAS_NVIDIA_DATACENTER=false HAS_NVIDIA_PASSIVE=false HAS_NVIDIA_LEGACY_PSTATE_CARD=false
HAS_NVIDIA_KEPLER=false HAS_NVIDIA_MAXWELL=false HAS_NVIDIA_PASCAL=false HAS_NVIDIA_VOLTA_SM70=false
HAS_NVIDIA_NVSWITCH=false IS_DGX_SPARK=false HAS_NVIDIA_UNIFIED_MEM=false
NVIDIA_DRIVER_VER="" NVIDIA_DRIVER_MAJOR=0 NVIDIA_LIVE_EXTRA_FIELDS=""
NVIDIA_MIG_ANY_ENABLED=false NVIDIA_MIG_ANY_PEND_ENABLED=false
GPU_SUMMARY="" GPU_RAW="" AMD_GFX_SUMMARY="" AMD_MISSING_GFX_SUMMARY="" CPU_SUMMARY="" RAM_GB=0 RAM_DETAILS="" NVIDIA_VRAM_MB=0 TOTAL_VRAM_MB=0
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

# ------------------------------------------------------------------------------
# Core Helpers (Privileges, Packages, Services, Bootloader)
# ------------------------------------------------------------------------------
run_root() {
  [[ "${CHECK_ONLY:-false}" == true ]] && return 1
  if [[ $EUID -eq 0 ]]; then "$@"
  else sudo "$@"; fi
}

run_as_user() {
  local env_prefix="" _kv=""
  local -a _rt_env=()
  [[ -n "${STRATA_API_KEY:-}" ]] && printf -v env_prefix 'export STRATA_API_KEY=%q; ' "$STRATA_API_KEY"
  _fill_strata_runtime_env_array _rt_env
  for _kv in ${_rt_env[@]+"${_rt_env[@]}"}; do
    env_prefix+="export ${_kv}; "
  done
  if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
    if command -v runuser >/dev/null 2>&1; then
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
    if command -v runuser >/dev/null 2>&1; then
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

resolve_rc_script() {
  local name="${1%.service}"
  if [[ -x "/etc/rc.d/rc.strata.${name}" ]]; then
    echo "/etc/rc.d/rc.strata.${name}"
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
  else
    service_installed "$1"
  fi
}

service_ctl() {
  local action="$1" unit="$2"
  if [[ "$HAS_SYSTEMD" == true ]]; then
    run_root systemctl "$action" "$unit"
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
  if [[ "$HAS_SYSTEMD" == true ]]; then
    run_root tee "/etc/systemd/system/${unit}" >/dev/null
    run_root systemctl daemon-reload
    refresh_unit_files_cache
    run_root systemctl enable --now "$unit"
    return $?
  fi

  local name="${unit%.service}" rc_script="/etc/rc.d/rc.strata.${unit%.service}"
  local content env_cmds="" start_cmds="" stop_cmds="" line cmd ignore_err ev ek evv
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

  run_root tee "$rc_script" >/dev/null <<EOF
#!/bin/sh
# Managed by strata-performance-setup (${unit})
${env_cmds}case "\$1" in
  start)
${start_cmds:-    :}
    ;;
  stop)
${stop_cmds:-    :}
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
    add_boot_hook "/etc/rc.d/rc.local" "# strata:${name}" "[ -x ${rc_script} ] && ${rc_script} start # strata:${name}" "#!/bin/sh"
    run_root chmod +x /etc/rc.d/rc.local
  fi
  run_root "$rc_script" start
}

remove_service() {
  local unit="$1"
  if [[ "$HAS_SYSTEMD" == true ]]; then
    run_root systemctl disable --now "$unit" 2>/dev/null || true
    run_root rm -f "/etc/systemd/system/${unit}"
    run_root systemctl daemon-reload
    refresh_unit_files_cache
    return 0
  fi

  local name="${unit%.service}" rc_script
  if rc_script="$(resolve_rc_script "$unit")"; then
    run_root sh "$rc_script" stop >/dev/null 2>&1 || true
  fi
  run_root rm -f "/etc/rc.d/rc.strata.${name}"
  if [[ "$IS_UNRAID" == true ]]; then
    run_root rm -f "/boot/config/strata/rc.strata.${name}"
    remove_boot_hook "/boot/config/go" "# strata:${name}"
  fi
  if [[ "$IS_SYNOLOGY" == true ]]; then
    run_root rm -f "/usr/local/etc/rc.d/strata-${name}.sh"
  fi
  remove_boot_hook "/etc/rc.d/rc.local" "# strata:${name}"
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
  [[ "$mode" == "aur" ]] && aur_install "${missing[@]}" || pkg_install "${missing[@]}"
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
  local d
  for d in /boot/loader/entries /efi/loader/entries /boot/efi/loader/entries; do
    compgen -G "$d/*.conf" >/dev/null 2>&1 && { echo "$d"; return 0; }
  done
  return 1
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

has_kernel_param() {
  local param="$1" f
  _file_has_kparam "$param" /proc/cmdline && return 0
  for f in /etc/default/limine /etc/default/grub /etc/kernel/cmdline /boot/refind_linux.conf /boot/loader/entries/*.conf /efi/loader/entries/*.conf /boot/efi/loader/entries/*.conf /boot/efi/EFI/Slackware/elilo.conf /etc/elilo.conf /etc/lilo.conf; do
    _file_has_kparam "$param" "$f" && return 0
  done
  return 1
}

add_kernel_param() {
  local param="$1" bls_dir
  _file_has_kparam "$param" /proc/cmdline && return 0

  if [[ "$DISTRO_FAMILY" == "fedora" || "$DISTRO_FAMILY" == "suse" ]] && command -v grubby >/dev/null 2>&1 && [[ ! -f /etc/default/limine ]]; then
    run_root grubby --update-kernel=ALL --args="$param" || true
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${param}' via grubby (reboot required).${C_RESET}"
    return 0
  fi

  if [[ -f /etc/default/limine ]]; then
    if ! _file_has_kparam "$param" /etc/default/limine; then
      if grep -qE '^KERNEL_CMDLINE\[default\]\+?="' /etc/default/limine; then
        run_root sed -i "s/\(KERNEL_CMDLINE\[default\]+\{0,1\}=\"[^\"]*\)\"/\1 ${param}\"/" /etc/default/limine
        run_root sed -i 's/KERNEL_CMDLINE\[default\]\(+\{0,1\}\)=\" /KERNEL_CMDLINE[default]\1=\"/' /etc/default/limine
      else
        echo "KERNEL_CMDLINE[default]+=\"${param}\"" | run_root tee -a /etc/default/limine >/dev/null
      fi
      command -v limine-mkinitcpio >/dev/null 2>&1 && run_root limine-mkinitcpio || true
    fi
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${param}' to /etc/default/limine (reboot required).${C_RESET}"
  elif [[ -f /etc/default/grub ]]; then
    if ! _file_has_kparam "$param" /etc/default/grub; then
      if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT="' /etc/default/grub; then
        run_root sed -i "s/\(^GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 ${param}\"/" /etc/default/grub
        run_root sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=\" /GRUB_CMDLINE_LINUX_DEFAULT=\"/' /etc/default/grub
      elif grep -qE "^GRUB_CMDLINE_LINUX_DEFAULT='" /etc/default/grub; then
        run_root sed -i "s/\(^GRUB_CMDLINE_LINUX_DEFAULT='[^']*\)'/\1 ${param}'/" /etc/default/grub
        run_root sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=' /GRUB_CMDLINE_LINUX_DEFAULT='/" /etc/default/grub
      elif grep -qE '^GRUB_CMDLINE_LINUX="' /etc/default/grub; then
        run_root sed -i "s/\(^GRUB_CMDLINE_LINUX=\"[^\"]*\)\"/\1 ${param}\"/" /etc/default/grub
        run_root sed -i 's/^GRUB_CMDLINE_LINUX=\" /GRUB_CMDLINE_LINUX=\"/' /etc/default/grub
      else
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${param}\"" | run_root tee -a /etc/default/grub >/dev/null
      fi
      if command -v grub-mkconfig >/dev/null 2>&1; then
        run_root grub-mkconfig -o /boot/grub/grub.cfg || true
      elif command -v grub2-mkconfig >/dev/null 2>&1; then
        run_root grub2-mkconfig -o /boot/grub2/grub.cfg || true
      fi
    fi
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${param}' to /etc/default/grub (reboot required).${C_RESET}"
  elif [[ -f /etc/kernel/cmdline ]]; then
    if ! _file_has_kparam "$param" /etc/kernel/cmdline; then
      run_root sed -i "s/[[:space:]]*$/ ${param}/; s/^[[:space:]]*//" /etc/kernel/cmdline
      command -v bootctl >/dev/null 2>&1 && run_root bootctl update >/dev/null 2>&1 || true
    fi
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${param}' to /etc/kernel/cmdline (reboot required).${C_RESET}"
  elif bls_dir="$(bls_entries_dir)"; then
    local f
    for f in "$bls_dir"/*.conf; do
      [[ -f "$f" ]] || continue
      if ! _file_has_kparam "$param" "$f"; then
        if grep -qE '^options[[:space:]]' "$f"; then
          run_root sed -i "s/^options .*/& ${param}/" "$f"
        else
          echo "options ${param}" | run_root tee -a "$f" >/dev/null
        fi
      fi
    done
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${param}' to systemd-boot entries in ${bls_dir} (reboot required).${C_RESET}"
  elif [[ -f /boot/refind_linux.conf ]]; then
    _file_has_kparam "$param" /boot/refind_linux.conf || run_root sed -i -E "s/\"[[:space:]]*$/ ${param}\"/" /boot/refind_linux.conf
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${param}' to /boot/refind_linux.conf (reboot required).${C_RESET}"
  elif [[ -f /boot/efi/EFI/Slackware/elilo.conf || -f /etc/elilo.conf ]]; then
    local elilo_f="/boot/efi/EFI/Slackware/elilo.conf"
    [[ -f "$elilo_f" ]] || elilo_f="/etc/elilo.conf"
    if ! _file_has_kparam "$param" "$elilo_f"; then
      if grep -qE '^[[:space:]]*append="' "$elilo_f"; then
        run_root sed -i -E "s/^([[:space:]]*append=\"[^\"]*)\"/\1 ${param}\"/" "$elilo_f"
        run_root sed -i -E 's/^([[:space:]]*append=") /\1/' "$elilo_f"
      else
        echo "append=\"${param}\"" | run_root tee -a "$elilo_f" >/dev/null
      fi
    fi
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${param}' to ${elilo_f} (reboot required).${C_RESET}"
  elif [[ -f /etc/lilo.conf ]]; then
    if ! _file_has_kparam "$param" /etc/lilo.conf; then
      if grep -qE '^[[:space:]]*append="' /etc/lilo.conf; then
        run_root sed -i -E "s/^([[:space:]]*append=\"[^\"]*)\"/\1 ${param}\"/" /etc/lilo.conf
        run_root sed -i -E 's/^([[:space:]]*append=") /\1/' /etc/lilo.conf
      else
        echo "append=\"${param}\"" | run_root tee -a /etc/lilo.conf >/dev/null
      fi
      command -v lilo >/dev/null 2>&1 && run_root lilo || true
    fi
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${param}' to /etc/lilo.conf (reboot required).${C_RESET}"
  else
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_YELLOW}Please add '${param}' to your bootloader kernel command line manually.${C_RESET}"
  fi
}

remove_kernel_param() {
  local param="$1" changed=false
  if _file_has_kparam "$param" /etc/default/limine; then
    _remove_kparam_from_file "$param" /etc/default/limine
    command -v limine-mkinitcpio >/dev/null 2>&1 && run_root limine-mkinitcpio || true
    changed=true
  fi
  if _file_has_kparam "$param" /etc/default/grub; then
    _remove_kparam_from_file "$param" /etc/default/grub
    if command -v grub-mkconfig >/dev/null 2>&1; then
      run_root grub-mkconfig -o /boot/grub/grub.cfg || true
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
      run_root grub2-mkconfig -o /boot/grub2/grub.cfg || true
    fi
    changed=true
  fi
  if _file_has_kparam "$param" /etc/kernel/cmdline; then
    _remove_kparam_from_file "$param" /etc/kernel/cmdline
    command -v bootctl >/dev/null 2>&1 && run_root bootctl update >/dev/null 2>&1 || true
    changed=true
  fi
  if [[ "$DISTRO_FAMILY" == "fedora" || "$DISTRO_FAMILY" == "suse" ]] && command -v grubby >/dev/null 2>&1; then
    run_root grubby --update-kernel=ALL --remove-args="$param" >/dev/null 2>&1 && changed=true || true
  fi
  local ef
  for ef in /boot/loader/entries/*.conf /efi/loader/entries/*.conf /boot/efi/loader/entries/*.conf; do
    if [[ -f "$ef" ]] && _file_has_kparam "$param" "$ef"; then
      _remove_kparam_from_file "$param" "$ef"
      changed=true
    fi
  done
  if _file_has_kparam "$param" /boot/refind_linux.conf; then
    _remove_kparam_from_file "$param" /boot/refind_linux.conf
    changed=true
  fi
  for ef in /boot/efi/EFI/Slackware/elilo.conf /etc/elilo.conf; do
    if [[ -f "$ef" ]] && _file_has_kparam "$param" "$ef"; then
      _remove_kparam_from_file "$param" "$ef"
      changed=true
    fi
  done
  if _file_has_kparam "$param" /etc/lilo.conf; then
    _remove_kparam_from_file "$param" /etc/lilo.conf
    command -v lilo >/dev/null 2>&1 && run_root lilo || true
    changed=true
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
  if [[ $EUID -eq 0 || ( -r /var/run/docker.sock && -w /var/run/docker.sock ) ]]; then
    timeout 3 docker "$@" 2>/dev/null
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n timeout 3 docker "$@" 2>/dev/null
  else
    return 1
  fi
}

refresh_strata_bin() {
  if command -v strata >/dev/null 2>&1; then STRATA_BIN="$(command -v strata)"
  elif [[ -x "$TARGET_HOME/.local/bin/strata" ]]; then STRATA_BIN="$TARGET_HOME/.local/bin/strata"
  elif [[ -x "/usr/local/bin/strata" ]]; then STRATA_BIN="/usr/local/bin/strata"
  else STRATA_BIN=""; fi

  if [[ -n "$STRATA_BIN" ]]; then
    local raw_ver
    raw_ver="$(run_as_user_exec "$STRATA_BIN" --version 2>/dev/null | head -n1 || true)"
    if [[ -n "$raw_ver" ]]; then
      STRATA_VERSION="$(sed -E 's/^strata[[:space:]]+//; s/; python [^)]*//g' <<< "$raw_ver")"
    else
      STRATA_VERSION="installed (${STRATA_BIN})"
    fi
  else
    STRATA_VERSION=""
  fi
  STRATA_DOCKER_CONTAINER=""
  STRATA_DOCKER_IMAGE=""
  if [[ -z "$STRATA_BIN" ]]; then
    local _dc_line=""
    _dc_line="$(_docker_ro ps --format '{{.Names}}|{{.Image}}' | awk -F'|' 'tolower($2) ~ /(^|[\/_-])strata(:|@|$)/ {print $1 "|" $2; exit}' || true)"
    if [[ -n "$_dc_line" ]]; then
      IFS='|' read -r STRATA_DOCKER_CONTAINER STRATA_DOCKER_IMAGE <<< "$_dc_line"
    fi
  fi
}

refresh_strata_running() {
  STRATA_RUNNING_PRESET=""
  STRATA_RUNNING_URL=""
  [[ -n "$STRATA_BIN" ]] || return 0
  local st_json parsed=""
  st_json="$(run_as_user_exec "$STRATA_BIN" launch --status --output json 2>/dev/null || true)"
  if [[ -n "$st_json" ]] && command -v python3 >/dev/null 2>&1; then
    parsed="$(python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    running = d.get("running") or []
    if running and isinstance(running[0], dict):
        r = running[0]
        nm = str(r.get("name") or "").replace("|", "/").replace("\n", " ")
        ur = str(r.get("url") or "").replace("|", "").replace("\n", "")
        print(nm + "|" + ur)
    break
' <<< "$st_json" 2>/dev/null || true)"
    if [[ -n "$parsed" ]]; then
      IFS='|' read -r STRATA_RUNNING_PRESET STRATA_RUNNING_URL <<< "$parsed"
    fi
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

amd_gfx_is_uma_apu() {
  case "$1" in
    gfx115[0-9a-f]|gfx1103|gfx1033|gfx1035|gfx1036|gfx1037|gfx90c|gfx902|gfx909) return 0 ;;
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

strata_amd_opt_in_env_list() {
  amd_missing_has_gfx "gfx1150" && echo "STRATA_EXPERIMENTAL_GFX1150=1"
  amd_missing_has_gfx "gfx1103" && echo "STRATA_EXPERIMENTAL_GFX1103=1"
  return 0
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
  [[ "$DISTRO_FAMILY" != "unknown" && "$DISTRO_FAMILY" != "synology" ]] || return 0
  [[ "$IS_UNRAID" == true || "$IS_TRUENAS" == true ]] && return 0
  [[ -t 0 ]] || return 0
  local missing_cmds=() missing_pkgs=()
  if ! command -v lspci >/dev/null 2>&1; then
    missing_cmds+=("lspci"); missing_pkgs+=("pciutils")
  fi
  if ! command -v curl >/dev/null 2>&1; then
    missing_cmds+=("curl"); missing_pkgs+=("curl")
  fi
  if ! command -v python3 >/dev/null 2>&1; then
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
  HAS_NVIDIA_TESLA=false HAS_NVIDIA_NON_TESLA=false NVIDIA_COMPUTE_MODE_NON_DEFAULT=false
  HAS_NVIDIA_DATACENTER=false HAS_NVIDIA_PASSIVE=false HAS_NVIDIA_LEGACY_PSTATE_CARD=false
  HAS_NVIDIA_KEPLER=false HAS_NVIDIA_MAXWELL=false HAS_NVIDIA_PASCAL=false HAS_NVIDIA_VOLTA_SM70=false
  HAS_NVIDIA_NVSWITCH=false IS_DGX_SPARK=false HAS_NVIDIA_UNIFIED_MEM=false
  NVIDIA_DRIVER_VER="" NVIDIA_DRIVER_MAJOR=0 NVIDIA_LIVE_EXTRA_FIELDS=""
  SYS_VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
  PRODUCT_NAME="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
  local dt_dir="${STRATA_DT_DIR:-/proc/device-tree}"
  if grep -qiE "GB10|DGX Spark|Grace Blackwell" "$dt_dir/model" /sys/class/dmi/id/product_name 2>/dev/null; then
    IS_DGX_SPARK=true
    HAS_NVIDIA_UNIFIED_MEM=true
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

  RAM_GB="$(awk '/MemTotal/ {printf "%.0f", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0)"
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
  refresh_strata_bin
}

# ------------------------------------------------------------------------------
# Extra Helpers (kernel param values, sysctl snapshots, NVIDIA caches, PCIe diag)
# ------------------------------------------------------------------------------
kernel_param_value() {
  local name="$1" esc f v
  esc="$(_escape_ere "$name")"
  v="$(tr ' ' '\n' </proc/cmdline 2>/dev/null | grep -m1 -E "^${esc}=" | cut -d= -f2- || true)"
  [[ -n "$v" ]] && { echo "$v"; return 0; }
  for f in /etc/default/limine /etc/default/grub /etc/kernel/cmdline /boot/refind_linux.conf /boot/loader/entries/*.conf /efi/loader/entries/*.conf /boot/efi/loader/entries/*.conf; do
    [[ -r "$f" ]] || continue
    v="$(grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep -oE "(^|[[:space:]\"'])${esc}=[^ \"']+" | head -n1 | sed -E 's/^[[:space:]"'\'']+//' | cut -d= -f2- || true)"
    [[ -n "$v" ]] && { echo "$v"; return 0; }
  done
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
  local active=()
  unit_active tlp.service && active+=("TLP")
  unit_active auto-cpufreq.service && active+=("auto-cpufreq")
  if unit_active tuned.service && unit_active power-profiles-daemon.service; then active+=("tuned+power-profiles-daemon"); fi
  (( ${#active[@]} > 0 )) || return 0
  printf "%bPower:  %b[!] %s active (may override governor/EPP set by this tool)%b" "${C_DIM}" "${C_YELLOW}" "${active[*]}" "${C_RESET}"
}

# Appends one "PCIe:" diagnostic line per discrete/integrated GPU (link width/gen + Resizable BAR).
append_gpu_pcie_lines() {
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
# Step Registry
# ------------------------------------------------------------------------------
ALL_STEPS=(
  nvidia_fabricmanager gpu_unlock amd_apu_memory amd_cwsr_disable
  nvidia_mig_disable nvidia_sm70_table nvidia_pstate
  gpu_groups intel_compute_stack lact_overclock jetson_perf jetson_fan
  nvidia_power_limit amd_gpu_perf intel_gpu_perf ryzenadj_tdp nvidia_ecc nvidia_compute_mode
  nvidia_power_cap pcie_acs_disable amd_instinct_partition
  headless_target numactl_interleave amd_x3d_mode intel_rapl msi_cooling lenovo_legion
  asus_perf dell_thermal system76_perf tuxedo_perf acpi_platform_profile intel_pcore_pinning zram_swap numa_balancing
  sysctl_tuning memlock_realtime nvme_tuning
  nvidia_persistenced nvidia_powerd intel_thermald iommu_pt scx_scheduler
  net_tuning irq_balance
  prevent_sleep hugepages_1g
  cpu_performance cstate_limit pcie_aspm nvidia_clock_lock tuned_profile
)
ACTIVE_STEPS=()

VM_HIDDEN_STEPS=" nvidia_fabricmanager pcie_acs_disable amd_instinct_partition msi_cooling acpi_platform_profile asus_perf dell_thermal lenovo_legion system76_perf tuxedo_perf cpu_performance cstate_limit pcie_aspm ryzenadj_tdp intel_rapl intel_thermald amd_x3d_mode intel_pcore_pinning tuned_profile jetson_perf jetson_fan "
build_active_steps() {
  local step candidates=() pts
  for step in "${ALL_STEPS[@]}"; do
    [[ -n "$IS_VIRT" && "$VM_HIDDEN_STEPS" == *" $step "* ]] && continue
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
  case "$1" in
    gpu_unlock) [[ "$DISTRO_FAMILY" != "arch" ]] ;;
    nvidia_pstate|pcie_acs_disable) return 0 ;;
    *) return 1 ;;
  esac
}

is_opt_in_step() {
  case "$1" in
    nvidia_power_cap|amd_instinct_partition|hugepages_1g) return 0 ;;
    *) return 1 ;;
  esac
}

is_high_idle_step() {
  case "$1" in
    cpu_performance|pcie_aspm|cstate_limit|nvidia_clock_lock|tuned_profile) return 0 ;;
    *) return 1 ;;
  esac
}

is_recommended_step() {
  is_experimental_step "$1" && return 1
  is_opt_in_step "$1" && return 1
  is_high_idle_step "$1" && return 1
  return 0
}

is_laptop_recommended_step() {
  is_recommended_step "$1" || return 1
  case "$1" in
    prevent_sleep|acpi_platform_profile|msi_cooling|asus_perf|dell_thermal|lenovo_legion|system76_perf|tuxedo_perf|amd_gpu_perf|intel_gpu_perf|nvidia_persistenced|nvidia_fabricmanager|nvidia_mig_disable)
      return 1 ;;
    *)
      return 0 ;;
  esac
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
  local has_opt_ex=false has_exp_ex=false extra_excl=""
  for step in "${ACTIVE_STEPS[@]}"; do
    is_experimental_step "$step" && has_exp_ex=true
    is_opt_in_step "$step" && has_opt_ex=true
  done
  [[ "$has_opt_ex" == true ]] && extra_excl+=", opt-in trade-offs ([OPT])"
  [[ "$has_exp_ex" == true ]] && extra_excl+=", experimental options ([EXP])"
  if [[ "$scope" == "laptop" ]]; then
    echo -e "${C_DIM}Excluded: high-idle-power options ([!])${extra_excl}, prevent sleep, GPU high-idle-clock/persistence, platform & vendor performance profiles, Strata setup.${C_RESET}\n"
  else
    echo -e "${C_DIM}Excluded: high-idle-power options ([!]: CPU Performance, PCIe ASPM, CPU C-State Limit, NVIDIA Clock Lock, tuned profile)${extra_excl}, Strata setup.${C_RESET}\n"
  fi

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

# 1. Prevent Sleep
applicable_prevent_sleep() { [[ "$HAS_SYSTEMD" == true ]]; }
title_prevent_sleep() { echo "Disable System Sleep & Lid-Close Suspend (Server Uptime)"; }
status_prevent_sleep() { [[ "$(systemctl is-enabled sleep.target 2>/dev/null || true)" == "masked" ]]; }
explain_prevent_sleep() {
  cat <<'EOF'
Impact:
  Masks systemd sleep/suspend/hibernate targets and ignores lid-close events
  on laptops so long-running Strata inference is never interrupted.
EOF
}
apply_prevent_sleep() {
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
  run_root systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
  if [[ -f /etc/systemd/logind.conf.d/99-strata-nosleep.conf ]]; then
    run_root rm -f /etc/systemd/logind.conf.d/99-strata-nosleep.conf
    run_root systemctl reload-or-restart systemd-logind || true
  fi
}

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
  run_root systemctl enable --now asusd.service 2>/dev/null || true
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
  run_root systemctl enable --now legiond.service 2>/dev/null || true
}
revert_lenovo_legion() { run_root systemctl disable --now legiond.service 2>/dev/null || true; }

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
  run_root systemctl enable --now system76-power.service 2>/dev/null || true
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
  run_root systemctl enable --now tccd.service 2>/dev/null || true
}
revert_tuxedo_perf() { run_root systemctl disable --now tccd.service 2>/dev/null || true; }

# 4. CPU Performance
applicable_cpu_performance() { [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]] || command -v powerprofilesctl >/dev/null 2>&1; }
title_cpu_performance() { echo "CPU Performance Profile & Governor (performance)"; }
note_cpu_performance() { echo -e "${C_YELLOW}[!]${C_RESET}"; }
status_cpu_performance() {
  local gov ppd
  gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)"
  ppd="$(powerprofilesctl get 2>/dev/null || true)"
  [[ "$gov" == "performance" ]] || (service_installed strata-cpu-perf.service && [[ "$ppd" == "performance" ]])
}
explain_cpu_performance() {
  cat <<'EOF'
Impact:
  Sets power-profiles-daemon to 'performance', enables CPU boost, and forces
  scaling_governor='performance' (slightly faster ramp-up from idle).
  Also switches amd_pstate / intel_pstate to 'active' mode (when present) so the
  hardware EPP hint ('performance') is honored.
EOF
  echo -e "\n${C_YELLOW}[WARNING] Enabling this option increases idle power consumption (often +5-10W)${C_RESET}"
  echo -e "${C_YELLOW}          and hardly provides any sustained performance gains over 'powersave'${C_RESET}"
  echo -e "${C_YELLOW}          when EPP (energy_performance_preference) is already 'performance'.${C_RESET}"
}
apply_cpu_performance() {
  if unit_active tlp.service || unit_active auto-cpufreq.service; then
    echo -e "${C_YELLOW}TLP/auto-cpufreq is active and may override the governor/EPP set here; consider disabling it.${C_RESET}"
  fi
  if ! command -v cpupower >/dev/null 2>&1; then
    case "$DISTRO_FAMILY" in
      arch)   prompt_install_deps repo cpupower || true ;;
      fedora) prompt_install_deps repo kernel-tools || true ;;
      debian) pkg_available repo linux-cpupower && prompt_install_deps repo linux-cpupower || true ;;
      suse)   prompt_install_deps repo cpupower || true ;;
    esac
  fi
  command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl set performance 2>/dev/null || true
  if [[ ! -f "$PSTATE_MARKER" ]]; then
    local pf
    for pf in /sys/devices/system/cpu/amd_pstate/status /sys/devices/system/cpu/intel_pstate/status; do
      [[ -r "$pf" ]] && echo "${pf}=$(cat "$pf")"
    done | run_root tee "$PSTATE_MARKER" >/dev/null
  fi
  install_service strata-cpu-perf.service <<'EOF'
[Unit]
Description=Set CPU Governor and Power Profile to Performance
After=multi-user.target power-profiles-daemon.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl set performance || true; [ -w /sys/devices/system/cpu/cpufreq/boost ] && echo 1 > /sys/devices/system/cpu/cpufreq/boost || true; for p in /sys/devices/system/cpu/amd_pstate/status /sys/devices/system/cpu/intel_pstate/status; do [ -w "$p" ] && echo active > "$p"; done; for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$g" ] && echo performance > "$g"; done; for e in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do [ -w "$e" ] && echo performance > "$e"; done; true'

[Install]
WantedBy=multi-user.target
EOF
}
revert_cpu_performance() {
  remove_service strata-cpu-perf.service
  if [[ -f "$PSTATE_MARKER" ]]; then
    local pf pm
    while IFS='=' read -r pf pm; do
      [[ -n "$pf" && -n "$pm" && -w "$pf" ]] && echo "$pm" | run_root tee "$pf" >/dev/null 2>&1
    done < "$PSTATE_MARKER"
    run_root rm -f "$PSTATE_MARKER"
  fi
  command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl set balanced 2>/dev/null || true
  run_root sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$g" ] && echo powersave > "$g"; done' 2>/dev/null || true
}

# 5. Memlock & Realtime
applicable_memlock_realtime() { return 0; }
title_memlock_realtime() { echo "Unlimited Memory Lock & Realtime Privileges (memlock=unlimited)"; }
status_memlock_realtime() {
  if [[ -n "$STRATA_DOCKER_CONTAINER" ]]; then
    _docker_ro inspect --format '{{range .HostConfig.Ulimits}}{{.Name}}={{.Soft}}:{{.Hard}} {{end}}' "$STRATA_DOCKER_CONTAINER" | grep -qE '(^|[[:space:]])memlock=-1:-1([[:space:]]|$)'
    return $?
  fi
  [[ -f /etc/security/limits.d/99-strata-memlock.conf ]] && return 0
  [[ -f /etc/security/limits.d/99-realtime-privileges.conf ]] && id -nG "$TARGET_USER" 2>/dev/null | grep -qw realtime && return 0
  [[ "$IS_UNRAID" == true && "$(ulimit -l 2>/dev/null || true)" == "unlimited" ]]
}
explain_memlock_realtime() {
  cat <<'EOF'
Impact:
  Grants unlimited locked memory (memlock unlimited) and rtprio/nice limits so
  Strata can pin model weights and KV caches in RAM without swapping (no-op if
  ulimit -l is already unlimited).
  Note: Docker containers do not inherit host /etc/security/limits.d/—pass
  '--ulimit memlock=-1:-1' (or set Docker default-ulimits) for containerized Strata.
EOF
}
apply_memlock_realtime() {
  if [[ -n "$STRATA_DOCKER_CONTAINER" ]]; then
    echo -e "${C_YELLOW}Note: Docker containers ignore host /etc/security/limits.d/ — add '--ulimit memlock=-1:-1' to container '${STRATA_DOCKER_CONTAINER}' (or configure Docker default-ulimits).${C_RESET}"
    [[ "$IS_UNRAID" == true ]] && return 0
  fi
  if [[ "$DISTRO_FAMILY" == "arch" ]] && ! pkg_installed realtime-privileges; then
    prompt_install_deps repo realtime-privileges && run_root usermod -aG realtime "$TARGET_USER" 2>/dev/null || true
  fi
  run_root mkdir -p /etc/security/limits.d
  run_root tee /etc/security/limits.d/99-strata-memlock.conf >/dev/null <<EOF
$TARGET_USER - memlock unlimited
$TARGET_USER - nice -11
$TARGET_USER - rtprio 98
EOF
}
revert_memlock_realtime() { run_root rm -f /etc/security/limits.d/99-strata-memlock.conf; }

# 6. PCIe ASPM
applicable_pcie_aspm() { [[ "$HAS_ASPM" == true ]] && grep -q "performance" /sys/module/pcie_aspm/parameters/policy 2>/dev/null; }
title_pcie_aspm() { echo "PCIe ASPM Performance Policy (Low-Latency GPU Transfers)"; }
note_pcie_aspm() { echo -e "${C_YELLOW}[!]${C_RESET}"; }
status_pcie_aspm() { grep -q "\[performance\]" /sys/module/pcie_aspm/parameters/policy 2>/dev/null || has_kernel_param "pcie_aspm.policy=performance"; }
explain_pcie_aspm() {
  cat <<'EOF'
Impact:
  Sets PCIe ASPM policy to 'performance' (runtime sysfs or bootloader kernel
  parameter fallback if BIOS locks runtime writes).
EOF
  echo -e "\n${C_YELLOW}[WARNING] Disabling PCIe ASPM increases idle power consumption${C_RESET}"
  echo -e "${C_YELLOW}          and hardly provides any sustained performance gains.${C_RESET}"
}
apply_pcie_aspm() {
  if echo performance | run_root tee /sys/module/pcie_aspm/parameters/policy >/dev/null 2>&1; then
    install_service strata-pcie-aspm.service <<'EOF'
[Unit]
Description=Set PCIe ASPM Policy to Performance for Strata
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '[ -w /sys/module/pcie_aspm/parameters/policy ] && echo performance > /sys/module/pcie_aspm/parameters/policy || true'
ExecStop=/bin/sh -c '[ -w /sys/module/pcie_aspm/parameters/policy ] && echo default > /sys/module/pcie_aspm/parameters/policy || true'

[Install]
WantedBy=multi-user.target
EOF
  else
    echo -e "${C_YELLOW}Runtime sysfs write not permitted by BIOS/kernel; configuring via bootloader...${C_RESET}"
    add_kernel_param "pcie_aspm.policy=performance"
  fi
}
revert_pcie_aspm() {
  remove_service strata-pcie-aspm.service
  remove_kernel_param "pcie_aspm.policy=performance"
  echo default | run_root tee /sys/module/pcie_aspm/parameters/policy >/dev/null 2>&1 || true
}

# 7. NVIDIA Persistenced
applicable_nvidia_persistenced() {
  [[ "$HAS_NVIDIA" == true ]] && { unit_exists nvidia-persistenced.service || service_installed strata-nvidia-persistenced.service || command -v nvidia-persistenced >/dev/null 2>&1 || command -v nvidia-smi >/dev/null 2>&1; }
}
title_nvidia_persistenced() { echo "NVIDIA Persistence Mode (nvidia-persistenced)"; }
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
    run_root systemctl enable --now nvidia-persistenced.service
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
    run_root systemctl disable --now nvidia-persistenced.service 2>/dev/null || true
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
    run_root systemctl enable --now nvidia-fabricmanager.service
  else
    echo -e "${C_YELLOW}nvidia-fabricmanager.service is not available; install the matching nvidia-fabricmanager package for driver ${NVIDIA_DRIVER_VER:-installed}.${C_RESET}"
    return 1
  fi
}
revert_nvidia_fabricmanager() { run_root systemctl disable --now nvidia-fabricmanager.service 2>/dev/null || true; }

# 8. NVIDIA Dynamic Boost
applicable_nvidia_powerd() {
  [[ "$HAS_NVIDIA" == true && "$HAS_NVIDIA_POWERD" == true ]] || return 1
  [[ "$IS_LAPTOP" == true ]] || grep -qiE "Laptop GPU|Mobile|Max-Q" <<<"${NVIDIA_GPU_NAMES[*]}"
}
title_nvidia_powerd() { echo "NVIDIA Dynamic Boost Daemon (nvidia-powerd)"; }
status_nvidia_powerd() { unit_enabled nvidia-powerd.service && unit_active nvidia-powerd.service; }
explain_nvidia_powerd() { echo -e "Impact:\n  Enables Dynamic Boost to shift power budget to mobile RTX GPUs under load."; }
apply_nvidia_powerd() { run_root systemctl enable --now nvidia-powerd.service; }
revert_nvidia_powerd() { run_root systemctl disable --now nvidia-powerd.service; }

# 9. NVIDIA Power Limit
nvidia_tunable_pl_indices() {
  local i
  for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
    [[ "${NVIDIA_GPU_PL_SUPPORTED[$i]}" == true ]] && echo "$i"
  done
}
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
    out="$(run_root "$smi_bin" -i "$idx" -pl "$mx" 2>&1 || true)"
    if grep -qi "not supported" <<< "$out"; then
      echo -e "${C_YELLOW}nvidia-smi -i ${idx} -pl is not supported on ${NVIDIA_GPU_NAMES[$i]}.${C_RESET}"
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
    out="$(run_root "$smi_bin" -i "$idx" -pl "$g_cap" 2>&1 || true)"
    if grep -qiE "not supported|failed|error|invalid" <<<"$out"; then
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

# 10. LACT GPU Overclocking
applicable_lact_overclock() {
  [[ "$IS_JETSON" == true ]] && return 1
  [[ "$HAS_NVIDIA" == true || "$HAS_AMD" == true || "$HAS_INTEL_ARC" == true ]] || return 1
  local has_eligible=false
  [[ "$HAS_NVIDIA_NON_TESLA" == true && "$IS_DGX_SPARK" == false ]] && has_eligible=true
  [[ "$HAS_AMD_NON_INSTINCT" == true ]] && has_eligible=true
  [[ "$HAS_INTEL_ARC" == true ]] && has_eligible=true
  [[ "$has_eligible" == true ]] || return 1
  command -v lact >/dev/null 2>&1 || pkg_available repo lact || pkg_available aur lact
}
title_lact_overclock() { echo "LACT GPU Clock & Memory Offsets (lactd)"; }
status_lact_overclock() { unit_enabled lactd.service && [[ -f /etc/lact/config.yaml ]] && grep -qE "gpu_clock_offsets:|mem_clock_offsets:" /etc/lact/config.yaml 2>/dev/null; }
explain_lact_overclock() {
  cat <<'EOF'
Impact:
  Installs/enables LACT (lactd) and applies GPU core & VRAM clock offsets
  (e.g. +135 MHz core, +1000 MHz VRAM). Higher VRAM bandwidth directly speeds
  up LLM token generation. On AMD GPUs it also adds the bootloader parameter
  'amdgpu.ppfeaturemask=0xffffffff' (reboot) to unlock clock/power controls.
EOF
}

lact_config_file() {
  # The config path LACT's own daemon resolves.
  if [[ -n "${LACT_DAEMON_CONFIG_DIR:-}" ]]; then
    printf '%s/config.yaml\n' "${LACT_DAEMON_CONFIG_DIR%/}"
  else
    printf '/etc/lact/config.yaml\n'
  fi
}
lact_gpu_ids() {
  # GPU ids are the keys of the `gpus:` map in LACT's config, e.g.
  #   10DE:2684-1043:88EF-0000:0a:00.0
  # Ask the daemon first (it only lists the GPUs it manages); fall back to
  # building the very same id from the PCI uevent if it cannot be reached.
  local -a ids=()
  local line id uev
  if command -v lact >/dev/null 2>&1; then
    while IFS= read -r line; do
      id="${line#*: }"          # drop the "0: " index prefix of `lact cli list`
      id="${id%%[[:space:]]*}"  # the id is the first whitespace-separated token
      [[ "$id" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}- ]] || continue
      ids+=("$id")
    done < <(lact cli list 2>/dev/null || true)
  fi
  if (( ${#ids[@]} == 0 )); then
    for uev in /sys/class/drm/card[0-9]*/device/uevent; do
      [[ -r "$uev" ]] || continue
      id="$(awk -F= '
        /^PCI_ID=/        { v = $2 }
        /^PCI_SUBSYS_ID=/ { s = $2 }
        /^PCI_SLOT_NAME=/ { p = $2 }
        END               { if (v && s && p) printf "%s-%s-%s", v, s, p }' "$uev")"
      [[ -n "$id" ]] && ids+=("$id")
    done
  fi
  (( ${#ids[@]} )) || return 1
  printf '%s\n' "${ids[@]}"
}

apply_lact_overclock() {
  if ! command -v lact >/dev/null 2>&1; then
    case "$DISTRO_FAMILY" in
      arch)   prompt_install_repo_or_aur lact || return 0 ;;
      fedora) prompt_install_deps repo lact || return 0 ;;
      debian) prompt_install_deps repo lact || return 0 ;;
      suse)   prompt_install_deps repo lact || return 0 ;;
    esac
  fi
  if ! python3 -c "import yaml" >/dev/null 2>&1; then
    case "$DISTRO_FAMILY" in
      arch)   prompt_install_deps repo python-yaml || true ;;
      fedora) prompt_install_deps repo python3-pyyaml || true ;;
      debian) prompt_install_deps repo python3-yaml || true ;;
      suse)   prompt_install_deps repo python3-PyYAML || true ;;
    esac
  fi

  run_root systemctl enable --now lactd.service 2>/dev/null || true
  if [[ "$HAS_AMD" == true ]] && compgen -G "/sys/class/drm/card*/device/power_dpm_force_performance_level" >/dev/null 2>&1; then
    add_kernel_param "amdgpu.ppfeaturemask=0xffffffff"
  fi
  sleep 1

  local core_off="135" mem_off="1000" in_core in_mem
  read -r -p "GPU Core Clock offset in MHz [default: 135]: " in_core
  [[ -n "$in_core" ]] && core_off="$in_core"
  read -r -p "VRAM Memory Clock offset in MHz [default: 1000]: " in_mem
  [[ -n "$in_mem" ]] && mem_off="$in_mem"
  if ! [[ "$core_off" =~ ^-?[0-9]+$ && "$mem_off" =~ ^-?[0-9]+$ ]]; then
    echo -e "${C_RED}Clock offsets must be integers.${C_RESET}"
    return 1
  fi

  local cfg out rc i id
  cfg="$(lact_config_file)"
  if ! python3 -c "import yaml" >/dev/null 2>&1; then
    echo -e "${C_YELLOW}PyYAML is missing, cannot edit ${cfg}; set the offsets in the LACT GUI.${C_RESET}"
    return 1
  fi
  if [[ ! -f "$cfg" ]]; then
    # lactd creates a default config on its first start
    run_root systemctl restart lactd.service 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
      [[ -f "$cfg" ]] && break
      sleep 0.5
    done
  fi
  if [[ ! -f "$cfg" ]]; then
    echo -e "${C_YELLOW}${cfg} does not exist yet; start lactd once, then re-run.${C_RESET}"
    return 1
  fi

  run_root cp -n "$cfg" "${cfg}.bak.strata-setup" 2>/dev/null || true

  # `gpus:` is keyed by GPU id, so tell the editor which GPUs to configure
  local -a pyargs=("$cfg" "$core_off" "$mem_off")
  while IFS= read -r id; do
    [[ -n "$id" ]] && pyargs+=("$id")
  done < <(lact_gpu_ids || true)

  rc=0
  out="$(run_root python3 - "${pyargs[@]}" 2>&1 <<'PY'
import sys

import yaml

path, core_off, mem_off = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
requested_ids = sys.argv[4:]

try:
    with open(path) as f:
        data = yaml.safe_load(f)
except FileNotFoundError:
    data = None
except yaml.YAMLError as err:
    sys.exit(f"{path}: not valid YAML: {err}")
except OSError as err:
    sys.exit(f"{path}: could not be read: {err}")
if data is None:
    data = {}
if not isinstance(data, dict):
    sys.exit(f"{path}: the top level is not a mapping")

# LACT applies the settings of the active profile when one is selected, and the
# top level `gpus` map otherwise (see Config::gpus in lact-daemon).
profile_name = data.get("current_profile")
if profile_name:
    profiles = data.setdefault("profiles", {})
    if not isinstance(profiles, dict):
        sys.exit(f"{path}: 'profiles' is not a mapping")
    profile = profiles.get(profile_name)
    if not isinstance(profile, dict):
        profile = {}
        profiles[profile_name] = profile
    where = f"profile '{profile_name}'"
else:
    profile = data
    where = "the default profile"

gpus = profile.get("gpus")
if not isinstance(gpus, dict):
    gpus = {}
    profile["gpus"] = gpus

# On a fresh LACT install `gpus` does not exist yet, its entries are created here
gpu_ids = [gpu_id for gpu_id in requested_ids if gpu_id] or list(gpus)
if not gpu_ids:
    sys.exit("no GPU id found - is lactd running? (`lact cli list`)")

for gpu_id in gpu_ids:
    gpu = gpus.get(gpu_id)
    if not isinstance(gpu, dict):
        gpu = {}
    gpu["gpu_clock_offsets"] = {0: core_off}
    gpu["mem_clock_offsets"] = {0: mem_off}
    if gpu_id.split(":", 1)[0].upper() == "10DE":
        # Nvidia only: controls the offsets through the adaptive clock governor
        gpu.setdefault("power_mizer_mode", "Adaptive")
    gpus[gpu_id] = gpu

try:
    with open(path, "w") as f:
        yaml.safe_dump(data, f, sort_keys=False, default_flow_style=False)
except OSError as err:
    sys.exit(f"{path}: could not be written: {err}")

# Read back, so that a reported success means the file really holds the offsets
with open(path) as f:
    saved = yaml.safe_load(f)
if profile_name:
    saved_gpus = ((saved.get("profiles") or {}).get(profile_name) or {}).get("gpus") or {}
else:
    saved_gpus = saved.get("gpus") or {}
for gpu_id in gpu_ids:
    gpu = saved_gpus.get(gpu_id) or {}
    if gpu.get("gpu_clock_offsets") != {0: core_off} or gpu.get("mem_clock_offsets") != {0: mem_off}:
        sys.exit(f"{path}: wrote the offsets but could not read them back")

print(f"core {core_off:+d} MHz, VRAM {mem_off:+d} MHz for {', '.join(gpu_ids)} in {where}")
PY
)" || rc=$?

  if (( rc == 0 )); then
    echo -e "${C_GREEN}LACT: ${out}${C_RESET}"
    run_root systemctl restart lactd.service 2>/dev/null || true
    sleep 1
    if ! unit_active lactd.service; then
      echo -e "${C_YELLOW}lactd is not running after the config change:${C_RESET}"
      run_root journalctl -u lactd.service -n 5 --no-pager 2>/dev/null | sed 's/^/  /' || true
    fi
  else
    echo -e "${C_YELLOW}Could not auto-edit ${cfg}; configure in LACT GUI.${C_RESET}"
    [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/  /'
    return 1
  fi
}
revert_lact_overclock() {
  [[ "$HAS_AMD" == true ]] && remove_kernel_param "amdgpu.ppfeaturemask=0xffffffff"
  if [[ -f /etc/lact/config.yaml.bak.strata-setup ]]; then
    run_root mv -f /etc/lact/config.yaml.bak.strata-setup /etc/lact/config.yaml
    run_root systemctl restart lactd.service 2>/dev/null || true
  else
    run_root systemctl disable --now lactd.service 2>/dev/null || true
  fi
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

# 11b. AMD GPU DPM
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
    run_root systemctl daemon-reload
    unit_active strata.service && echo -e "${C_YELLOW}Restart strata.service for STRATA_SM70_TABLE=1 to take effect.${C_RESET}" || true
  fi
}
revert_nvidia_sm70_table() {
  run_root rm -f "$NVIDIA_SM70_MARKER" /etc/profile.d/strata-sm70.sh
  if [[ -f /etc/systemd/system/strata.service.d/20-sm70-table.conf ]]; then
    run_root rm -f /etc/systemd/system/strata.service.d/20-sm70-table.conf
    run_root rmdir /etc/systemd/system/strata.service.d 2>/dev/null || true
    [[ "$HAS_SYSTEMD" == true ]] && run_root systemctl daemon-reload 2>/dev/null || true
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

# 11c. Intel Arc / iGPU
applicable_intel_gpu_perf() {
  [[ "$HAS_INTEL_GPU" == true ]] || return 1
  compgen -G "/sys/class/drm/card*/gt_min_freq_mhz" >/dev/null 2>&1 || compgen -G "/sys/class/drm/card*/device/tile*/gt*/freq*/min_freq" >/dev/null 2>&1
}
title_intel_gpu_perf() { echo "Intel Arc / iGPU Maximum Base Frequency Lock (xe / i915 / SYCL)"; }
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

# 12. Sysctl & Scheduler
applicable_sysctl_tuning() { return 0; }
title_sysctl_tuning() { echo "Kernel VM, Sysctl, THP & Auto-Nice Tuning (ananicy-cpp / bpftune / sysctl)"; }
strata_swappiness_value() { if status_zram_swap; then echo 100; else echo 10; fi; }
write_swappiness_conf() {
  local v
  v="$(strata_swappiness_value)"
  printf 'vm.swappiness = %s\n' "$v" | run_root tee /etc/sysctl.d/99-strata-swappiness.conf >/dev/null
  run_root sysctl -w "vm.swappiness=${v}" >/dev/null 2>&1 || true
}
thp_supported() { [[ -e /sys/kernel/mm/transparent_hugepage/enabled ]]; }
status_sysctl_tuning() {
  [[ -f /etc/sysctl.d/99-strata-perf.conf ]] && grep -q max_map_count /etc/sysctl.d/99-strata-perf.conf 2>/dev/null || return 1
  [[ -f /etc/sysctl.d/99-strata-swappiness.conf ]] || return 1
  if thp_supported; then [[ -f /etc/tmpfiles.d/99-strata-thp.conf ]] || return 1; fi
  return 0
}
explain_sysctl_tuning() {
  echo -e "Impact:\n  Applies vm.vfs_cache_pressure=50, vm.dirty_ratio=10, vm.zone_reclaim_mode=0,\n  vm.max_map_count>=1048576 (large mmap'd models / CUDA / ROCm),\n  vm.swappiness (100 with zram swap, 10 without), Transparent Huge Pages\n  (enabled=always, defrag=defer+madvise; fewer TLB misses on big weights),\n  and enables ananicy-cpp / bpftune on Arch/CachyOS if available."
}
apply_sysctl_tuning() {
  local cur_map
  cur_map="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  [[ "$cur_map" =~ ^[0-9]+$ ]] || cur_map=0
  (( cur_map < 1048576 )) && cur_map=1048576
  run_root tee /etc/sysctl.d/99-strata-perf.conf >/dev/null <<EOF2
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.zone_reclaim_mode = 0
vm.max_map_count = ${cur_map}
EOF2
  write_swappiness_conf
  run_root sysctl --system >/dev/null 2>&1 || true
  if thp_supported; then
    local en=/sys/kernel/mm/transparent_hugepage/enabled df=/sys/kernel/mm/transparent_hugepage/defrag prev_en prev_df
    if [[ -f /etc/tmpfiles.d/99-strata-thp.conf ]]; then
      prev_en="$(sed -nE 's/^# prev_enabled=([^ ]+).*/\1/p' /etc/tmpfiles.d/99-strata-thp.conf)"
      prev_df="$(sed -nE 's/^# prev_enabled=[^ ]+ prev_defrag=([^ ]+).*/\1/p' /etc/tmpfiles.d/99-strata-thp.conf)"
    else
      prev_en="$(sed -E 's/.*\[([a-z+_]+)\].*/\1/' "$en" 2>/dev/null)"
      prev_df="$(sed -E 's/.*\[([a-z+_]+)\].*/\1/' "$df" 2>/dev/null)"
    fi
    local thp_df_val="defer+madvise"
    grep -qw "defer+madvise" "$df" 2>/dev/null || thp_df_val="madvise"
    run_root mkdir -p /etc/tmpfiles.d
    run_root tee /etc/tmpfiles.d/99-strata-thp.conf >/dev/null <<EOF2
# prev_enabled=${prev_en:-madvise} prev_defrag=${prev_df:-madvise}
w /sys/kernel/mm/transparent_hugepage/enabled - - - - always
w /sys/kernel/mm/transparent_hugepage/defrag - - - - ${thp_df_val}
EOF2
    echo always | run_root tee "$en" >/dev/null 2>&1 || true
    echo "$thp_df_val" | run_root tee "$df" >/dev/null 2>&1 || true
  fi
  if [[ "$DISTRO_FAMILY" == "arch" ]]; then
    local svc
    for svc in ananicy-cpp.service bpftune.service; do
      unit_exists "$svc" && run_root systemctl enable --now "$svc" 2>/dev/null || true
    done
  fi
}
revert_sysctl_tuning() {
  run_root rm -f /etc/sysctl.d/99-strata-perf.conf /etc/sysctl.d/99-strata-swappiness.conf
  run_root sysctl -w vm.swappiness=60 >/dev/null 2>&1 || true
  if [[ -f /etc/tmpfiles.d/99-strata-thp.conf ]]; then
    local prev_en prev_df
    prev_en="$(sed -nE 's/^# prev_enabled=([^ ]+).*/\1/p' /etc/tmpfiles.d/99-strata-thp.conf)"
    prev_df="$(sed -nE 's/^# prev_enabled=[^ ]+ prev_defrag=([^ ]+).*/\1/p' /etc/tmpfiles.d/99-strata-thp.conf)"
    [[ -n "$prev_en" ]] && echo "$prev_en" | run_root tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1
    [[ -n "$prev_df" ]] && echo "$prev_df" | run_root tee /sys/kernel/mm/transparent_hugepage/defrag >/dev/null 2>&1
    run_root rm -f /etc/tmpfiles.d/99-strata-thp.conf
  fi
  run_root sysctl --system >/dev/null 2>&1 || true
}

# 12b. zram Swap
applicable_zram_swap() {
  status_zram_swap && return 0
  case "$DISTRO_FAMILY" in
    arch)   pkg_available repo zram-generator ;;
    fedora) pkg_available repo zram-generator-defaults || pkg_available repo zram-generator ;;
    debian)
      pkg_available repo zram-tools && return 0
      pkg_available repo zram-config && return 0
      [[ "$IS_JETSON" == true ]] && { [[ -d /sys/module/zram ]] || modinfo zram >/dev/null 2>&1; }
      ;;
    suse)   pkg_available repo zram-generator ;;
    *)      return 1 ;;
  esac
}
title_zram_swap() { echo "Compressed zram Swap (zstd/lz4) for Large Model Safety"; }
status_zram_swap() { swapon --show=NAME --noheadings 2>/dev/null | grep -E "zram" >/dev/null; }
explain_zram_swap() { echo -e "Impact:\n  Enables compressed RAM swap (/dev/zram0) to prevent OOM crashes on\n  large models without slow storage swap thrashing, and raises vm.swappiness to 100\n  (zram swap is faster than evicting page cache)."; }
apply_zram_swap() {
  status_zram_swap && { echo -e "${C_GREEN}zram swap is already active.${C_RESET}"; return 0; }
  case "$DISTRO_FAMILY" in
    arch|suse)
      prompt_install_deps repo zram-generator || return 0
      run_root tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
zram-size = ram
compression-algorithm = zstd
swap-priority = 100
EOF
      run_root systemctl daemon-reload
      run_root systemctl start systemd-zram-setup@zram0.service
      ;;
    fedora)
      prompt_install_deps repo zram-generator-defaults || return 0
      run_root systemctl daemon-reload
      run_root systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
      ;;
    debian)
      if pkg_available repo zram-tools; then
        prompt_install_deps repo zram-tools || return 0
        run_root cp -n /etc/default/zramswap /etc/default/zramswap.bak.strata-setup 2>/dev/null || true
        run_root tee /etc/default/zramswap >/dev/null <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
        run_root systemctl enable --now zramswap.service
      elif pkg_available repo zram-config; then
        prompt_install_deps repo zram-config || return 0
        run_root systemctl enable --now zram-config.service 2>/dev/null || true
      else
        local zram_kb
        zram_kb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 4194304) / 2 ))
        install_service strata-zram.service <<EOF
[Unit]
Description=Strata Compressed zram Swap
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'modprobe zram num_devices=1; algo=lzo; for a in zstd lz4 lzo; do grep -qw "\$a" /sys/block/zram0/comp_algorithm 2>/dev/null && { algo=\$a; break; }; done; echo "\$algo" > /sys/block/zram0/comp_algorithm 2>/dev/null || true; echo ${zram_kb}K > /sys/block/zram0/disksize && mkswap /dev/zram0 && swapon -p 100 /dev/zram0'
ExecStop=/bin/sh -c 'swapoff /dev/zram0 2>/dev/null || true; echo 1 > /sys/block/zram0/reset 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
      fi
      ;;
  esac
  write_swappiness_conf
}
revert_zram_swap() {
  case "$DISTRO_FAMILY" in
    arch|fedora|suse)
      if [[ -f /etc/systemd/zram-generator.conf ]]; then
        run_root systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
        run_root rm -f /etc/systemd/zram-generator.conf
        run_root systemctl daemon-reload
      else
        echo -e "${C_YELLOW}zram was configured by your OS by default; leaving OS zram intact.${C_RESET}"
      fi
      ;;
    debian)
      if service_installed strata-zram.service; then
        remove_service strata-zram.service
      elif unit_exists zramswap.service; then
        run_root systemctl disable --now zramswap.service 2>/dev/null || true
        [[ -f /etc/default/zramswap.bak.strata-setup ]] && run_root mv -f /etc/default/zramswap.bak.strata-setup /etc/default/zramswap
      elif unit_exists zram-config.service; then
        run_root systemctl disable --now zram-config.service 2>/dev/null || true
      else
        echo -e "${C_YELLOW}zram was configured by your OS by default; leaving OS zram intact.${C_RESET}"
      fi
      ;;
  esac
  [[ -f /etc/sysctl.d/99-strata-swappiness.conf ]] && write_swappiness_conf
}

# 12c. IRQ Balance
applicable_irq_balance() { [[ "$(nproc 2>/dev/null || echo 1)" -gt 1 ]] && { command -v irqbalance >/dev/null 2>&1 || pkg_available repo irqbalance; }; }
title_irq_balance() { echo "Hardware IRQ Load Balancing (irqbalance)"; }
status_irq_balance() { unit_enabled irqbalance.service && unit_active irqbalance.service; }
explain_irq_balance() { echo -e "Impact:\n  Distributes NVMe, NIC, and PCIe/GPU interrupts across CPU cores."; }
apply_irq_balance() {
  command -v irqbalance >/dev/null 2>&1 || prompt_install_deps repo irqbalance || return 0
  run_root systemctl enable --now irqbalance.service
}
revert_irq_balance() { run_root systemctl disable --now irqbalance.service 2>/dev/null || true; }

# 12d. NUMA Balancing
numa_node_count() { echo "${NUMA_NODES:-1}"; }
cpu_socket_count() { echo "${CPU_SOCKETS:-1}"; }
applicable_numa_balancing() {
  [[ -e /proc/sys/kernel/numa_balancing ]] || return 1
  (( $(numa_node_count) > 1 || $(cpu_socket_count) > 1 ))
}
title_numa_balancing() { echo "Disable Automatic NUMA Balancing ($(cpu_socket_count) socket(s), $(numa_node_count) NUMA nodes, page-migration hygiene)"; }
status_numa_balancing() {
  [[ -f /etc/sysctl.d/99-strata-numa.conf ]] && [[ "$(cat /proc/sys/kernel/numa_balancing 2>/dev/null)" == "0" ]]
}
explain_numa_balancing() {
  echo -e "Impact:\n  Sets kernel.numa_balancing=0 (persistent via /etc/sysctl.d/99-strata-numa.conf).\n  Stops the kernel from periodically unmapping pages to migrate them between NUMA\n  nodes (jitter/stall hygiene for large model memory; no measured prefill/decode\n  speedup once allocations are resident)."
}
apply_numa_balancing() {
  run_root tee /etc/sysctl.d/99-strata-numa.conf >/dev/null <<'EOF2'
kernel.numa_balancing = 0
EOF2
  run_root sysctl -w kernel.numa_balancing=0 >/dev/null 2>&1 || true
  run_root sysctl --system >/dev/null 2>&1 || true
}
revert_numa_balancing() {
  run_root rm -f /etc/sysctl.d/99-strata-numa.conf
  run_root sysctl -w kernel.numa_balancing=1 >/dev/null 2>&1 || true
  run_root sysctl --system >/dev/null 2>&1 || true
}

# 12e. Headless Boot Target
applicable_headless_target() {
  [[ "$HAS_SYSTEMD" == true ]] || return 1
  [[ -f "$HEADLESS_MARKER" ]] && return 0
  [[ "$IS_LAPTOP" == true ]] && return 1
  [[ "$(systemctl get-default 2>/dev/null)" == "graphical.target" ]] || return 1
  unit_enabled display-manager.service || unit_active display-manager.service
}
title_headless_target() { echo "Headless Boot Target (stop desktop / display manager, free VRAM & RAM)"; }
status_headless_target() { [[ "$(systemctl get-default 2>/dev/null)" == "multi-user.target" ]]; }
explain_headless_target() {
  cat <<'EOF'
Impact:
  Sets the default boot target to multi-user.target so the display manager and
  desktop session no longer start. This frees several hundred MB of VRAM and RAM
  for models. Over SSH the desktop is stopped immediately; from a local desktop
  session the change applies on next boot (reboot prompt). Revert restores the
  previous default target. Only offered on non-laptop machines using a desktop.
EOF
}
apply_headless_target() {
  local prev
  prev="$(systemctl get-default 2>/dev/null)"
  if [[ -n "$prev" && "$prev" != "multi-user.target" ]]; then
    echo "$prev" | run_root tee "$HEADLESS_MARKER" >/dev/null
  fi
  run_root systemctl set-default multi-user.target
  local remote=false local_gui=false
  [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]] && remote=true
  if [[ -n "${XDG_SESSION_ID:-}" ]] && [[ "$(loginctl show-session "$XDG_SESSION_ID" -p Remote --value 2>/dev/null)" == "yes" ]]; then
    remote=true
  fi
  if [[ "$remote" == false ]]; then
    if [[ "${XDG_SESSION_TYPE:-}" =~ ^(x11|wayland)$ || -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
      local_gui=true
    elif [[ "$(tty 2>/dev/null || true)" == /dev/pts/* ]] && unit_active display-manager.service; then
      local_gui=true
    fi
  fi
  if [[ "$local_gui" == true ]]; then
    echo -e "${C_YELLOW}Running inside a local desktop session; the desktop will stop on next boot.${C_RESET}"
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
  else
    run_root systemctl isolate multi-user.target || true
  fi
}
revert_headless_target() {
  local prev="graphical.target"
  [[ -f "$HEADLESS_MARKER" ]] && prev="$(cat "$HEADLESS_MARKER" 2>/dev/null)"
  [[ -n "$prev" ]] || prev="graphical.target"
  run_root systemctl set-default "$prev"
  run_root rm -f "$HEADLESS_MARKER"
  REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
  echo -e "${C_GREEN}Default target restored to ${prev} (applies on next boot).${C_RESET}"
}

# 12f. CPU C-State Limit
cstate_limit_service_installed() { service_installed strata-cstate-limit.service; }
applicable_cstate_limit() {
  cstate_limit_service_installed && return 0
  local f lat
  for f in /sys/devices/system/cpu/cpu0/cpuidle/state*/latency; do
    [[ -r "$f" ]] || continue
    lat="$(cat "$f" 2>/dev/null)"
    [[ "$lat" =~ ^[0-9]+$ ]] && (( lat > 10 )) && return 0
  done
  return 1
}
title_cstate_limit() { echo "CPU Deep C-State Limit (lowest wake-up latency, C1 only)"; }
note_cstate_limit() { echo -e "${C_YELLOW}[!]${C_RESET}"; }
status_cstate_limit() { cstate_limit_service_installed && unit_enabled strata-cstate-limit.service; }
explain_cstate_limit() {
  cat <<'EOF'
Impact:
  Disables CPU idle states with an exit latency above 10 us (deep C-states) on
  all cores via a systemd service, so cores wake instantly when tokens/requests
  arrive (lower latency jitter for CPU-offloaded layers).
EOF
  echo -e "\n${C_YELLOW}[WARNING] Keeping cores out of deep sleep increases idle power consumption${C_RESET}"
  echo -e "${C_YELLOW}          and hardly provides sustained performance gains for GPU-bound inference.${C_RESET}"
}
apply_cstate_limit() {
  install_service strata-cstate-limit.service <<'EOF'
[Unit]
Description=Limit CPU Deep C-States for Strata Low-Latency Inference
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for s in /sys/devices/system/cpu/cpu*/cpuidle/state*; do [ -w "$s/disable" ] && [ "$(cat "$s/latency")" -gt 10 ] && echo 1 > "$s/disable"; done; true'
ExecStop=/bin/sh -c 'for s in /sys/devices/system/cpu/cpu*/cpuidle/state*; do [ -w "$s/disable" ] && echo 0 > "$s/disable"; done; true'

[Install]
WantedBy=multi-user.target
EOF
}
revert_cstate_limit() {
  remove_service strata-cstate-limit.service
  run_root sh -c 'for s in /sys/devices/system/cpu/cpu*/cpuidle/state*; do [ -w "$s/disable" ] && echo 0 > "$s/disable"; done; true' 2>/dev/null || true
}

# 12g. GPU Device Access Groups
gpu_missing_groups() {
  local g
  for g in render video; do
    getent group "$g" >/dev/null 2>&1 || continue
    id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$g" || echo "$g"
  done
}
applicable_gpu_groups() {
  [[ "$TARGET_USER" != "root" ]] || return 1
  compgen -G "/dev/dri/renderD*" >/dev/null 2>&1 || [[ -e /dev/kfd || -e /dev/nvhost-gpu ]] || return 1
  getent group render >/dev/null 2>&1 || getent group video >/dev/null 2>&1
}
title_gpu_groups() { echo "GPU Device Access Groups (render / video for ROCm, Intel Arc, Vulkan)"; }
status_gpu_groups() { [[ -z "$(gpu_missing_groups)" ]]; }
explain_gpu_groups() {
  cat <<'EOF'
Impact:
  Adds your user to the 'render' and 'video' groups (when missing) so ROCm/HIP,
  Intel SYCL/Level Zero and Vulkan can open /dev/dri/render* and /dev/kfd.
  Prevents 'GPU not found' / silent CPU fallback. Requires re-login to take effect.
EOF
}
apply_gpu_groups() {
  local g added=()
  for g in $(gpu_missing_groups); do
    run_root usermod -aG "$g" "$TARGET_USER" && added+=("$g")
  done
  if (( ${#added[@]} > 0 )); then
    printf '%s\n' "${added[@]}" | run_root tee -a "$GPU_GROUPS_MARKER" >/dev/null
    echo -e "${C_GREEN}Added ${TARGET_USER} to: ${added[*]} (log out and back in to apply).${C_RESET}"
  fi
}
revert_gpu_groups() {
  local g
  if [[ -f "$GPU_GROUPS_MARKER" ]]; then
    while IFS= read -r g; do
      [[ -n "$g" ]] && run_root gpasswd -d "$TARGET_USER" "$g" >/dev/null 2>&1 || true
    done < "$GPU_GROUPS_MARKER"
    run_root rm -f "$GPU_GROUPS_MARKER"
  else
    echo -e "${C_YELLOW}Group memberships were not added by this script; leaving them intact.${C_RESET}"
  fi
}

# 12h. NVIDIA Clock Lock
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

# 12j. AMD APU Unified Memory Limit
amd_apu_gtt_pages() {
  local kb reserve
  kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  reserve=$((4 * 1048576))
  (( kb / 8 > reserve )) && reserve=$((kb / 8))
  echo $(( (kb - reserve) / 4 ))
}
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
  add_kernel_param "ttm.pages_limit=${pages}"
  add_kernel_param "ttm.page_pool_size=${pages}"
}
revert_amd_apu_memory() {
  local n v
  for n in ttm.pages_limit ttm.page_pool_size; do
    v="$(kernel_param_value "$n" || true)"
    [[ -n "$v" ]] && remove_kernel_param "${n}=${v}"
  done
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
applicable_nvme_tuning() { compgen -G "/sys/block/nvme*n*" >/dev/null 2>&1; }
title_nvme_tuning() { echo "NVMe I/O Scheduler & Read-Ahead (faster model loading)"; }
status_nvme_tuning() { [[ -f /etc/udev/rules.d/60-strata-nvme.rules ]]; }
explain_nvme_tuning() {
  cat <<'EOF'
Impact:
  Installs a udev rule setting every NVMe disk to I/O scheduler 'none' with a
  4 MiB read-ahead (queue/read_ahead_kb=4096). Large sequential model reads and
  mmap page-ins load noticeably faster than with the 128 KiB default.
EOF
}
apply_nvme_tuning() {
  run_root tee /etc/udev/rules.d/60-strata-nvme.rules >/dev/null <<'EOF'
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]*n[0-9]*", ENV{DEVTYPE}=="disk", ATTR{queue/scheduler}="none", ATTR{queue/read_ahead_kb}="4096"
EOF
  run_root udevadm control --reload >/dev/null 2>&1 || true
  run_root sh -c 'for d in /sys/block/nvme*n*; do echo none > "$d/queue/scheduler" 2>/dev/null; echo 4096 > "$d/queue/read_ahead_kb" 2>/dev/null; done; true'
}
revert_nvme_tuning() {
  run_root rm -f /etc/udev/rules.d/60-strata-nvme.rules
  run_root udevadm control --reload >/dev/null 2>&1 || true
  run_root sh -c 'for d in /sys/block/nvme*n*; do echo 128 > "$d/queue/read_ahead_kb" 2>/dev/null; done; true'
}

# 12l. Network Serving Tuning
has_physical_nic_up() {
  local n
  for n in /sys/class/net/*; do
    [[ "$(basename "$n")" == "lo" ]] && continue
    [[ -e "$n/device" && "$(cat "$n/operstate" 2>/dev/null)" == "up" ]] && return 0
  done
  return 1
}
applicable_net_tuning() {
  [[ -f /etc/sysctl.d/99-strata-net.conf ]] && return 0
  [[ -e /proc/sys/net/core/somaxconn ]] && has_physical_nic_up
}
title_net_tuning() { echo "Network Serving Tuning (somaxconn, TCP Fast Open, BBR)"; }
status_net_tuning() { [[ -f /etc/sysctl.d/99-strata-net.conf ]]; }
explain_net_tuning() {
  cat <<'EOF'
Impact:
  Raises net.core.somaxconn (4096), enables TCP Fast Open, disables TCP slow-start
  after idle (keeps streaming token responses fast) and enables BBR congestion
  control with the fq qdisc when the kernel supports it. Helps when Strata serves
  many concurrent API clients over the network.
EOF
}
apply_net_tuning() {
  local opts=("net.core.somaxconn=4096" "net.ipv4.tcp_fastopen=3" "net.ipv4.tcp_slow_start_after_idle=0")
  run_root modprobe tcp_bbr >/dev/null 2>&1 || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    opts+=("net.core.default_qdisc=fq" "net.ipv4.tcp_congestion_control=bbr")
    echo "tcp_bbr" | run_root tee /etc/modules-load.d/strata-bbr.conf >/dev/null
  fi
  write_sysctl_with_prev /etc/sysctl.d/99-strata-net.conf "${opts[@]}"
}
revert_net_tuning() {
  restore_sysctl_prev /etc/sysctl.d/99-strata-net.conf
  run_root rm -f /etc/modules-load.d/strata-bbr.conf
}

# 12m. Ryzen APU Power Limits (ryzenadj)
is_amd_mobile_apu_cpu() {
  grep -qi "AuthenticAMD" /proc/cpuinfo 2>/dev/null || return 1
  grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | grep -qiE 'Ryzen AI|Radeon|Ryzen.*[0-9]{3,4}(U|HS|H|HX|G|GE)\b'
}
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
  run_root systemctl enable --now thermald.service
}
revert_intel_thermald() { run_root systemctl disable --now thermald.service 2>/dev/null || true; }

# 12p. tuned profile
applicable_tuned_profile() {
  [[ -f "$TUNED_MARKER" ]] && return 0
  unit_active power-profiles-daemon.service && return 1
  unit_active tlp.service && return 1
  unit_exists tuned.service || command -v tuned-adm >/dev/null 2>&1 || pkg_available repo tuned
}
tuned_target_profile() {
  if command -v tuned-adm >/dev/null 2>&1 && tuned-adm list 2>/dev/null | grep -E "accelerator-performance" >/dev/null; then
    echo accelerator-performance
  else
    echo throughput-performance
  fi
}
title_tuned_profile() { echo "tuned Profile (throughput-performance / accelerator-performance)"; }
note_tuned_profile() { echo -e "${C_YELLOW}[!]${C_RESET}"; }
status_tuned_profile() {
  unit_active tuned.service || return 1
  tuned-adm active 2>/dev/null | grep -E "throughput-performance|accelerator-performance" >/dev/null
}
explain_tuned_profile() {
  cat <<'EOF'
Impact:
  Installs/enables tuned and activates the 'throughput-performance' (or
  'accelerator-performance' when available) profile: performance governor,
  energy-performance bias, and larger dirty/readahead/scheduler settings.
  Not offered when power-profiles-daemon or TLP manage power.
EOF
  echo -e "\n${C_YELLOW}[WARNING] These profiles keep the CPU at high clocks and raise idle power${C_RESET}"
  echo -e "${C_YELLOW}          while adding little over the other tuning steps for GPU-bound inference.${C_RESET}"
}
apply_tuned_profile() {
  command -v tuned-adm >/dev/null 2>&1 || prompt_install_deps repo tuned || return 0
  run_root systemctl enable --now tuned.service || return 1
  sleep 1
  if [[ ! -f "$TUNED_MARKER" ]]; then
    tuned-adm active 2>/dev/null | sed -nE 's/^Current active profile: *//p' | run_root tee "$TUNED_MARKER" >/dev/null
  fi
  run_root tuned-adm profile "$(tuned_target_profile)"
}
revert_tuned_profile() {
  local prev=""
  [[ -f "$TUNED_MARKER" ]] && prev="$(cat "$TUNED_MARKER" 2>/dev/null)"
  if [[ -n "$prev" ]]; then run_root tuned-adm profile "$prev"; else run_root tuned-adm off 2>/dev/null || true; fi
  run_root rm -f "$TUNED_MARKER"
}

# 12q. IOMMU passthrough
gpu_pci_count() { echo "${DISCRETE_GPU_COUNT:-0}"; }
applicable_iommu_pt() {
  has_kernel_param "iommu=pt" && return 0
  [[ -n "$(ls -A "${STRATA_IOMMU_GROUPS_DIR:-/sys/kernel/iommu_groups}" 2>/dev/null)" ]] && (( $(gpu_pci_count) >= 2 ))
}
title_iommu_pt() { echo "IOMMU Passthrough Mode (iommu=pt, lower multi-GPU DMA overhead)"; }
status_iommu_pt() { has_kernel_param "iommu=pt" || has_kernel_param "iommu.passthrough=1"; }
explain_iommu_pt() { echo -e "Impact:\n  Adds 'iommu=pt' to the kernel command line so host devices skip IOMMU address\n  translation (lower DMA overhead for multi-GPU transfers and fast NICs). VFIO\n  device passthrough keeps working. Requires a reboot."; }
apply_iommu_pt() { add_kernel_param "iommu=pt"; }
revert_iommu_pt() { remove_kernel_param "iommu=pt"; remove_kernel_param "iommu.passthrough=1"; }

# 12q2. Multi-GPU PCIe ACS Disable
applicable_pcie_acs_disable() {
  (( $(gpu_pci_count) >= 2 )) && [[ "$HAS_FULL_GPU_INTERCONNECT" == false ]] && command -v setpci >/dev/null 2>&1 &&
    { service_installed strata-pcie-acs-disable.service || [[ "$PCIE_ACS_CHECKED" == false || "$PCIE_ACS_ENABLED" == true ]]; }
}
title_pcie_acs_disable() { echo "Multi-GPU PCIe ACS Disable (setpci, direct GPU-to-GPU P2P)"; }
note_pcie_acs_disable() { echo -e "${C_MAGENTA}[EXP]${C_RESET}"; }
status_pcie_acs_disable() { service_installed strata-pcie-acs-disable.service && unit_enabled strata-pcie-acs-disable.service; }
explain_pcie_acs_disable() {
  cat <<'EOF'
Impact:
  Clears PCIe Access Control Services (ECAP_ACS+0x6.w=0000) via setpci at boot
  on PCIe bridges/switches when GPUs lack NVLink or XGMI. Allows direct
  peer-to-peer GPU transfers across PCIe switches instead of detouring through
  the CPU root complex (boosts multi-GPU tensor parallelism bandwidth).
EOF
  echo -e "\n${C_MAGENTA}[EXPERIMENTAL] Disabling ACS removes PCIe isolation between devices.${C_RESET}"
  echo -e "${C_YELLOW}[WARNING] Bare-metal single-tenant hosts only — DO NOT enable if you use${C_RESET}"
  echo -e "${C_YELLOW}          VFIO VM passthrough or untrusted multi-tenant VMs.${C_RESET}"
}
apply_pcie_acs_disable() {
  local setpci_bin lspci_bin
  setpci_bin="$(command -v setpci)" || return 1
  lspci_bin="$(command -v lspci)" || return 1
  run_root mkdir -p /usr/local/sbin
  run_root tee /usr/local/sbin/strata-disable-acs.sh >/dev/null <<EOF
#!/bin/sh
bdfs="\$("${lspci_bin}" -d "*:*:0604" 2>/dev/null | awk '{print \$1}')"
[ -n "\$bdfs" ] || bdfs="\$("${lspci_bin}" -d "*:*:*" 2>/dev/null | awk '{print \$1}')"
for bdf in \$bdfs; do
  "${setpci_bin}" -s "\$bdf" ECAP_ACS+0x6.w >/dev/null 2>&1 || continue
  "${setpci_bin}" -s "\$bdf" ECAP_ACS+0x6.w=0000 >/dev/null 2>&1 || true
done
EOF
  run_root chmod 0755 /usr/local/sbin/strata-disable-acs.sh
  install_service strata-pcie-acs-disable.service <<'EOF'
[Unit]
Description=Disable PCIe ACS for Multi-GPU P2P (Strata)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/strata-disable-acs.sh

[Install]
WantedBy=multi-user.target
EOF
  detect_gpu_topology
}
revert_pcie_acs_disable() {
  remove_service strata-pcie-acs-disable.service
  run_root rm -f /usr/local/sbin/strata-disable-acs.sh
  REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
  echo -e "${C_YELLOW}Removed PCIe ACS disable service; reboot to restore BIOS default ACS settings.${C_RESET}"
}

# 12q3. AMD Instinct Compute/Memory Partition Mode
amd_instinct_partition_supported() {
  [[ "$HAS_AMD" == true && "$HAS_AMD_INSTINCT" == true ]] || return 1
  local drm_dir="${STRATA_DRM_DIR:-/sys/class/drm}"
  compgen -G "${drm_dir}/card*/device/current_compute_partition" >/dev/null 2>&1 && return 0
  command -v amd-smi >/dev/null 2>&1 && amd-smi partition --current >/dev/null 2>&1 && return 0
  return 1
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
applicable_numactl_interleave() {
  [[ "$HAS_SYSTEMD" == true ]] || return 1
  [[ -z "$STRATA_BIN" && -n "$STRATA_DOCKER_CONTAINER" ]] && return 1
  (( $(numa_node_count) > 1 )) || return 1
  [[ -f "$NUMACTL_MARKER" ]] || command -v numactl >/dev/null 2>&1 || pkg_available repo numactl
}
title_numactl_interleave() { echo "NUMA Memory Interleaving for Strata (numactl --interleave=all)"; }
status_numactl_interleave() { [[ -f "$NUMACTL_MARKER" ]] && command -v numactl >/dev/null 2>&1; }
explain_numactl_interleave() {
  cat <<'EOF'
Impact:
  Installs numactl and starts native Strata (strata.service) under
  'numactl --interleave=all', spreading CPU-resident model weights across all
  NUMA nodes so memory bandwidth from every socket is used (primarily benefits
  multi-socket CPU/MoE-offload inference; restart strata.service after applying).
EOF
}
apply_numactl_interleave() {
  command -v numactl >/dev/null 2>&1 || prompt_install_deps repo numactl || return 0
  echo "enabled" | run_root tee "$NUMACTL_MARKER" >/dev/null
  if [[ -f /etc/systemd/system/strata.service ]] && ! grep -q numactl /etc/systemd/system/strata.service; then
    run_root sed -i "s|^ExecStart=|ExecStart=$(command -v numactl) --interleave=all |" /etc/systemd/system/strata.service
    run_root systemctl daemon-reload
    echo -e "${C_YELLOW}Restart strata.service for the interleave policy to take effect.${C_RESET}"
  fi
}
revert_numactl_interleave() {
  run_root rm -f "$NUMACTL_MARKER"
  if [[ -f /etc/systemd/system/strata.service ]]; then
    run_root sed -i "s|^ExecStart=[^ ]*/numactl --interleave=all |ExecStart=|" /etc/systemd/system/strata.service
    run_root systemctl daemon-reload
  fi
}

# 12u. 1 GiB hugepages
applicable_hugepages_1g() {
  [[ -n "$(kernel_param_value hugepages || true)" ]] && return 0
  grep -qw pdpe1gb /proc/cpuinfo 2>/dev/null || return 1
  (( ${RAM_GB:-0} >= 64 )) && (( $(numa_node_count) > 1 ))
}
title_hugepages_1g() { echo "Reserve 1 GiB Hugepages ($(( RAM_GB / 4 )) GiB, multi-socket CPU inference)"; }
note_hugepages_1g() { echo -e "${C_BLUE}[OPT]${C_RESET}"; }
status_hugepages_1g() { [[ -n "$(kernel_param_value hugepages || true)" ]]; }
explain_hugepages_1g() {
  cat <<EOF
Impact:
  Reserves $(( RAM_GB / 4 )) GiB of 1 GiB hugepages at boot (default_hugepagesz=1G
  hugepagesz=1G hugepages=$(( RAM_GB / 4 ))) for hugetlb-aware CPU inference. Requires a reboot.
EOF
  echo -e "\n${C_YELLOW}[WARNING] The reserved memory is permanently unavailable to the rest of the system${C_RESET}"
  echo -e "${C_YELLOW}          and only helps workloads that explicitly use hugetlbfs.${C_RESET}"
}
apply_hugepages_1g() {
  add_kernel_param "default_hugepagesz=1G"
  add_kernel_param "hugepagesz=1G"
  add_kernel_param "hugepages=$(( RAM_GB / 4 ))"
}
revert_hugepages_1g() {
  local n v
  for n in default_hugepagesz hugepagesz hugepages; do
    v="$(kernel_param_value "$n" || true)"
    [[ -n "$v" ]] && remove_kernel_param "${n}=${v}"
  done
}

# 12v. sched_ext scheduler
scx_unit() {
  local u
  for u in scx.service scx_loader.service strata-scx.service; do
    if unit_exists "$u" || systemctl cat "$u" >/dev/null 2>&1; then
      echo "$u"; return 0
    fi
  done
  return 1
}
applicable_scx_scheduler() {
  [[ -d /sys/kernel/sched_ext ]] || return 1
  scx_unit >/dev/null 2>&1 || command -v scx_bpfland >/dev/null 2>&1 || pkg_available repo scx-scheds
}
title_scx_scheduler() { echo "sched_ext BPF CPU Scheduler (scx, lower scheduling latency)"; }
status_scx_scheduler() { [[ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" == "enabled" ]]; }
explain_scx_scheduler() { echo -e "Impact:\n  Installs scx-scheds (if needed) and enables its service so a sched_ext BPF\n  scheduler (default: scx_bpfland) replaces the kernel CPU scheduler, improving\n  responsiveness of the API/server threads when CPU cores are saturated."; }
apply_scx_scheduler() {
  if ! scx_unit >/dev/null 2>&1; then
    local pkgs=()
    command -v scx_bpfland >/dev/null 2>&1 || pkgs+=(scx-scheds)
    pkg_available repo scx-tools && pkgs+=(scx-tools)
    if (( ${#pkgs[@]} > 0 )); then
      prompt_install_deps repo "${pkgs[@]}" || true
    fi
  fi
  local u
  u="$(scx_unit 2>/dev/null || true)"
  if [[ "$u" == "scx_loader.service" ]] && command -v scxctl >/dev/null 2>&1; then
    local scxctl_bin
    scxctl_bin="$(command -v scxctl)"
    run_root mkdir -p /etc/systemd/system/scx_loader.service.d
    run_root tee /etc/systemd/system/scx_loader.service.d/strata.conf >/dev/null <<EOF
[Service]
ExecStartPost=-${scxctl_bin} start -s bpfland
EOF
    run_root systemctl daemon-reload
    run_root systemctl enable --now "$u"
    if [[ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" != "enabled" ]]; then
      run_root "$scxctl_bin" start -s bpfland 2>/dev/null || run_root "$scxctl_bin" switch -s bpfland
    fi
  elif [[ -n "$u" && "$u" != "strata-scx.service" ]]; then
    run_root systemctl enable --now "$u"
  elif command -v scx_bpfland >/dev/null 2>&1; then
    local bpfland_bin
    bpfland_bin="$(command -v scx_bpfland)"
    install_service strata-scx.service <<EOF
[Unit]
Description=Strata sched_ext BPF CPU Scheduler (scx_bpfland)
After=multi-user.target

[Service]
Type=simple
ExecStart=${bpfland_bin}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  else
    echo -e "${C_YELLOW}No scx service or scx_bpfland binary found after installation.${C_RESET}"
    return 1
  fi
}
revert_scx_scheduler() {
  command -v scxctl >/dev/null 2>&1 && run_root scxctl stop 2>/dev/null || true
  if [[ -f /etc/systemd/system/scx_loader.service.d/strata.conf ]]; then
    run_root rm -f /etc/systemd/system/scx_loader.service.d/strata.conf
    run_root rmdir /etc/systemd/system/scx_loader.service.d 2>/dev/null || true
    run_root systemctl daemon-reload
  fi
  if service_installed strata-scx.service; then
    remove_service strata-scx.service
  fi
  local u
  u="$(scx_unit 2>/dev/null || true)"
  [[ -n "$u" ]] && run_root systemctl disable --now "$u" 2>/dev/null || true
}

# 12w. AMD X3D V-Cache Mode
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
  run_root systemctl daemon-reload
  unit_active strata.service && echo -e "${C_YELLOW}Restart strata.service for P-core affinity to take effect.${C_RESET}" || true
}
revert_intel_pcore_pinning() {
  run_root rm -f /etc/systemd/system/strata.service.d/10-pcore-affinity.conf
  run_root rmdir /etc/systemd/system/strata.service.d 2>/dev/null || true
  run_root systemctl daemon-reload
}

# 13. Strata Manager
applicable_strata_manager() { return 0; }
title_strata_manager() { echo "Strata: Install, Update, Launch & Systemd Service"; }
strata_service_installed() { service_installed strata.service; }

strata_components_engine_dir() {
  local base="${STRATA_COMPONENTS_DIR:-}"
  if [[ -z "$base" ]]; then
    local xdg=""
    [[ -n "${XDG_DATA_HOME:-}" && ( $EUID -ne 0 || "$TARGET_USER" == "root" ) ]] && xdg="$XDG_DATA_HOME"
    base="${xdg:-$TARGET_HOME/.local/share}/strata/components"
  fi
  echo "${base%/}/engine"
}

invalidate_local_hip_engine_cache() {
  LOCAL_HIP_INFO_CACHE_KEY=""
  LOCAL_HIP_INFO_CACHE_MATCH=""
  LOCAL_HIP_INFO_CACHE_ANY=""
}

_refresh_local_hip_engine_cache() {
  local eng_dir=""
  eng_dir="$(strata_components_engine_dir)"
  if [[ ! -d "$eng_dir" ]]; then
    invalidate_local_hip_engine_cache
    return 0
  fi

  local missing_key="" mtime_sig="" ckey=""
  if (( ${#AMD_MISSING_GFX_ARCHS[@]} > 0 )); then
    local IFS=','
    missing_key="${AMD_MISSING_GFX_ARCHS[*]}"
  fi
  mtime_sig="$(stat -c '%n:%Y:%s' "$eng_dir" "$eng_dir"/*/engine-component.json 2>/dev/null || true)"
  ckey="${eng_dir}|${missing_key}|${mtime_sig}"
  [[ "$ckey" == "$LOCAL_HIP_INFO_CACHE_KEY" ]] && return 0

  LOCAL_HIP_INFO_CACHE_MATCH=""
  LOCAL_HIP_INFO_CACHE_ANY=""
  if command -v python3 >/dev/null 2>&1; then
    local py_out="" line=""
    py_out="$(python3 - "$eng_dir" "${AMD_MISSING_GFX_ARCHS[@]+"${AMD_MISSING_GFX_ARCHS[@]}"}" <<'PY' 2>/dev/null || true
import json, os, re, sys

eng_dir = sys.argv[1]
missing = set(sys.argv[2:])

def ver_key(v):
    return tuple(int(x) for x in re.findall(r"\d+", str(v or "")))

best_match = None
best_any = None
try:
    entries = os.listdir(eng_dir)
except OSError:
    sys.exit(0)

for name in entries:
    pkg_dir = os.path.join(eng_dir, name)
    manifest = os.path.join(pkg_dir, "engine-component.json")
    if not os.path.isfile(manifest):
        continue
    try:
        with open(manifest, encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        continue
    if d.get("backend") != "hip":
        continue
    entry = d.get("entrypoint") or "strata"
    if not os.path.isfile(os.path.join(pkg_dir, entry)):
        continue
    archs = [str(a) for a in (d.get("archs") or []) if a]
    arch_set = set(archs)
    is_local = (bool(d.get("local")) or (d.get("signature") is None)
                or str(d.get("variant") or "").startswith("local") or "-local" in name)
    covers_all = 1 if (not missing or missing <= arch_set) else 0
    ver = str(d.get("version") or "0")
    cand = (covers_all, ver_key(ver), name, ver, ",".join(archs))
    if missing and (arch_set & missing):
        if best_match is None or cand[:3] > best_match[:3]:
            best_match = cand
        if best_any is None or cand[:3] > best_any[:3]:
            best_any = cand
    elif is_local:
        if best_any is None or cand[:3] > best_any[:3]:
            best_any = cand

if best_match is not None:
    print(f"MATCH:{best_match[2]}|{best_match[3]}|{best_match[4]}|{best_match[0]}")
if best_any is not None:
    print(f"ANY:{best_any[2]}|{best_any[3]}|{best_any[4]}|{best_any[0]}")
PY
)"
    while IFS= read -r line; do
      case "$line" in
        MATCH:*) LOCAL_HIP_INFO_CACHE_MATCH="${line#MATCH:}" ;;
        ANY:*)   LOCAL_HIP_INFO_CACHE_ANY="${line#ANY:}" ;;
      esac
    done <<< "$py_out"
  fi
  LOCAL_HIP_INFO_CACHE_KEY="$ckey"
  return 0
}

strata_local_hip_engine_info() {
  local any_local=false
  [[ "${1:-}" == "--any-local" ]] && any_local=true
  if [[ "$any_local" == false ]] && (( ${#AMD_MISSING_GFX_ARCHS[@]} == 0 )); then
    return 0
  fi
  _refresh_local_hip_engine_cache
  if [[ "$any_local" == true ]]; then
    [[ -n "$LOCAL_HIP_INFO_CACHE_ANY" ]] && printf '%s\n' "$LOCAL_HIP_INFO_CACHE_ANY"
  else
    [[ -n "$LOCAL_HIP_INFO_CACHE_MATCH" ]] && printf '%s\n' "$LOCAL_HIP_INFO_CACHE_MATCH"
  fi
  return 0
}

_amd_gfx_covered_by_local_hip() {
  local gfx="$1" arch_csv=""
  _refresh_local_hip_engine_cache
  [[ -n "$LOCAL_HIP_INFO_CACHE_ANY" ]] || return 1
  IFS='|' read -r _ _ arch_csv _ <<< "$LOCAL_HIP_INFO_CACHE_ANY"
  [[ ",${arch_csv}," == *",${gfx},"* ]]
}

status_strata_build_hip() {
  (( ${#AMD_MISSING_GFX_ARCHS[@]} > 0 )) || return 1
  _refresh_local_hip_engine_cache
  [[ -n "$LOCAL_HIP_INFO_CACHE_MATCH" && "${LOCAL_HIP_INFO_CACHE_MATCH##*|}" == "1" ]]
}

check_strata_update_sync() {
  [[ -n "$STRATA_BIN" ]] || return 1
  local json_out parsed=""
  json_out="$(run_as_user_exec "$STRATA_BIN" update --check --json 2>/dev/null || true)"
  if [[ -n "$json_out" ]] && command -v python3 >/dev/null 2>&1; then
    parsed="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(1)
updates = []
for key in ("engine", "control"):
    comp = d.get(key)
    if not isinstance(comp, dict):
        continue
    inst = comp.get("installed")
    off = comp.get("offered")
    inst_v = inst.get("version") if isinstance(inst, dict) else inst
    off_v = off.get("version") if isinstance(off, dict) else off
    st = comp.get("status", "")
    if inst_v and off_v and (st not in ("", "current", "unknown-installed") or inst_v != off_v):
        updates.append(f"{key} {inst_v} -> {off_v}")
if updates:
    print("1|" + ", ".join(updates))
else:
    print("0|")
' <<< "$json_out" 2>/dev/null || true)"
  fi

  if [[ -z "$parsed" ]]; then
    local txt_out
    txt_out="$(run_as_user_exec "$STRATA_BIN" update --check 2>/dev/null || true)"
    if grep -qiE "update available|newer|out of date" <<< "$txt_out"; then
      parsed="1|new version available"
    else
      parsed="0|"
    fi
  fi

  if [[ -n "$STRATA_UPDATE_CACHE_FILE" ]]; then
    printf "%s\n" "$parsed" > "${STRATA_UPDATE_CACHE_FILE}.tmp" 2>/dev/null && mv -f "${STRATA_UPDATE_CACHE_FILE}.tmp" "$STRATA_UPDATE_CACHE_FILE" 2>/dev/null || true
  fi

  if [[ "$parsed" == 1\|* ]]; then
    STRATA_UPDATE_AVAILABLE=true
    STRATA_UPDATE_SUMMARY="${parsed#1|}"
    return 0
  else
    STRATA_UPDATE_AVAILABLE=false
    STRATA_UPDATE_SUMMARY=""
    return 1
  fi
}

load_strata_update_state() {
  [[ -n "$STRATA_UPDATE_CACHE_FILE" && -r "$STRATA_UPDATE_CACHE_FILE" ]] || return 0
  local line
  line="$(<"$STRATA_UPDATE_CACHE_FILE")"
  if [[ "$line" == 1\|* ]]; then
    STRATA_UPDATE_AVAILABLE=true
    STRATA_UPDATE_SUMMARY="${line#1|}"
  else
    STRATA_UPDATE_AVAILABLE=false
    STRATA_UPDATE_SUMMARY=""
  fi
}

stop_strata_update_poller() {
  if [[ -n "$STRATA_POLLER_PID" ]]; then
    kill "$STRATA_POLLER_PID" 2>/dev/null || true
    wait "$STRATA_POLLER_PID" 2>/dev/null || true
    STRATA_POLLER_PID=""
  fi
  [[ -n "$STRATA_UPDATE_CACHE_FILE" ]] && rm -f "$STRATA_UPDATE_CACHE_FILE" "${STRATA_UPDATE_CACHE_FILE}.tmp" 2>/dev/null || true
  STRATA_UPDATE_CACHE_FILE=""
}

start_strata_update_poller() {
  [[ -n "$STRATA_BIN" && -z "$STRATA_POLLER_PID" ]] || return 0
  [[ -n "$STRATA_UPDATE_CACHE_FILE" ]] || STRATA_UPDATE_CACHE_FILE="$(mktemp /tmp/strata-update-check.XXXXXX 2>/dev/null || echo "")"
  [[ -n "$STRATA_UPDATE_CACHE_FILE" ]] || return 0
  (
    trap 'kill $(jobs -p) 2>/dev/null || true; exit 0' TERM INT
    while true; do
      check_strata_update_sync >/dev/null 2>&1 || true
      sleep 60 &
      wait $! 2>/dev/null || exit 0
    done
  ) &
  STRATA_POLLER_PID=$!
}

strata_update_available() {
  check_strata_update_sync
}

wait_for_strata_model_live() {
  local max_wait="${1:-120}" elapsed=0 json_out ready_profile=""
  echo -e "${C_DIM}Waiting for Strata model to become ready...${C_RESET}"
  while (( elapsed < max_wait )); do
    if ! unit_active strata.service; then
      echo -e "${C_RED}strata.service is not active (check 'journalctl -u strata -n 50').${C_RESET}"
      return 1
    fi
    json_out="$(run_as_user_exec "$STRATA_BIN" update --check --json 2>/dev/null || true)"
    if [[ -n "$json_out" ]] && command -v python3 >/dev/null 2>&1; then
      ready_profile="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
for s in d.get("serving") or []:
    if isinstance(s, dict) and s.get("state") == "ready":
        print(s.get("profile") or "model")
        break
' <<< "$json_out" 2>/dev/null || true)"
      if [[ -n "$ready_profile" ]]; then
        echo -e "${C_BGREEN}[LIVE] Strata service is active and model '${ready_profile}' is ready!${C_RESET}"
        return 0
      fi
    fi
    sleep 2
    ((elapsed += 2))
  done
  if unit_active strata.service; then
    echo -e "${C_GREEN}strata.service is active (model readiness not reported via JSON within ${max_wait}s).${C_RESET}"
    return 0
  fi
  return 1
}

wait_for_strata_stopped() {
  local max_wait="${1:-60}" elapsed=0 svc_active=false
  echo -e "${C_DIM}Waiting for Strata to stop completely...${C_RESET}"
  while (( elapsed < max_wait )); do
    svc_active=false
    unit_active strata.service && svc_active=true
    refresh_strata_running
    if [[ "$svc_active" == false && -z "$STRATA_RUNNING_PRESET" ]]; then
      echo -e "${C_GREEN}Strata stopped.${C_RESET}"
      return 0
    fi
    sleep 1
    (( elapsed += 1 ))
  done
  echo -e "${C_RED}Timed out waiting for Strata to stop after ${max_wait}s.${C_RESET}"
  return 1
}

perform_strata_update() {
  refresh_strata_bin
  if [[ -z "$STRATA_BIN" ]]; then
    echo -e "${C_YELLOW}Strata is not installed.${C_RESET}"
    return 1
  fi

  local was_active=false was_launch_running=false
  unit_active strata.service && was_active=true
  if [[ "$was_active" == false ]]; then
    refresh_strata_running
    [[ -n "$STRATA_RUNNING_PRESET" ]] && was_launch_running=true
  fi

  echo -e "${C_BOLD}Strata Update${C_RESET}"
  [[ -n "$STRATA_UPDATE_SUMMARY" ]] && echo -e "Pending update: ${C_CYAN}${STRATA_UPDATE_SUMMARY}${C_RESET}"
  if [[ "$was_active" == true ]]; then
    echo -e "Service status: ${C_GREEN}active (will stop & restart)${C_RESET}\n"
  elif [[ "$was_launch_running" == true ]]; then
    echo -e "Strata status: ${C_GREEN}running (${STRATA_RUNNING_PRESET}; will stop before updating)${C_RESET}\n"
  else
    echo -e "Service status: ${C_DIM}inactive${C_RESET}\n"
  fi

  if ! confirm_yn "Install Strata update now? [Y/n]: " "Y"; then
    echo -e "${C_DIM}Update cancelled.${C_RESET}"
    return 0
  fi

  # Pause background update polling and wait for any in-flight 'strata update --check'
  # to release the component-folder lock before running 'strata update --yes'.
  stop_strata_update_poller

  if [[ "$was_active" == true ]]; then
    echo -e "\n${C_CYAN}Stopping strata.service before updating...${C_RESET}"
    service_ctl stop strata.service || true
    if ! wait_for_strata_stopped 60; then
      start_strata_update_poller
      return 1
    fi
  else
    refresh_strata_running
    if [[ "$was_launch_running" == true || -n "$STRATA_RUNNING_PRESET" ]]; then
      echo -e "\n${C_CYAN}Stopping Strata ('strata launch --stop') before updating...${C_RESET}"
      run_as_user_exec "$STRATA_BIN" launch --stop || true
      if ! wait_for_strata_stopped 60; then
        start_strata_update_poller
        return 1
      fi
    fi
  fi

  echo -e "\n${C_CYAN}Running 'strata update --yes'...${C_RESET}"
  local rc=0 attempt=0
  for (( attempt = 1; attempt <= 4; attempt++ )); do
    rc=0
    run_as_user_exec "$STRATA_BIN" update --yes || rc=$?
    if (( rc != 7 || attempt == 4 )); then
      break
    fi
    echo -e "${C_YELLOW}Strata update lock is busy (exit code 7); waiting 5s to retry (${attempt}/3)...${C_RESET}"
    sleep 5
  done

  refresh_strata_bin
  if (( rc == 0 )); then
    echo -e "\n${C_GREEN}Strata update completed successfully!${C_RESET}"
    echo -e "${C_DIM}Installed version: $(run_as_user_exec "$STRATA_BIN" --version 2>/dev/null || echo unknown)${C_RESET}"
    check_strata_update_sync >/dev/null 2>&1 || true
  else
    echo -e "\n${C_RED}Strata update failed (exit code ${rc}).${C_RESET}"
  fi

  if [[ "$was_active" == true ]]; then
    echo -e "\n${C_CYAN}Restarting strata.service...${C_RESET}"
    if service_ctl start strata.service; then
      wait_for_strata_model_live 120
    else
      echo -e "${C_RED}Failed to start strata.service$([[ "$HAS_SYSTEMD" == true ]] && echo " (check 'journalctl -u strata -n 50')").${C_RESET}"
    fi
  elif strata_service_installed; then
    echo ""
    if confirm_yn "strata.service is installed but was stopped. Start it now? [y/N]: " "N"; then
      if service_ctl start strata.service; then
        wait_for_strata_model_live 120
      else
        echo -e "${C_RED}Failed to start strata.service.${C_RESET}"
      fi
    fi
  fi

  start_strata_update_poller
}
format_strata_hw_warnings() {
  if (( RAM_GB > 0 && RAM_GB < 32 )); then
    echo -e "${C_YELLOW}[WARNING] System RAM is ${RAM_GB} GiB (< 32 GiB). Larger Strata models may not fit or may swap.${C_RESET}"
  fi
  if [[ "$IS_JETSON" == true ]]; then
    return 0
  elif [[ "$HAS_NVIDIA" == false && "$HAS_AMD" == false && "$HAS_INTEL_ARC" == false ]]; then
    echo -e "${C_YELLOW}[WARNING] No dedicated NVIDIA, AMD Radeon, or Intel Arc GPU detected (${GPU_SUMMARY}). Strata models may not run.${C_RESET}"
  elif [[ "$HAS_NVIDIA" == true && "$HAS_NVIDIA_UNIFIED_MEM" == false && "$NVIDIA_VRAM_MB" -gt 0 && "$NVIDIA_VRAM_MB" -lt 6144 ]]; then
    echo -e "${C_YELLOW}[WARNING] NVIDIA GPU VRAM is $((NVIDIA_VRAM_MB / 1024)) GiB (< 6 GiB). Larger Strata models may not fit in VRAM.${C_RESET}"
  fi
  if (( ${#AMD_MISSING_GFX_ARCHS[@]} > 0 )) && [[ "$HAS_NVIDIA" == false && "$HAS_AMD_PREBUILT_GFX" == false && "$HAS_INTEL_ARC" == false ]]; then
    if ! status_strata_build_hip; then
      echo -e "${C_YELLOW}[NOTE] AMD GPU (${AMD_MISSING_GFX_SUMMARY}) has no official prebuilt Strata Linux engine. Open [STRATA] -> Build Local HIP Engine to compile & register support from source.${C_RESET}"
    fi
  fi
  if [[ "$HAS_NVIDIA_DATACENTER" == true && ${#NVIDIA_GPU_INDICES[@]} -eq 0 ]]; then
    echo -e "${C_YELLOW}[WARNING] NVIDIA Tesla / datacenter GPU detected without active nvidia-smi. Ensure Above 4G Decoding is enabled in BIOS, use the proprietary nvidia driver (not nvidia-open) for pre-Turing GPUs, use the R580 legacy branch for Maxwell/Pascal/Volta (R590+ dropped M40/M60/P4/P40/P100/V100), or R470 legacy for Kepler (K80/K40).${C_RESET}"
  elif [[ "$HAS_NVIDIA_PASCAL" == true || "$HAS_NVIDIA_VOLTA_SM70" == true ]]; then
    local _arch_note="Pascal/Volta (sm_60/sm_61/sm_70) GPU detected: CUDA 13 dropped sm_60-sm_70, so use Strata CUDA 12 builds and R580-branch drivers"
    if [[ "$HAS_NVIDIA_VOLTA_SM70" == true ]] && [[ ! -f "$NVIDIA_SM70_MARKER" ]]; then
      _arch_note+=" (enable the V100 STRATA_SM70_TABLE step for faster decode)"
    fi
    echo -e "${C_YELLOW}[NOTE] ${_arch_note}.${C_RESET}"
  fi
}

status_strata_manager() { [[ -n "$STRATA_BIN" ]] && strata_service_installed; }
explain_strata_manager() {
  cat <<'EOF'
Impact:
  Installs Strata (Niko1221/Strata), checks for updates ('strata update'),
  runs 'strata launch', benchmarks running instances ('strata bench run'),
  and installs/uninstalls strata.service using a saved preset.
EOF
  local hw_warns=""
  hw_warns="$(format_strata_hw_warnings)"
  if [[ -n "$hw_warns" ]]; then
    echo ""
    printf "%s\n" "$hw_warns"
  fi
}
list_strata_presets() {
  local preset_dir="$TARGET_HOME/.config/strata/launch-presets" cli_out f
  if [[ -n "$STRATA_BIN" ]]; then
    cli_out="$(run_as_user_exec "$STRATA_BIN" launch --list-presets 2>/dev/null || true)"
    if [[ -n "$cli_out" ]]; then
      echo "$cli_out" | awk -F'  +' '{print $1}' | sed '/^$/d'
      return 0
    fi
  fi
  if [[ -d "$preset_dir" ]]; then
    for f in "$preset_dir"/*.json; do [[ -f "$f" ]] && basename "$f" .json; done
  fi
}
install_strata_service_fn() {
  local presets=() line i=1 choice selected_preset user_group
  while IFS= read -r line; do [[ -n "$line" ]] && presets+=("$line"); done < <(list_strata_presets)
  if [[ ${#presets[@]} -eq 0 ]]; then
    echo -e "${C_YELLOW}No saved Strata presets found. Run 'strata launch' first to save a preset.${C_RESET}"
    return 1
  fi
  echo -e "\n${C_BOLD}Select a Strata preset for systemd service:${C_RESET}"
  for line in "${presets[@]}"; do echo "  $i) $line"; ((i++)); done
  read -r -p "Preset number [1-${#presets[@]}]: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#presets[@]} )); then
    echo -e "${C_RED}Invalid selection.${C_RESET}"; return 1
  fi
  selected_preset="${presets[$((choice-1))]}"
  user_group="$(id -gn "$TARGET_USER")"
  local numa_prefix="" env_lines="" kv=""
  [[ -f "$NUMACTL_MARKER" ]] && command -v numactl >/dev/null 2>&1 && numa_prefix="$(command -v numactl) --interleave=all "
  while IFS= read -r kv; do
    [[ -n "$kv" ]] && env_lines+="Environment=${kv}"$'\n'
  done < <(strata_runtime_env_list)

  install_service strata.service <<EOF
[Unit]
Description=Strata LLM Service (${selected_preset})
After=network-online.target multi-user.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${TARGET_USER}
Group=${user_group}
WorkingDirectory=${TARGET_HOME}
${env_lines:+${env_lines%$'\n'}$'\n'}ExecStart=${numa_prefix}${STRATA_BIN} launch --preset "${selected_preset}" --no-tui --yes
ExecStop=${STRATA_BIN} launch --stop --preset "${selected_preset}"
LimitMEMLOCK=infinity
TimeoutStartSec=0
TimeoutStopSec=30
SyslogIdentifier=strata

[Install]
WantedBy=multi-user.target
EOF
  echo -e "${C_GREEN}strata.service installed and started with preset '${selected_preset}'.${C_RESET}"
}
format_avg_power_str() {
  local sys_w="${1:-}" gpu_w="${2:-}" cpu_w="${3:-}"
  local parts=()
  [[ -n "$gpu_w" ]] && parts+=("GPU ${gpu_w}W")
  [[ -n "$cpu_w" ]] && parts+=("CPU ${cpu_w}W")
  local detail=""
  if (( ${#parts[@]} > 0 )); then
    local i
    for ((i=0; i<${#parts[@]}; i++)); do
      (( i > 0 )) && detail+=", "
      detail+="${parts[$i]}"
    done
  fi
  if [[ -n "$sys_w" ]]; then
    [[ -n "$detail" ]] && echo "Sys ${sys_w}W (${detail})" || echo "Sys ${sys_w}W"
  elif [[ -n "$detail" ]]; then
    echo "$detail"
  fi
}

find_latest_results_json() {
  local min_mtime="${1:-0}" newest="" d f fm
  local search_dirs=("$PWD/bench/results" "$PWD/bench-results" "$TARGET_HOME/bench/results" "$TARGET_HOME/bench-results" "$TARGET_HOME/.local/share/strata/bench-results" "$TARGET_HOME/.config/strata/bench-results")
  for d in "${search_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*/results.json "$d"/results.json; do
      [[ -r "$f" ]] || continue
      if (( min_mtime > 0 )); then
        fm="$(stat -c '%Y' "$f" 2>/dev/null || echo 0)"
        (( fm >= min_mtime )) || continue
      fi
      if [[ -z "$newest" || "$f" -nt "$newest" ]]; then
        newest="$f"
      fi
    done
  done
  [[ -n "$newest" ]] && printf "%s" "$newest"
}

read_jetson_ina3221_watts() {
  local d ch rname pval mv ma sw="" gw="" cw=""
  for d in /sys/bus/i2c/drivers/ina3221x/*/iio:device*; do
    [[ -d "$d" ]] || continue
    for ch in 0 1 2; do
      [[ -r "$d/rail_name_${ch}" && -r "$d/in_power${ch}_input" ]] || continue
      rname="$(cat "$d/rail_name_${ch}" 2>/dev/null || true)"
      pval="$(cat "$d/in_power${ch}_input" 2>/dev/null || true)"
      [[ "$pval" =~ ^[0-9]+$ ]] || continue
      case "$rname" in
        VDD_IN|POM_5V_IN|VIN_SYS_5V0) [[ -z "$sw" ]] && sw="$(awk -v m="$pval" 'BEGIN{printf "%.2f", m/1000.0}')" ;;
        VDD_GPU|POM_5V_GPU|VDD_GPU_SOC|VDD_CPU_GPU_CV) [[ -z "$gw" ]] && gw="$(awk -v m="$pval" 'BEGIN{printf "%.2f", m/1000.0}')" ;;
        VDD_CPU|POM_5V_CPU|VDD_SYS_CPU|VDD_CPU_CV) [[ -z "$cw" ]] && cw="$(awk -v m="$pval" 'BEGIN{printf "%.2f", m/1000.0}')" ;;
      esac
    done
  done
  if [[ -z "$sw" && -z "$gw" && -z "$cw" ]]; then
    local hm_base="${STRATA_HWMON_DIR:-/sys/class/hwmon}" hm
    for hm in "$hm_base"/hwmon*; do
      [[ -r "$hm/name" ]] || continue
      [[ "$(cat "$hm/name" 2>/dev/null || true)" == "ina3221" ]] || continue
      for ch in 0 1 2 3; do
        [[ -r "$hm/in${ch}_label" && -r "$hm/in${ch}_input" && -r "$hm/curr${ch}_input" ]] || continue
        rname="$(cat "$hm/in${ch}_label" 2>/dev/null || true)"
        mv="$(cat "$hm/in${ch}_input" 2>/dev/null || true)"
        ma="$(cat "$hm/curr${ch}_input" 2>/dev/null || true)"
        [[ "$mv" =~ ^[0-9]+$ && "$ma" =~ ^[0-9]+$ ]] || continue
        pval="$(awk -v v="$mv" -v c="$ma" 'BEGIN{printf "%.2f", (v*c)/1000000.0}')"
        case "$rname" in
          VDD_IN|POM_5V_IN|VIN_SYS_5V0) [[ -z "$sw" ]] && sw="$pval" ;;
          VDD_GPU|POM_5V_GPU|VDD_GPU_SOC|VDD_CPU_GPU_CV) [[ -z "$gw" ]] && gw="$pval" ;;
          VDD_CPU|POM_5V_CPU|VDD_SYS_CPU|VDD_CPU_CV) [[ -z "$cw" ]] && cw="$pval" ;;
        esac
      done
    done
  fi
  printf "%s|%s|%s" "$sw" "$gw" "$cw"
}

start_bench_power_sampler() {
  local out_file="$1"
  (
    local n=0 gpu_sum="0" cpu_sum="0" sys_sum="0" gpu_n=0 cpu_n=0 sys_n=0
    local prev_uj="" prev_us="" rapl_f="/sys/class/powercap/intel-rapl:0/energy_uj" rapl_mode="none"
    local -A prev_intel_uj=() prev_intel_us=()
    if [[ -r "$rapl_f" ]]; then
      rapl_mode="direct"
    elif [[ -e "$rapl_f" ]] && sudo -n true >/dev/null 2>&1; then
      rapl_mode="sudo"
    fi
    local stop=false
    trap 'stop=true' TERM INT USR1
    while [[ "$stop" == false ]]; do
      local gw="0" has_g=false
      if [[ "$HAS_NVIDIA" == true ]] && command -v nvidia-smi >/dev/null 2>&1; then
        local nv_p
        nv_p="$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | awk '{if($1~/^[0-9]+(\.[0-9]+)?$/){s+=$1; c++}} END{if(c>0) printf "%.2f", s}')"
        if [[ -n "$nv_p" ]]; then gw="$nv_p"; has_g=true; fi
      fi
      if [[ "$HAS_AMD" == true ]]; then
        local drm_dir="${STRATA_DRM_DIR:-/sys/class/drm}" card_dir hwmon_dir pa
        for card_dir in "${drm_dir}"/card[0-9]*/device; do
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

      local sw="" hm_dir hm_name pf uw
      for hm_dir in /sys/class/hwmon/hwmon*; do
        [[ -r "$hm_dir/name" ]] || continue
        hm_name="$(cat "$hm_dir/name" 2>/dev/null || true)"
        case "$hm_name" in
          corsair-psu|acpi_power_meter|power_meter)
            for pf in "$hm_dir"/power1_input "$hm_dir"/power1_average; do
              if [[ -r "$pf" ]]; then
                uw="$(cat "$pf" 2>/dev/null || echo 0)"
                [[ "$uw" =~ ^[0-9]+$ ]] && (( uw > 0 )) && { sw="$(awk -v u="$uw" 'BEGIN{printf "%.2f", u/1000000.0}')"; break 2; }
              fi
            done
            ;;
        esac
      done
      if [[ -z "$sw" ]]; then
        local bat_d bat_st cur_ua volt_uv
        for bat_d in /sys/class/power_supply/BAT*; do
          [[ -d "$bat_d" ]] || continue
          if [[ -r "$bat_d/power_now" ]]; then
            uw="$(cat "$bat_d/power_now" 2>/dev/null || echo 0)"
            [[ "$uw" =~ ^[0-9]+$ ]] && (( uw > 0 )) && { sw="$(awk -v u="$uw" 'BEGIN{printf "%.2f", u/1000000.0}')"; break; }
          elif [[ -r "$bat_d/current_now" && -r "$bat_d/voltage_now" ]]; then
            bat_st="$(cat "$bat_d/status" 2>/dev/null || true)"
            cur_ua="$(cat "$bat_d/current_now" 2>/dev/null || echo 0)"
            volt_uv="$(cat "$bat_d/voltage_now" 2>/dev/null || echo 0)"
            if [[ "$bat_st" == "Discharging" && "$cur_ua" =~ ^[0-9]+$ && "$volt_uv" =~ ^[0-9]+$ ]] && (( cur_ua > 0 && volt_uv > 0 )); then
              sw="$(awk -v c="$cur_ua" -v v="$volt_uv" 'BEGIN{printf "%.2f", (c/1000000.0)*(v/1000000.0)}')"
              break
            fi
          fi
        done
      fi
      if [[ -n "$sw" ]]; then
        sys_sum="$(awk -v a="$sys_sum" -v b="$sw" 'BEGIN{printf "%.2f", a + b}')"
        ((sys_n++))
      fi

      ((n++))
      (sleep 0.25 2>/dev/null || sleep 1) &
      wait $! 2>/dev/null || true
    done

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

save_bench_history_entry() {
  local results_file="$1" mode="$2" avg_sys="$3" avg_gpu="$4" avg_cpu="$5" samples="$6" active_csv="$7" applicable_csv="$8"
  command -v python3 >/dev/null 2>&1 || return 0
  local hist_dir
  hist_dir="$(dirname "$STRATA_BENCH_HISTORY_FILE")"
  run_as_user_exec mkdir -p "$hist_dir" 2>/dev/null || mkdir -p "$hist_dir"
  local tmp_file
  tmp_file="$(mktemp "${STRATA_BENCH_HISTORY_FILE}.tmp.XXXXXX" 2>/dev/null || echo "")"
  [[ -n "$tmp_file" ]] || return 1

  python3 - "$STRATA_BENCH_HISTORY_FILE" "$tmp_file" "$results_file" "$mode" "${STRATA_RUNNING_PRESET:-}" "${STRATA_RUNNING_URL:-}" "$avg_sys" "$avg_gpu" "$avg_cpu" "${samples:-0}" "$active_csv" "$applicable_csv" <<'PY'
import datetime, json, os, statistics, sys

(
    hist_path, tmp_path, res_path, mode, preset, url,
    avg_sys, avg_gpu, avg_cpu, samples_s, active_csv, applicable_csv
) = sys.argv[1:13]

history = []
if os.path.exists(hist_path):
    try:
        with open(hist_path) as f:
            loaded = json.load(f)
            if isinstance(loaded, list):
                history = loaded
    except Exception:
        history = []

res_data = {}
if res_path and os.path.exists(res_path):
    try:
        with open(res_path) as f:
            res_data = json.load(f)
    except Exception:
        res_data = {}

if not isinstance(res_data, dict):
    res_data = {}

run = res_data.get("run") if isinstance(res_data.get("run"), dict) else {}
ts = run.get("started_at") or run.get("timestamp") or res_data.get("timestamp") or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
cfg = res_data.get("configuration") if isinstance(res_data.get("configuration"), dict) else {}
proto_d = res_data.get("protocol") if isinstance(res_data.get("protocol"), dict) else {}
prof = proto_d.get("profile") or cfg.get("profile") or preset or ""
proto = proto_d.get("id") or res_data.get("protocol_id") or res_data.get("format") or ""
tag = prof or ("standard-v1" if "standard" in proto else proto) or mode

mdl = res_data.get("model")
if isinstance(mdl, dict):
    m_name = mdl.get("name") or mdl.get("id") or ""
    m_quant = mdl.get("quantization") or ""
    if m_name and m_quant and m_quant.lower() not in m_name.lower():
        model_s = f"{m_name} ({m_quant})"
    else:
        model_s = m_name or m_quant or "Unknown"
elif isinstance(mdl, str) and mdl:
    model_s = mdl
else:
    model_s = "Unknown"

sums_raw = res_data.get("summaries") if "summaries" in res_data else res_data.get("summary")
reqs = res_data.get("requests") if isinstance(res_data.get("requests"), list) else []

dec = None
pre = None
tot_r = None
fail_r = 0

if isinstance(sums_raw, list):
    perf_dec = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("phase") == "performance" and s.get("metric") == "decode_tps" and isinstance(s.get("median"), (int, float))]
    all_dec = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("metric") == "decode_tps" and isinstance(s.get("median"), (int, float))]
    perf_pre = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("phase") == "performance" and s.get("metric") == "prompt_tps" and isinstance(s.get("median"), (int, float))]
    all_pre = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("metric") == "prompt_tps" and isinstance(s.get("median"), (int, float))]
    if perf_dec:
        dec = statistics.median(perf_dec)
    elif all_dec:
        dec = statistics.median(all_dec)
    if perf_pre:
        pre = statistics.median(perf_pre)
    elif all_pre:
        pre = statistics.median(all_pre)
elif isinstance(sums_raw, dict):
    dec = sums_raw.get("median_decode_tok_s") or sums_raw.get("decode_tps") or sums_raw.get("decode_tok_s")
    pre = sums_raw.get("median_prefill_tok_s") or sums_raw.get("prompt_tps") or sums_raw.get("prefill_tok_s")
    tot_r = sums_raw.get("total_requests")
    fail_r = sums_raw.get("failed_requests") if isinstance(sums_raw.get("failed_requests"), int) else 0

if dec is None:
    vals = [r.get("decode_tok_s") for r in reqs if isinstance(r, dict) and isinstance(r.get("decode_tok_s"), (int, float))]
    if vals:
        dec = statistics.median(vals)
if pre is None:
    vals = [r.get("prefill_tok_s") for r in reqs if isinstance(r, dict) and isinstance(r.get("prefill_tok_s"), (int, float))]
    if vals:
        pre = statistics.median(vals)

perf_reqs = [r for r in reqs if isinstance(r, dict) and r.get("phase") == "performance"]
req_pool = perf_reqs if perf_reqs else [r for r in reqs if isinstance(r, dict) and r.get("phase") != "warmup"]
avg_dec_vals = []
avg_pre_vals = []
for r in req_pool:
    m = r.get("metrics") if isinstance(r.get("metrics"), dict) else {}
    dv = m.get("decode_tps") if isinstance(m.get("decode_tps"), (int, float)) else r.get("decode_tok_s")
    pv = m.get("prompt_tps") if isinstance(m.get("prompt_tps"), (int, float)) else r.get("prefill_tok_s")
    if dv is None:
        tk = r.get("tokens") if isinstance(r.get("tokens"), dict) else {}
        tm = r.get("timings") if isinstance(r.get("timings"), dict) else {}
        if isinstance(tk.get("decode_tokens"), (int, float)) and isinstance(tm.get("decode_s"), (int, float)) and tm["decode_s"] > 0:
            dv = tk["decode_tokens"] / tm["decode_s"]
    if pv is None:
        tk = r.get("tokens") if isinstance(r.get("tokens"), dict) else {}
        tm = r.get("timings") if isinstance(r.get("timings"), dict) else {}
        rtok = tk.get("read_tokens") if isinstance(tk.get("read_tokens"), (int, float)) else tk.get("input_tokens")
        if isinstance(rtok, (int, float)) and isinstance(tm.get("prompt_s"), (int, float)) and tm["prompt_s"] > 0:
            pv = rtok / tm["prompt_s"]
    if isinstance(dv, (int, float)):
        avg_dec_vals.append(dv)
    if isinstance(pv, (int, float)):
        avg_pre_vals.append(pv)
avg_dec = statistics.mean(avg_dec_vals) if avg_dec_vals else None
avg_pre = statistics.mean(avg_pre_vals) if avg_pre_vals else None

rcounts = res_data.get("request_counts") if isinstance(res_data.get("request_counts"), dict) else {}
if not isinstance(tot_r, int) and rcounts:
    tot_r = sum(v.get("attempted", 0) for v in rcounts.values() if isinstance(v, dict) and isinstance(v.get("attempted"), int))
    fail_r = sum(v.get("failed", 0) for v in rcounts.values() if isinstance(v, dict) and isinstance(v.get("failed"), int))
if not isinstance(tot_r, int) and reqs:
    tot_r = len(reqs)
    fail_r = sum(1 for r in reqs if isinstance(r, dict) and r.get("status") not in (None, "ok", "completed"))

qual = res_data.get("quality") if isinstance(res_data.get("quality"), dict) else {}
qp = qual.get("sanity_checks_passed") if qual.get("sanity_checks_passed") is not None else qual.get("passed")
qt = qual.get("sanity_checks_total") if qual.get("sanity_checks_total") is not None else qual.get("total")
entry = {
    "id": run.get("id") or ts,
    "timestamp": ts,
    "mode": mode,
    "tag": tag,
    "preset": preset,
    "url": url,
    "results_file": res_path,
    "model": model_s,
    "decode_tok_s": round(dec, 2) if isinstance(dec, (int, float)) else None,
    "prefill_tok_s": round(pre, 2) if isinstance(pre, (int, float)) else None,
    "avg_decode_tok_s": round(avg_dec, 2) if isinstance(avg_dec, (int, float)) else None,
    "avg_prefill_tok_s": round(avg_pre, 2) if isinstance(avg_pre, (int, float)) else None,
    "total_requests": tot_r if isinstance(tot_r, int) else None,
    "failed_requests": fail_r if isinstance(fail_r, int) else 0,
    "sanity_checks_passed": qp,
    "sanity_checks_total": qt,
    "avg_power": {
        "sys_w": avg_sys,
        "gpu_w": avg_gpu,
        "cpu_w": avg_cpu,
        "samples": int(samples_s) if samples_s.isdigit() else 0,
    },
    "active_steps": [s for s in active_csv.split(",") if s],
    "applicable_steps": [s for s in applicable_csv.split(",") if s],
}
history.append(entry)
with open(tmp_path, "w") as f:
    json.dump(history, f, indent=2)
os.replace(tmp_path, hist_path)
PY
  if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
    chown -R "$TARGET_USER:$(id -gn "$TARGET_USER")" "$hist_dir" 2>/dev/null || true
  fi
}

count_bench_history() {
  command -v python3 >/dev/null 2>&1 || { echo 0; return 0; }
  local newest="" hist_mtime="0" newest_mtime="0" ckey
  newest="$(find_latest_results_json 0)"
  [[ -r "$STRATA_BENCH_HISTORY_FILE" ]] && hist_mtime="$(stat -c '%Y' "$STRATA_BENCH_HISTORY_FILE" 2>/dev/null || echo 0)"
  [[ -n "$newest" ]] && newest_mtime="$(stat -c '%Y' "$newest" 2>/dev/null || echo 0)"
  ckey="${STRATA_BENCH_HISTORY_FILE}:${hist_mtime}:${newest}:${newest_mtime}"
  if [[ "$ckey" == "$BENCH_HISTORY_COUNT_KEY" ]]; then
    echo "$BENCH_HISTORY_COUNT_CACHE"
    return 0
  fi
  local cnt
  cnt="$(python3 - "$STRATA_BENCH_HISTORY_FILE" "$PWD/bench/results" "$PWD/bench-results" "$TARGET_HOME/bench/results" "$TARGET_HOME/bench-results" "$TARGET_HOME/.local/share/strata/bench-results" "$TARGET_HOME/.config/strata/bench-results" <<'PY' 2>/dev/null || echo 0
import glob, json, os, sys
hist_path = sys.argv[1]
search_dirs = sys.argv[2:]
seen = set()
count = 0
if hist_path and os.path.exists(hist_path):
    try:
        with open(hist_path) as f:
            d = json.load(f)
        if isinstance(d, list):
            for e in d:
                if not isinstance(e, dict):
                    continue
                rf = e.get("results_file") or ""
                key = os.path.realpath(rf) if rf else f"hist:{e.get('id') or e.get('timestamp') or count}"
                if key not in seen:
                    seen.add(key)
                    count += 1
    except Exception:
        pass
for sd in search_dirs:
    if not os.path.isdir(sd):
        continue
    for pat in (os.path.join(sd, "*", "results.json"), os.path.join(sd, "results.json")):
        for p in glob.glob(pat):
            rp = os.path.realpath(p)
            if rp not in seen:
                seen.add(rp)
                count += 1
print(count)
PY
)"
  [[ "$cnt" =~ ^[0-9]+$ ]] || cnt=0
  BENCH_HISTORY_COUNT_KEY="$ckey"
  BENCH_HISTORY_COUNT_CACHE="$cnt"
  echo "$cnt"
}

apply_bench_history_config() {
  local target_csv="$1"
  build_active_steps
  local -A target_map=()
  local st
  IFS=',' read -ra _tarr <<< "$target_csv"
  for st in "${_tarr[@]}"; do
    [[ -n "$st" ]] && target_map["$st"]=1
  done

  local to_apply=() to_revert=()
  for st in "${ACTIVE_STEPS[@]}"; do
    [[ "$st" == "strata_manager" ]] && continue
    local cur_applied=false
    "status_${st}" && cur_applied=true
    if [[ -n "${target_map[$st]+x}" ]]; then
      [[ "$cur_applied" == false ]] && to_apply+=("$st")
    else
      [[ "$cur_applied" == true ]] && to_revert+=("$st")
    fi
  done

  if (( ${#to_apply[@]} == 0 && ${#to_revert[@]} == 0 )); then
    echo -e "\n${C_GREEN}System already matches this benchmark's active options.${C_RESET}"
    return 0
  fi

  if (( ${#to_apply[@]} > 0 )); then
    echo -e "\n${C_GREEN}Options to APPLY (${#to_apply[@]}):${C_RESET}"
    for st in "${to_apply[@]}"; do echo "  + $("title_${st}")"; done
  fi
  if (( ${#to_revert[@]} > 0 )); then
    echo -e "\n${C_RED}Options to REVERT (${#to_revert[@]}):${C_RESET}"
    for st in "${to_revert[@]}"; do echo "  - $("title_${st}")"; done
  fi

  echo ""
  local _ans="" _ch=""
  printf "%s" "Apply and revert options to match this benchmark configuration? [y] Apply / [N/c/Esc] Cancel: "
  while true; do
    IFS= read -rsn1 _ch || { echo ""; echo -e "${C_YELLOW}Cancelled. No changes were made.${C_RESET}"; return 2; }
    if [[ -z "$_ch" ]]; then
      echo ""
      break
    elif [[ "$_ch" == $'\e' ]]; then
      local _esc=""
      IFS= read -rsn2 -t 0.01 _esc || true
      if [[ -z "$_esc" ]]; then
        echo ""
        echo -e "${C_YELLOW}Cancelled. No changes were made.${C_RESET}"
        return 2
      fi
    elif [[ "$_ch" == $'\177' || "$_ch" == $'\b' ]]; then
      if [[ -n "$_ans" ]]; then
        _ans="${_ans%?}"
        printf "\b \b"
      fi
    else
      _ans+="$_ch"
      printf "%s" "$_ch"
    fi
  done
  [[ -z "$_ans" ]] && _ans="N"
  case "$_ans" in
    y|Y|yes|YES|Yes) ;;
    n|N|no|NO|No|c|C|cancel|CANCEL|Cancel|b|B|q|Q)
      echo -e "${C_YELLOW}Cancelled. No changes were made.${C_RESET}"
      return 2
      ;;
    *)
      echo -e "${C_RED}Invalid input '${_ans}'. Cancelled.${C_RESET}"
      return 2
      ;;
  esac

  for st in "${to_revert[@]}"; do
    echo -e "\n${C_BOLD}${C_RED}>>> Reverting: $("title_${st}")${C_RESET}"
    "revert_${st}" || echo -e "${C_YELLOW}Step '${st}' exited with a warning.${C_RESET}"
  done
  for st in "${to_apply[@]}"; do
    echo -e "\n${C_BOLD}${C_CYAN}>>> Applying: $("title_${st}")${C_RESET}"
    "apply_${st}" || echo -e "${C_YELLOW}Step '${st}' exited with a warning or was skipped.${C_RESET}"
  done
  echo -e "\n${C_GREEN}Finished restoring benchmark configuration.${C_RESET}"
  prompt_reboot_if_needed
}

HIST_SELECTED=0

show_benchmark_history() {
  local -A HIST_EXPANDED=()
  while true; do
    print_header none true
    if ! command -v python3 >/dev/null 2>&1; then
      echo -e "${C_BOLD}Strata Benchmark History & Coupled Configurations${C_RESET}"
      echo -e "${C_DIM}----------------------------------------------------------------------${C_RESET}"
      echo -e "${C_DIM}python3 is required to parse benchmark results.${C_RESET}"
      pause_prompt
      return 0
    fi

    local rows=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && rows+=("$line")
    done < <(python3 - "$STRATA_BENCH_HISTORY_FILE" "$PWD/bench/results" "$PWD/bench-results" "$TARGET_HOME/bench/results" "$TARGET_HOME/bench-results" "$TARGET_HOME/.local/share/strata/bench-results" "$TARGET_HOME/.config/strata/bench-results" <<'PY' 2>/dev/null || true
import datetime, glob, json, os, statistics, sys

hist_path = sys.argv[1]
search_dirs = sys.argv[2:]

def fmt_ts(ts):
    ts = (ts or "").replace("T", " ")
    if ts.endswith("Z"):
        ts = ts[:-1] + " UTC"
    if len(ts) > 20 and " UTC" in ts:
        ts = ts[:16] + " UTC"
    return ts

def parse_results(path, he):
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception:
        return None
    if not isinstance(d, dict):
        return None
    run = d.get("run") if isinstance(d.get("run"), dict) else {}
    ts = fmt_ts(run.get("started_at") or run.get("timestamp") or d.get("timestamp") or "")
    if not ts:
        try:
            ts = datetime.datetime.fromtimestamp(os.path.getmtime(path), tz=datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        except Exception:
            ts = "Unknown"
    cfg = d.get("configuration") if isinstance(d.get("configuration"), dict) else {}
    proto_d = d.get("protocol") if isinstance(d.get("protocol"), dict) else {}
    prof = proto_d.get("profile") or cfg.get("profile") or ""
    proto = proto_d.get("id") or d.get("protocol_id") or d.get("format") or ""
    tag = prof or ("standard-v1" if "standard" in proto else proto) or (he.get("tag") if he else "") or "cli"
    mdl = d.get("model")
    if isinstance(mdl, dict):
        m_name = mdl.get("name") or mdl.get("id") or ""
        m_quant = mdl.get("quantization") or ""
        if m_name and m_quant and m_quant.lower() not in m_name.lower():
            model = f"{m_name} ({m_quant})"
        else:
            model = m_name or m_quant or "Unknown"
    elif isinstance(mdl, str) and mdl:
        model = mdl
    else:
        model = (he.get("model") if he else None) or "Unknown"
    sums_raw = d.get("summaries") if "summaries" in d else d.get("summary")
    reqs = d.get("requests") if isinstance(d.get("requests"), list) else []
    dec = None
    pre = None
    tot_r = None
    fail_r = 0
    if isinstance(sums_raw, list):
        perf_dec = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("phase") == "performance" and s.get("metric") == "decode_tps" and isinstance(s.get("median"), (int, float))]
        all_dec = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("metric") == "decode_tps" and isinstance(s.get("median"), (int, float))]
        perf_pre = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("phase") == "performance" and s.get("metric") == "prompt_tps" and isinstance(s.get("median"), (int, float))]
        all_pre = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("metric") == "prompt_tps" and isinstance(s.get("median"), (int, float))]
        if perf_dec:
            dec = statistics.median(perf_dec)
        elif all_dec:
            dec = statistics.median(all_dec)
        if perf_pre:
            pre = statistics.median(perf_pre)
        elif all_pre:
            pre = statistics.median(all_pre)
    elif isinstance(sums_raw, dict):
        dec = sums_raw.get("median_decode_tok_s") or sums_raw.get("decode_tps") or sums_raw.get("decode_tok_s")
        pre = sums_raw.get("median_prefill_tok_s") or sums_raw.get("prompt_tps") or sums_raw.get("prefill_tok_s")
        tot_r = sums_raw.get("total_requests")
        fail_r = sums_raw.get("failed_requests") if isinstance(sums_raw.get("failed_requests"), int) else 0
    if dec is None:
        vals = [r.get("decode_tok_s") for r in reqs if isinstance(r, dict) and isinstance(r.get("decode_tok_s"), (int, float))]
        if vals:
            dec = statistics.median(vals)
    if pre is None:
        vals = [r.get("prefill_tok_s") for r in reqs if isinstance(r, dict) and isinstance(r.get("prefill_tok_s"), (int, float))]
        if vals:
            pre = statistics.median(vals)
    perf_reqs = [r for r in reqs if isinstance(r, dict) and r.get("phase") == "performance"]
    req_pool = perf_reqs if perf_reqs else [r for r in reqs if isinstance(r, dict) and r.get("phase") != "warmup"]
    avg_dec_vals = []
    avg_pre_vals = []
    for r in req_pool:
        m = r.get("metrics") if isinstance(r.get("metrics"), dict) else {}
        dv = m.get("decode_tps") if isinstance(m.get("decode_tps"), (int, float)) else r.get("decode_tok_s")
        pv = m.get("prompt_tps") if isinstance(m.get("prompt_tps"), (int, float)) else r.get("prefill_tok_s")
        if dv is None:
            tk = r.get("tokens") if isinstance(r.get("tokens"), dict) else {}
            tm = r.get("timings") if isinstance(r.get("timings"), dict) else {}
            if isinstance(tk.get("decode_tokens"), (int, float)) and isinstance(tm.get("decode_s"), (int, float)) and tm["decode_s"] > 0:
                dv = tk["decode_tokens"] / tm["decode_s"]
        if pv is None:
            tk = r.get("tokens") if isinstance(r.get("tokens"), dict) else {}
            tm = r.get("timings") if isinstance(r.get("timings"), dict) else {}
            rtok = tk.get("read_tokens") if isinstance(tk.get("read_tokens"), (int, float)) else tk.get("input_tokens")
            if isinstance(rtok, (int, float)) and isinstance(tm.get("prompt_s"), (int, float)) and tm["prompt_s"] > 0:
                pv = rtok / tm["prompt_s"]
        if isinstance(dv, (int, float)):
            avg_dec_vals.append(dv)
        if isinstance(pv, (int, float)):
            avg_pre_vals.append(pv)
    avg_dec = statistics.mean(avg_dec_vals) if avg_dec_vals else (he.get("avg_decode_tok_s") if he else None)
    avg_pre = statistics.mean(avg_pre_vals) if avg_pre_vals else (he.get("avg_prefill_tok_s") if he else None)
    dec_s = f"{dec:.1f}" if isinstance(dec, (int, float)) else "—"
    pre_s = f"{pre:.1f}" if isinstance(pre, (int, float)) else "—"
    avg_dec_s = f"{avg_dec:.1f}" if isinstance(avg_dec, (int, float)) else ""
    avg_pre_s = f"{avg_pre:.1f}" if isinstance(avg_pre, (int, float)) else ""
    req_d = run.get("required_duration_s")
    opt_d = run.get("optional_duration_s")
    dur_s = ""
    if isinstance(req_d, (int, float)):
        tot_d = req_d + (opt_d if isinstance(opt_d, (int, float)) else 0.0)
        dur_s = f"{tot_d:.1f}s"
    rcounts = d.get("request_counts") if isinstance(d.get("request_counts"), dict) else {}
    if not isinstance(tot_r, int) and rcounts:
        tot_r = sum(v.get("attempted", 0) for v in rcounts.values() if isinstance(v, dict) and isinstance(v.get("attempted"), int))
        fail_r = sum(v.get("failed", 0) for v in rcounts.values() if isinstance(v, dict) and isinstance(v.get("failed"), int))
    if not isinstance(tot_r, int) and reqs:
        tot_r = len(reqs)
        fail_r = sum(1 for r in reqs if isinstance(r, dict) and r.get("status") not in (None, "ok", "completed"))
    req_s = f"{tot_r - fail_r}/{tot_r} ok" if isinstance(tot_r, int) and tot_r > 0 else ""
    qual = d.get("quality") if isinstance(d.get("quality"), dict) else {}
    qp = qual.get("sanity_checks_passed") if qual.get("sanity_checks_passed") is not None else qual.get("passed")
    qt = qual.get("sanity_checks_total") if qual.get("sanity_checks_total") is not None else qual.get("total")
    qual_s = f"Sanity {qp}/{qt}" if isinstance(qp, int) and isinstance(qt, int) and qt > 0 else ""
    pwr = (he.get("avg_power") if isinstance((he or {}).get("avg_power"), dict) else {})
    sw, gw, cw = str(pwr.get("sys_w") or ""), str(pwr.get("gpu_w") or ""), str(pwr.get("cpu_w") or "")
    has_opts = "1" if (he is not None and "active_steps" in he) else "0"
    act_list = (he.get("active_steps") if isinstance((he or {}).get("active_steps"), list) else [])
    act = ",".join(act_list)
    act_n = str(len(act_list)) if has_opts == "1" else "untracked"
    return [ts, tag, model, dec_s, pre_s, sw, gw, cw, act_n, act, req_s, qual_s, has_opts, avg_dec_s, avg_pre_s, dur_s]

hist_list = []
hist_by_file = {}
if hist_path and os.path.exists(hist_path):
    try:
        with open(hist_path) as f:
            loaded = json.load(f)
        if isinstance(loaded, list):
            hist_list = [e for e in loaded if isinstance(e, dict)]
            for e in hist_list:
                rf = e.get("results_file")
                if rf:
                    hist_by_file[rf] = e
                    hist_by_file[os.path.realpath(rf)] = e
    except Exception:
        pass

out_rows = []
seen = set()
for e in reversed(hist_list):
    rf = e.get("results_file") or ""
    rp = os.path.realpath(rf) if rf else f"hist:{e.get('id') or e.get('timestamp') or len(out_rows)}"
    if rp in seen:
        continue
    seen.add(rp)
    if rf and os.path.exists(rf):
        row = parse_results(rf, e)
        if row:
            out_rows.append(row)
            continue
    ts = fmt_ts(e.get("timestamp"))
    tag = e.get("tag") or e.get("mode") or ""
    model = e.get("model") or "Unknown"
    dec, pre = e.get("decode_tok_s"), e.get("prefill_tok_s")
    dec_s = f"{dec:.1f}" if isinstance(dec, (int, float)) else "—"
    pre_s = f"{pre:.1f}" if isinstance(pre, (int, float)) else "—"
    pwr = e.get("avg_power") if isinstance(e.get("avg_power"), dict) else {}
    sw, gw, cw = str(pwr.get("sys_w") or ""), str(pwr.get("gpu_w") or ""), str(pwr.get("cpu_w") or "")
    act_list = e.get("active_steps") if isinstance(e.get("active_steps"), list) else []
    act = ",".join(act_list)
    tot_r = e.get("total_requests")
    fail_r = e.get("failed_requests") if isinstance(e.get("failed_requests"), int) else 0
    req_s = f"{tot_r - fail_r}/{tot_r} ok" if isinstance(tot_r, int) and tot_r > 0 else ""
    qp, qt = e.get("sanity_checks_passed"), e.get("sanity_checks_total")
    qual_s = f"Sanity {qp}/{qt}" if isinstance(qp, int) and isinstance(qt, int) and qt > 0 else ""
    avg_dec_h = e.get("avg_decode_tok_s")
    avg_dec_hs = f"{avg_dec_h:.1f}" if isinstance(avg_dec_h, (int, float)) else ""
    avg_pre_h = e.get("avg_prefill_tok_s")
    avg_pre_hs = f"{avg_pre_h:.1f}" if isinstance(avg_pre_h, (int, float)) else ""
    out_rows.append([ts, tag, model, dec_s, pre_s, sw, gw, cw, str(len(act_list)), act, req_s, qual_s, "1", avg_dec_hs, avg_pre_hs, ""])

found_files = []
for sd in search_dirs:
    if not os.path.isdir(sd):
        continue
    for pat in (os.path.join(sd, "*", "results.json"), os.path.join(sd, "results.json")):
        for p in glob.glob(pat):
            try:
                found_files.append((os.path.getmtime(p), os.path.realpath(p), p))
            except Exception:
                pass
found_files.sort(reverse=True)
for _, rp, p in found_files:
    if rp in seen:
        continue
    seen.add(rp)
    row = parse_results(p, hist_by_file.get(rp) or hist_by_file.get(p))
    if row:
        out_rows.append(row)

def _num(s):
    try:
        return float(s) if s not in ("", "—", None) else None
    except Exception:
        return None

best_idx = None
best_score = None
for idx, cols in enumerate(out_rows):
    dv = _num(cols[13])
    if dv is None:
        dv = _num(cols[3])
    pv = _num(cols[14])
    if pv is None:
        pv = _num(cols[4])
    if dv is not None:
        sc = (dv, pv if pv is not None else -1.0)
        if best_score is None or sc > best_score:
            best_score = sc
            best_idx = idx

best_dec = best_score[0] if best_score is not None else None
best_pre = (_num(out_rows[best_idx][14]) if _num(out_rows[best_idx][14]) is not None else _num(out_rows[best_idx][4])) if best_idx is not None else None

for idx, cols in enumerate(out_rows):
    d_pct = ""
    p_pct = ""
    is_best = "1" if (best_idx is not None and idx == best_idx) else "0"
    if best_idx is not None and idx != best_idx:
        dv = _num(cols[13])
        if dv is None:
            dv = _num(cols[3])
        pv = _num(cols[14])
        if pv is None:
            pv = _num(cols[4])
        if dv is not None and best_dec is not None and best_dec > 0:
            d_pct = f"{((dv - best_dec) / best_dec) * 100.0:.1f}"
        if pv is not None and best_pre is not None and best_pre > 0:
            p_pct = f"{((pv - best_pre) / best_pre) * 100.0:.1f}"
    safe_cols = [str(c).replace("|", "/").replace("\n", " ").replace("\r", "") for c in cols + [d_pct, p_pct, is_best]]
    print("|".join([str(idx)] + safe_cols))
PY
)
    if (( ${#rows[@]} == 0 )); then
      echo -e "${C_DIM}No benchmark results found yet.${C_RESET}"
      echo -e "${C_DIM}Run a benchmark from Strata Options (Run Strata Benchmark) to record results, power, and active options.${C_RESET}"
      pause_prompt
      return 0
    fi

    (( HIST_SELECTED >= ${#rows[@]} )) && HIST_SELECTED=$(( ${#rows[@]} - 1 ))
    (( HIST_SELECTED < 0 )) && HIST_SELECTED=0

    local _rule_w=117
    [[ -t 1 ]] && _rule_w="$(tput cols 2>/dev/null || echo 117)"
    (( _rule_w > 117 )) && _rule_w=117
    local tbl_w=$(( _rule_w - 2 ))
    (( tbl_w < 78 )) && tbl_w=78
    local hdr_w=$(( tbl_w - 4 ))
    local val_w=$(( tbl_w - 27 ))
    local _dashes_top _dashes_val _hdr_rule
    printf -v _dashes_top "%*s" "$(( tbl_w - 2 ))" ""; _dashes_top="${_dashes_top// /-}"
    printf -v _dashes_val "%*s" "$(( val_w + 2 ))" ""; _dashes_val="${_dashes_val// /-}"
    printf -v _hdr_rule "%*s" "$_rule_w" ""; _hdr_rule="${_hdr_rule// /-}"
    local _tbl_top="  +${_dashes_top}+"
    local _tbl_rule="  +----------------------+${_dashes_val}+"

    HIST_HDR_LINES=()
    HIST_HDR_PLAIN=()
    HIST_HDR_SEL=()

    local body="" r idx ts tag model dec_s pre_s sw gw cw act_n act_csv req_s qual_s has_opts avg_dec_s avg_pre_s dur_s d_pct p_pct is_best
    local pwr_s dec_cell pre_cell chk_cell diff_cell act_lbl _s
    local opt_items=()
    body+="$(echo -e "${C_BOLD}Strata Benchmark Results & Coupled Configurations (${#rows[@]} recorded)${C_RESET}")"$'\n'
    body+="$(echo -e "${C_DIM}${_hdr_rule}${C_RESET}")"$'\n'
    for r in "${rows[@]}"; do
      IFS='|' read -r idx ts tag model dec_s pre_s sw gw cw act_n act_csv req_s qual_s has_opts avg_dec_s avg_pre_s dur_s d_pct p_pct is_best <<< "$r"
      pwr_s="$(format_avg_power_str "$sw" "$gw" "$cw")"
      [[ -z "$pwr_s" ]] && pwr_s="n/a (not recorded)"

      dec_cell="${dec_s} tok/s"
      [[ -n "$avg_dec_s" ]] && dec_cell+=" (Avg: ${avg_dec_s} tok/s)"
      pre_cell="${pre_s} tok/s"
      [[ -n "$avg_pre_s" ]] && pre_cell+=" (Avg: ${avg_pre_s} tok/s)"

      chk_cell=""
      [[ -n "$req_s" ]] && chk_cell="Reqs: ${req_s}"
      if [[ -n "$qual_s" ]]; then
        [[ -n "$chk_cell" ]] && chk_cell+=" | "
        chk_cell+="$qual_s"
      fi
      [[ -n "$dur_s" ]] && chk_cell+="${chk_cell:+ | }Dur: ${dur_s}"

      opt_items=()
      if [[ "$has_opts" != "1" ]]; then
        opt_items=("Not recorded (CLI run)")
        act_lbl="Active options not recorded for CLI run"
      elif [[ -z "$act_csv" ]]; then
        opt_items=("(none)")
        act_lbl="Press [Enter] or [$((idx + 1))] to revert all active optimizations"
      else
        local _slist=() _stitle
        IFS=',' read -ra _slist <<< "$act_csv"
        for _s in "${_slist[@]}"; do
          if declare -F "title_${_s}" >/dev/null 2>&1; then
            _stitle="$("title_${_s}")"
          else
            _stitle="$_s"
          fi
          opt_items+=("- ${_stitle}")
        done
        act_lbl="Press [Enter] or [$((idx + 1))] to apply/restore these ${act_n} option(s)"
      fi

      local is_exp=false exp_tag="[+]"
      if [[ "${HIST_EXPANDED[$idx]:-0}" == "1" ]]; then
        is_exp=true
        exp_tag="[-]"
      fi
      diff_cell=""
      local diff_hdr=""
      if [[ "$is_best" == "1" ]]; then
        diff_cell="$(printf "%b[BEST]%b %b(Best overall performance)%b" "${C_BGREEN}" "${C_RESET}" "${C_DIM}" "${C_RESET}")"
        diff_hdr="$(printf "%b[BEST]%b" "${C_BGREEN}" "${C_RESET}")"
      else
        local _dp=()
        [[ -n "$d_pct" ]] && _dp+=("Decode $(format_pct_delta "$d_pct")")
        [[ -n "$p_pct" ]] && _dp+=("Prefill $(format_pct_delta "$p_pct")")
        if (( ${#_dp[@]} > 0 )); then
          diff_cell="${_dp[0]}"
          (( ${#_dp[@]} > 1 )) && diff_cell+=" | ${_dp[1]}"
          diff_hdr="$diff_cell"
        fi
      fi

      local _dvis="${diff_hdr//$'\033'\[*([0-9;])m/}"
      local _dlen=${#_dvis}
      local left_max=$(( hdr_w - (_dlen > 0 ? _dlen + 2 : 0) ))
      (( left_max < 10 )) && left_max=10
      local opts_tag="(${act_n} opts)"
      [[ "$has_opts" != "1" ]] && opts_tag="(CLI)"
      local hdr_base="${exp_tag} [$((idx + 1))] ${ts}${tag:+ (${tag})} | ${opts_tag}"
      local hdr_plain_txt="  ${hdr_base}" hdr_sel_txt="> ${hdr_base}"
      (( ${#hdr_plain_txt} > left_max )) && hdr_plain_txt="${hdr_plain_txt:0:$((left_max - 3))}..."
      (( ${#hdr_sel_txt} > left_max )) && hdr_sel_txt="${hdr_sel_txt:0:$((left_max - 3))}..."
      (( ${#model} > val_w )) && model="${model:0:$((val_w - 3))}..."
      (( ${#act_lbl} > val_w )) && act_lbl="${act_lbl:0:$((val_w - 3))}..."

      local gap_p=$(( hdr_w - ${#hdr_plain_txt} - _dlen ))
      local gap_s=$(( hdr_w - ${#hdr_sel_txt} - _dlen ))
      (( gap_p < 0 )) && gap_p=0
      (( gap_s < 0 )) && gap_s=0
      local row_plain row_sel
      row_plain="$(printf "  | ${C_BOLD}%s${C_RESET}%*s%s |" "$hdr_plain_txt" "$gap_p" "" "$diff_hdr")"
      row_sel="$(printf "  | ${C_CYAN}${C_BOLD}%s${C_RESET}%*s%s |" "$hdr_sel_txt" "$gap_s" "" "$diff_hdr")"
      HIST_HDR_PLAIN+=("$row_plain")
      HIST_HDR_SEL+=("$row_sel")

      body+=$'\n'"${_tbl_top}"$'\n'
      local cur_line_no
      cur_line_no="$(printf "%s" "$body" | wc -l)"
      HIST_HDR_LINES+=("$((cur_line_no + 1))")
      if (( idx == HIST_SELECTED )); then
        body+="${row_sel}"$'\n'
      else
        body+="${row_plain}"$'\n'
      fi
      if [[ "$is_exp" == true ]]; then
        body+="${_tbl_rule}"$'\n'
        [[ -n "$diff_cell" ]] && body+="$(printf "  | %-20s | %s |" "Diff (vs Best)" "$(pad_ansi_col "$diff_cell" "$val_w")")"$'\n'
        body+="$(printf "  | %-20s | %-*s |" "Model" "$val_w" "$model")"$'\n'
        body+="$(printf "  | %-20s | ${C_GREEN}%-*s${C_RESET} |" "Decode (Med / Avg)" "$val_w" "$dec_cell")"$'\n'
        body+="$(printf "  | %-20s | ${C_CYAN}%-*s${C_RESET} |" "Prefill (Med / Avg)" "$val_w" "$pre_cell")"$'\n'
        body+="$(printf "  | %-20s | %-*s |" "Average Power" "$val_w" "$pwr_s")"$'\n'
        [[ -n "$chk_cell" ]] && body+="$(printf "  | %-20s | %-*s |" "Checks" "$val_w" "$chk_cell")"$'\n'
        local opts_hdr="Active Opts (${act_n})"
        [[ "$has_opts" != "1" ]] && opts_hdr="Active Opts (CLI)"
        local first_opt_row=true _opt_line
        for _opt_line in "${opt_items[@]}"; do
          (( ${#_opt_line} > val_w )) && _opt_line="${_opt_line:0:$((val_w - 3))}..."
          if [[ "$first_opt_row" == true ]]; then
            body+="$(printf "  | %-20s | %-*s |" "$opts_hdr" "$val_w" "$_opt_line")"$'\n'
            first_opt_row=false
          else
            body+="$(printf "  | %-20s | %-*s |" "" "$val_w" "$_opt_line")"$'\n'
          fi
        done
        body+="$(printf "  | %-20s | ${C_BOLD}%-*s${C_RESET} |" "Restore Options" "$val_w" "$act_lbl")"$'\n'
        body+="${_tbl_rule}"$'\n'
      else
        body+="${_tbl_top}"$'\n'
      fi
    done

    body+=$'\n'"$(echo -e "  ${C_DIM}Use [↑/↓] select, [e/Space] expand/collapse, [Enter] or [1-${#rows[@]} + Enter] apply active options, [b/q/Esc] back:${C_RESET}")"$'\n'
    printf "%s" "$body"
    local body_lines lines_up h_choice hi
    body_lines="$(printf "%s" "$body" | wc -l)"
    for (( hi = 0; hi < ${#HIST_HDR_LINES[@]}; hi++ )); do
      HIST_HDR_LINES[$hi]=$(( body_lines - HIST_HDR_LINES[$hi] + 1 ))
    done
    lines_up=$(( LIVE_STATS_COUNT + POST_HEADER_LINES + body_lines ))
    read_line_with_live_stats h_choice "Select action: " "$lines_up" "${#rows[@]}"
    case "$h_choice" in
      __refresh__) continue ;;
      __toggle__)
        if [[ "${HIST_EXPANDED[$HIST_SELECTED]:-0}" == "1" ]]; then
          HIST_EXPANDED[$HIST_SELECTED]=0
        else
          HIST_EXPANDED[$HIST_SELECTED]=1
        fi
        continue
        ;;
      __esc__|b|B|q|Q) return 0 ;;
      *)
        [[ -z "$h_choice" ]] && h_choice=$(( HIST_SELECTED + 1 ))
        if ! [[ "$h_choice" =~ ^[0-9]+$ ]] || (( h_choice < 1 || h_choice > ${#rows[@]} )); then
          echo -e "${C_RED}Invalid selection '${h_choice}'.${C_RESET}"; sleep 1
          continue
        fi
        HIST_SELECTED=$(( h_choice - 1 ))
        IFS='|' read -r idx ts tag model dec_s pre_s sw gw cw act_n act_csv req_s qual_s has_opts avg_dec_s avg_pre_s dur_s <<< "${rows[$HIST_SELECTED]}"
        pwr_s="$(format_avg_power_str "$sw" "$gw" "$cw")"
        [[ -z "$pwr_s" ]] && pwr_s="n/a"
        echo ""
        echo -e "${C_BOLD}Benchmark #${h_choice}: ${ts} (${tag})${C_RESET}"
        echo "  Model:         $model"
        echo "  Throughput:    Decode ${dec_s} tok/s | Prefill ${pre_s} tok/s"
        echo "  Avg Power:     $pwr_s"
        [[ -n "$req_s$qual_s" ]] && echo "  Checks:        ${req_s}${req_s:+${qual_s:+ | }}${qual_s}"
        if [[ "$has_opts" != "1" ]]; then
          echo -e "  Active Opts:   ${C_YELLOW}Not recorded (this benchmark was run outside the setup script).${C_RESET}"
          echo -e "  ${C_DIM}Run future benchmarks via [s4] Run Strata Benchmark to couple active host options and power.${C_RESET}"
          pause_prompt
        else
          echo -e "  Active Opts (${act_n}):"
          if [[ -z "$act_csv" ]]; then
            echo "    (none)"
          else
            local _s
            IFS=',' read -ra _slist <<< "$act_csv"
            for _s in "${_slist[@]}"; do
              if declare -F "title_${_s}" >/dev/null 2>&1; then
                echo "    * $("title_${_s}")"
              else
                echo "    * $_s"
              fi
            done
          fi
          local _ab_rc=0
          apply_bench_history_config "$act_csv" || _ab_rc=$?
          if (( _ab_rc == 2 )); then
            sleep 1
          else
            pause_prompt
          fi
        fi
        ;;
    esac
  done
}

run_strata_benchmark() {
  LAST_BENCH_COMPLETED=false
  refresh_strata_bin
  refresh_strata_running
  if [[ -z "$STRATA_BIN" || -z "$STRATA_RUNNING_URL" ]]; then
    echo -e "${C_YELLOW}Strata must be installed and running to run a benchmark.${C_RESET}"
    return 1
  fi

  echo -e "${C_BOLD}Strata Benchmark${C_RESET}"
  echo -e "${C_DIM}Target: ${STRATA_RUNNING_PRESET:-active} (${STRATA_RUNNING_URL})${C_RESET}"
  echo "  1) Quick local benchmark (strata bench run --url ${STRATA_RUNNING_URL} --skip-model-hash)"
  echo "  2) Standard protocol benchmark (strata bench run --url ${STRATA_RUNNING_URL})"
  echo "  3) Cancel"
  local b_choice mode="" bench_args=()
  read -r -p "Choose [1-3]: " b_choice
  case "$b_choice" in
    1)
      mode="quick"
      bench_args=(bench run --url "$STRATA_RUNNING_URL" --skip-model-hash)
      ;;
    2)
      mode="standard"
      bench_args=(bench run --url "$STRATA_RUNNING_URL")
      ;;
    3|"")
      echo -e "${C_DIM}Benchmark cancelled.${C_RESET}"
      return 0
      ;;
    *)
      echo -e "${C_RED}Invalid selection '${b_choice}'. Cancelled.${C_RESET}"
      return 1
      ;;
  esac
  if [[ -n "${STRATA_API_KEY:-}" ]]; then
    bench_args+=(--credential-env STRATA_API_KEY --telemetry-credential-env STRATA_API_KEY)
  fi

  build_active_steps
  local active_csv="" applicable_csv="" st
  for st in "${ACTIVE_STEPS[@]}"; do
    [[ "$st" == "strata_manager" ]] && continue
    applicable_csv+="${applicable_csv:+,}${st}"
    if "status_${st}"; then
      active_csv+="${active_csv:+,}${st}"
    fi
  done

  local pwr_file start_epoch rc=0
  pwr_file="$(mktemp /tmp/strata-bench-pwr.XXXXXX 2>/dev/null || echo "")"
  BENCH_POWER_TMP_FILE="$pwr_file"
  start_epoch="$(date +%s)"
  [[ -n "$pwr_file" ]] && start_bench_power_sampler "$pwr_file"

  echo -e "\n${C_CYAN}Running: ${STRATA_BIN} ${bench_args[*]}${C_RESET}\n"
  run_as_user_exec "$STRATA_BIN" "${bench_args[@]}" || rc=$?

  stop_bench_power_sampler
  local avg_sys="" avg_gpu="" avg_cpu="" samples="0"
  if [[ -n "$pwr_file" && -r "$pwr_file" ]]; then
    IFS='|' read -r avg_sys avg_gpu avg_cpu samples < "$pwr_file" || true
    rm -f "$pwr_file" 2>/dev/null || true
  fi
  BENCH_POWER_TMP_FILE=""

  local res_file=""
  res_file="$(find_latest_results_json "$((start_epoch - 2))")"
  if (( rc != 0 )) && [[ -z "$res_file" ]]; then
    echo -e "\n${C_RED}Benchmark exited with code ${rc} and produced no results file.${C_RESET}"
    return "$rc"
  fi

  save_bench_history_entry "$res_file" "$mode" "$avg_sys" "$avg_gpu" "$avg_cpu" "$samples" "$active_csv" "$applicable_csv"
  LAST_BENCH_COMPLETED=true
  STRATA_BENCH_CACHE_KEY=""
  BENCH_HISTORY_COUNT_KEY=""
  local pwr_disp
  pwr_disp="$(format_avg_power_str "$avg_sys" "$avg_gpu" "$avg_cpu")"
  echo -e "\n${C_GREEN}Benchmark saved to coupled host history.${C_RESET}"
  [[ -n "$pwr_disp" ]] && echo -e "  Average Power: ${C_YELLOW}${pwr_disp}${C_RESET} (${samples}s)"
  return "$rc"
}

ACTIVE_STRATA_OPTIONS=()

strata_show_build_hip() {
  (( ${#AMD_MISSING_GFX_ARCHS[@]} > 0 )) && return 0
  _refresh_local_hip_engine_cache
  [[ -n "$LOCAL_HIP_INFO_CACHE_ANY" ]]
}

build_strata_options() {
  if [[ -z "$STRATA_BIN" ]]; then
    ACTIVE_STRATA_OPTIONS=(install)
  else
    ACTIVE_STRATA_OPTIONS=(update remove service benchmark history)
  fi
  if strata_show_build_hip; then
    ACTIVE_STRATA_OPTIONS+=(build_hip)
  fi
}

title_strata_install()   { echo "Install Strata (Niko1221/Strata)"; }
title_strata_update()    { echo "Update Strata (strata update)"; }
title_strata_remove()    { echo "Remove Strata & Uninstall Service"; }
title_strata_service()   { echo "Manage Strata Systemd Service (strata.service)"; }
title_strata_benchmark() { echo "Run Strata Benchmark (strata bench run)"; }
title_strata_history()   { echo "View All Benchmark Results & Coupled Options"; }
title_strata_build_hip() {
  if (( ${#AMD_MISSING_GFX_ARCHS[@]} > 0 )); then
    echo "Build Local Strata HIP Engine (${AMD_MISSING_GFX_SUMMARY})"
  else
    echo "Manage Local Strata HIP Engine"
  fi
}

badge_strata_install() {
  [[ -n "$STRATA_BIN" ]] && echo "${C_GREEN}[INSTALLED]    ${C_RESET}" || echo "${C_YELLOW}[NOT INSTALLED]${C_RESET}"
}
badge_strata_update() {
  if [[ -z "$STRATA_BIN" ]]; then
    echo "${C_DIM}[NOT INSTALLED]${C_RESET}"
  elif [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
    echo "${C_UPDATE_BANNER}[UPDATE READY]${C_RESET} "
  else
    echo "${C_GREEN}[UP TO DATE]   ${C_RESET}"
  fi
}
badge_strata_remove() {
  [[ -n "$STRATA_BIN" ]] && echo "${C_GREEN}[INSTALLED]    ${C_RESET}" || echo "${C_DIM}[NOT INSTALLED]${C_RESET}"
}
badge_strata_service() {
  if [[ -z "$STRATA_BIN" ]]; then
    echo "${C_DIM}[NOT INSTALLED]${C_RESET}"
  elif strata_service_installed; then
    unit_active strata.service && echo "${C_GREEN}[ACTIVE]       ${C_RESET}" || echo "${C_YELLOW}[STOPPED]      ${C_RESET}"
  else
    echo "${C_YELLOW}[NOT SETUP]    ${C_RESET}"
  fi
}
badge_strata_benchmark() {
  if [[ -z "$STRATA_BIN" ]]; then
    echo "${C_DIM}[NOT INSTALLED]${C_RESET}"
  elif [[ -n "$STRATA_RUNNING_URL" ]]; then
    echo "${C_GREEN}[READY]        ${C_RESET}"
  else
    echo "${C_YELLOW}[NOT RUNNING]  ${C_RESET}"
  fi
}
badge_strata_history() {
  local cnt
  cnt="$(count_bench_history)"
  if (( cnt > 0 )); then
    printf "${C_CYAN}%-15s${C_RESET}" "[${cnt} SAVED]"
  else
    echo "${C_DIM}[NONE SAVED]   ${C_RESET}"
  fi
}
badge_strata_build_hip() {
  _refresh_local_hip_engine_cache
  if (( ${#AMD_MISSING_GFX_ARCHS[@]} > 0 )) && [[ -n "$LOCAL_HIP_INFO_CACHE_MATCH" && "${LOCAL_HIP_INFO_CACHE_MATCH##*|}" == "1" ]]; then
    echo "${C_GREEN}[BUILT]        ${C_RESET}"
  elif [[ -n "$LOCAL_HIP_INFO_CACHE_ANY" ]]; then
    echo "${C_CYAN}[LOCAL BUILD]  ${C_RESET}"
  else
    echo "${C_YELLOW}[NOT BUILT]    ${C_RESET}"
  fi
}

strata_action_install() {
  refresh_strata_bin
  if [[ -n "$STRATA_BIN" ]]; then
    echo -e "${C_GREEN}Strata is already installed at: ${STRATA_BIN}${C_RESET}"
    echo -e "${C_DIM}Use [s2] to check for updates.${C_RESET}"
    return 0
  fi
  local hw_warns=""
  hw_warns="$(format_strata_hw_warnings)"
  if [[ -n "$hw_warns" ]]; then
    printf "%s\n\n" "$hw_warns"
  fi
  if confirm_yn "Install Strata now? [Y/n]: " "Y"; then
    command -v curl >/dev/null 2>&1 || prompt_install_deps repo curl || return 0
    run_as_user "curl -fsSL https://github.com/Niko1221/Strata/releases/latest/download/install.sh | sh"
    refresh_strata_bin
    [[ -n "$STRATA_BIN" && -z "$STRATA_POLLER_PID" ]] && start_strata_update_poller
    if [[ -n "$STRATA_BIN" ]] && (( ${#AMD_MISSING_GFX_ARCHS[@]} > 0 )) && ! status_strata_build_hip; then
      echo ""
      if confirm_yn "Detected AMD GPU (${AMD_MISSING_GFX_SUMMARY}) has no prebuilt Strata engine package. Build and register a local HIP engine from source now? [Y/n]: " "Y"; then
        strata_action_build_hip || true
      fi
    fi
  fi
}

strata_action_update() {
  refresh_strata_bin
  if [[ -z "$STRATA_BIN" ]]; then
    if [[ -n "$STRATA_DOCKER_CONTAINER" ]]; then
      echo -e "${C_YELLOW}Strata is running in Docker (${STRATA_DOCKER_CONTAINER}); manage its lifecycle via Docker/Unraid.${C_RESET}"
    else
      echo -e "${C_YELLOW}Strata is not installed. Run [s1] to install Strata first.${C_RESET}"
    fi
    return 0
  fi
  echo -e "${C_DIM}Checking for Strata updates...${C_RESET}"
  if check_strata_update_sync; then
    echo -e "${C_CYAN}An update is available for Strata (${STRATA_UPDATE_SUMMARY})!${C_RESET}"
    perform_strata_update
  else
    echo -e "${C_GREEN}Strata is up to date (${STRATA_VERSION:-installed}).${C_RESET}"
  fi
}

strata_action_remove() {
  refresh_strata_bin
  if [[ -z "$STRATA_BIN" ]] && ! strata_service_installed; then
    echo -e "${C_YELLOW}Strata is not installed.${C_RESET}"
    return 0
  fi
  echo -e "${C_YELLOW}This will stop any running Strata instance, uninstall strata.service (if installed), and remove ${STRATA_BIN:-the Strata binary}.${C_RESET}"
  confirm_yn "Remove Strata now? [y/N]: " "N" || return 0
  stop_strata_update_poller
  if strata_service_installed; then
    remove_service strata.service && echo -e "${C_GREEN}strata.service uninstalled.${C_RESET}"
  fi
  if [[ -n "$STRATA_BIN" ]]; then
    run_as_user_exec "$STRATA_BIN" launch --stop 2>/dev/null || true
    if [[ -w "$(dirname "$STRATA_BIN")" ]]; then
      rm -f "$STRATA_BIN"
    else
      run_root rm -f "$STRATA_BIN"
    fi
    echo -e "${C_GREEN}Removed ${STRATA_BIN}.${C_RESET}"
  fi
  STRATA_BIN="" STRATA_VERSION="" STRATA_RUNNING_PRESET="" STRATA_RUNNING_URL=""
  STRATA_UPDATE_AVAILABLE=false STRATA_UPDATE_SUMMARY=""
}

strata_action_service() {
  refresh_strata_bin
  if [[ -z "$STRATA_BIN" ]]; then
    if [[ -n "$STRATA_DOCKER_CONTAINER" ]]; then
      echo -e "${C_YELLOW}Strata is running in Docker (${STRATA_DOCKER_CONTAINER}); manage its lifecycle via Docker/Unraid.${C_RESET}"
    else
      echo -e "${C_YELLOW}Strata is not installed. Run [s1] to install Strata first.${C_RESET}"
    fi
    return 0
  fi
  if strata_service_installed; then
    echo -e "${C_GREEN}strata.service is installed ($(unit_active strata.service && echo "active" || echo "inactive")).${C_RESET}"
    echo "  1) Start / Restart strata.service"
    echo "  2) Stop strata.service"
    echo "  3) Change preset / reinstall strata.service"
    echo "  4) Uninstall strata.service"
    echo "  5) Cancel"
    local svc_choice
    read -r -p "Choose [1-5]: " svc_choice
    case "$svc_choice" in
      1)
        if service_ctl restart strata.service; then
          wait_for_strata_model_live 120
        else
          echo -e "${C_RED}Failed to start strata.service$([[ "$HAS_SYSTEMD" == true ]] && echo " (check 'journalctl -u strata -n 50')").${C_RESET}"
        fi
        ;;
      2)
        service_ctl stop strata.service && echo -e "${C_GREEN}strata.service stopped.${C_RESET}"
        ;;
      3) install_strata_service_fn ;;
      4) remove_service strata.service && echo -e "${C_GREEN}strata.service uninstalled.${C_RESET}" ;;
      5|"") ;;
      *) echo -e "${C_RED}Invalid selection '${svc_choice}'. Cancelled.${C_RESET}" ;;
    esac
  else
    local preset_count
    preset_count="$(list_strata_presets | wc -l)"
    if (( preset_count == 0 )); then
      echo -e "${C_YELLOW}No saved Strata presets found yet.${C_RESET}"
      if confirm_yn "Launch Strata interactively now ('strata launch') to create a preset? [y/N]: " "N"; then
        run_as_user_exec "$STRATA_BIN" launch
        preset_count="$(list_strata_presets | wc -l)"
      fi
    fi
    if (( preset_count > 0 )); then
      confirm_yn "Saved presets detected ($preset_count). Install strata.service? [Y/n]: " "Y" && install_strata_service_fn
    fi
  fi
}

strata_action_benchmark() {
  run_strata_benchmark
}

explain_strata_install() {
  cat <<'EOF'
Impact:
  Downloads and installs Strata (Niko1221/Strata) using the official installer
  for the current user, and starts background update checking.
EOF
  local hw_warns=""
  hw_warns="$(format_strata_hw_warnings)"
  if [[ -n "$hw_warns" ]]; then
    echo ""
    printf "%s\n" "$hw_warns"
  fi
}

explain_strata_update() {
  cat <<'EOF'
Impact:
  Checks whether a newer Strata engine/control release is available and runs
  'strata update --yes'. Stops strata.service (if active) or any running
  'strata launch' instance and waits until Strata is fully stopped before
  updating, then restarts strata.service if it was active.
EOF
  if [[ -n "$STRATA_BIN" ]]; then
    echo -e "\nInstalled: ${STRATA_VERSION:-$STRATA_BIN}"
    [[ "$STRATA_UPDATE_AVAILABLE" == true ]] && echo -e "${C_BGREEN}Update available: ${STRATA_UPDATE_SUMMARY}${C_RESET}"
  fi
}

explain_strata_remove() {
  cat <<'EOF'
Impact:
  Stops any running Strata instance, uninstalls strata.service (if present),
  and removes the Strata binary from the host. Saved launch presets and
  coupled benchmark history are preserved.
EOF
  [[ -n "$STRATA_BIN" ]] && echo -e "\nBinary: ${STRATA_BIN}"
}

explain_strata_service() {
  cat <<'EOF'
Impact:
  Configures strata.service (systemd) using a saved 'strata launch' preset
  with LimitMEMLOCK=infinity (and numactl --interleave=all when enabled).
  Lets you start, stop, restart, change preset, or uninstall the service.
EOF
  local preset_count
  preset_count="$(list_strata_presets | wc -l)"
  echo -e "\nSaved presets: ${preset_count}"
}

explain_strata_benchmark() {
  cat <<'EOF'
Impact:
  Runs Strata's built-in benchmark ('strata bench run') against the currently
  running Strata instance, measures average GPU/CPU/system power consumption,
  and stores results + active host optimizations in persistent host history.
  Tip: After a cold model load, run a warmup pass before A/B comparing host
  settings—decode throughput can ramp over the first several requests as the
  engine warms up.
EOF
  if [[ -n "$STRATA_RUNNING_URL" ]]; then
    echo -e "\nActive target: ${STRATA_RUNNING_PRESET:-active} (${STRATA_RUNNING_URL})"
  else
    echo -e "\n${C_YELLOW}Strata is not currently serving. Start strata.service or 'strata launch' first.${C_RESET}"
  fi
}

strata_action_history() {
  show_benchmark_history
}

explain_strata_history() {
  local cnt
  cnt="$(count_bench_history)"
  cat <<'EOF'
Impact:
  Lists all recorded benchmark runs with decode/prefill throughput and average
  GPU/CPU/system power consumption. Selecting any result lets you revert/apply
  the host optimizations to match what was active during that benchmark run.
EOF
  echo -e "\nRecorded benchmark results: ${cnt}"
}

_user_cache_dir() {
  if [[ -n "${XDG_CACHE_HOME:-}" && ( $EUID -ne 0 || "$TARGET_USER" == "root" ) ]]; then
    echo "${XDG_CACHE_HOME%/}"
  else
    echo "${TARGET_HOME}/.cache"
  fi
}

_is_usable_rocm_root() {
  local r="${1:-}"
  [[ -n "$r" && -d "$r" ]] || return 1
  [[ -x "$r/lib/llvm/bin/clang++" || -x "$r/llvm/bin/clang++" ]] || return 1
  [[ -d "$r/lib/cmake/hipblas" || -d "$r/lib64/cmake/hipblas" ]]
}

_resolve_rocm_root_in_dir() {
  local d="$1" sub=""
  if _is_usable_rocm_root "$d"; then
    printf '%s\n' "$d"
    return 0
  fi
  for sub in "$d"/*; do
    if [[ -d "$sub" ]] && _is_usable_rocm_root "$sub"; then
      printf '%s\n' "$sub"
      return 0
    fi
  done
  return 1
}

_detect_rocm_paths() {
  local sdk="$1" hip_clang="" hip_cc="" bitcode="" sysdeps_lib="" prefix="" ld_path="" d
  if [[ -x "$sdk/lib/llvm/bin/clang++" ]]; then
    hip_clang="$sdk/lib/llvm/bin/clang++"
    hip_cc="$sdk/lib/llvm/bin/clang"
  elif [[ -x "$sdk/llvm/bin/clang++" ]]; then
    hip_clang="$sdk/llvm/bin/clang++"
    hip_cc="$sdk/llvm/bin/clang"
  fi
  for d in "$sdk/lib/llvm/amdgcn/bitcode" "$sdk/amdgcn/bitcode" "$sdk/llvm/amdgcn/bitcode"; do
    if [[ -d "$d" ]]; then
      bitcode="$d"
      break
    fi
  done
  [[ -d "$sdk/lib/rocm_sysdeps/lib" ]] && sysdeps_lib="$sdk/lib/rocm_sysdeps/lib"
  prefix="$sdk"
  [[ -d "$sdk/lib/rocm_sysdeps" ]] && prefix+=";${sdk}/lib/rocm_sysdeps"
  [[ -d "$sdk/lib/llvm" ]] && prefix+=";${sdk}/lib/llvm"
  [[ -d "$sdk/llvm" ]] && prefix+=";${sdk}/llvm"
  for d in "$sdk/lib" "$sdk/lib64" "$sysdeps_lib" "$sdk/lib/llvm/lib" "$sdk/llvm/lib"; do
    [[ -n "$d" && -d "$d" ]] && ld_path="${ld_path:+${ld_path}:}${d}"
  done
  printf '%s|%s|%s|%s|%s|%s\n' "$hip_clang" "$hip_cc" "$bitcode" "$sysdeps_lib" "$prefix" "$ld_path"
}

_ensure_hip_build_deps() {
  local missing_cmds=() pkgs=() cmd pkg
  for cmd in git cmake ninja patchelf python3 curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || missing_cmds+=("$cmd")
  done
  if ! command -v g++ >/dev/null 2>&1 && ! command -v c++ >/dev/null 2>&1; then
    missing_cmds+=("g++")
  fi

  if (( ${#missing_cmds[@]} > 0 )); then
    case "$DISTRO_FAMILY" in
      arch|fedora|debian|suse)
        for cmd in "${missing_cmds[@]}"; do
          case "${DISTRO_FAMILY}:${cmd}" in
            arch:python3)   pkg="python" ;;
            arch:g++)       pkg="gcc" ;;
            fedora:ninja)   pkg="ninja-build" ;;
            fedora:g++)     pkg="gcc-c++" ;;
            debian:ninja)   pkg="ninja-build" ;;
            suse:g++)       pkg="gcc-c++" ;;
            *)              pkg="$cmd" ;;
          esac
          if (( ${#pkgs[@]} == 0 )) || ! _array_contains_val "$pkg" "${pkgs[@]}"; then
            pkgs+=("$pkg")
          fi
        done
        prompt_install_deps repo "${pkgs[@]}" || true
        ;;
      *)
        echo -e "${C_YELLOW}Missing build tools (automatic install unavailable on ${DISTRO_FAMILY}): ${missing_cmds[*]}${C_RESET}"
        ;;
    esac
  fi

  local still_missing=()
  for cmd in git cmake ninja patchelf python3 curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || still_missing+=("$cmd")
  done
  if ! command -v g++ >/dev/null 2>&1 && ! command -v c++ >/dev/null 2>&1; then
    still_missing+=("g++")
  fi
  if (( ${#still_missing[@]} > 0 )); then
    echo -e "${C_RED}Missing required build tools: ${still_missing[*]}${C_RESET}"
    return 1
  fi

  local cm_ver="" cm_maj=0 cm_min=0
  cm_ver="$(cmake --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
  if [[ "$cm_ver" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    cm_maj="${BASH_REMATCH[1]}"
    cm_min="${BASH_REMATCH[2]}"
    if (( cm_maj < 3 || (cm_maj == 3 && cm_min < 24) )); then
      echo -e "${C_YELLOW}[WARNING] CMake ${cm_ver} detected (< 3.24); Strata requires CMake >= 3.24 and configuration may fail.${C_RESET}"
    fi
  fi
  return 0
}

_ACQUIRED_ROCM_SDK=""
_acquire_therock_sdk() {
  local family="$1" cache_base="$2"
  _ACQUIRED_ROCM_SDK=""
  local sdk_cache="${cache_base}/rocm-therock-${family}"
  local sdk="${sdk_cache}/sdk"
  local resolved=""

  resolved="$(_resolve_rocm_root_in_dir "$sdk" || true)"
  if [[ -n "$resolved" && -f "${resolved}/.strata_extracted" ]]; then
    echo -e "${C_GREEN}Reusing cached AMD TheRock ROCm SDK (${family}) at ${resolved}.${C_RESET}"
    _ACQUIRED_ROCM_SDK="$resolved"
    return 0
  fi

  run_as_user_exec mkdir -p "$sdk_cache" || return 1
  local url="https://repo.amd.com/rocm/tarball-multi-arch/therock-dist-linux-${family}-7.14.1.tar.gz"
  if ! curl -fsIL --connect-timeout 15 "$url" >/dev/null 2>&1; then
    echo -e "${C_DIM}TheRock 7.14.1 tarball not directly at default URL; checking AMD multi-arch index for ${family}...${C_RESET}"
    local index_html="" fname=""
    index_html="$(curl -fsSL --connect-timeout 15 "https://repo.amd.com/rocm/tarball-multi-arch/" 2>/dev/null || true)"
    if [[ -n "$index_html" ]]; then
      fname="$(python3 - "$family" <<<"$index_html" <<'PY' 2>/dev/null || true
import re, sys
fam = re.escape(sys.argv[1])
html = sys.stdin.read()
hits = re.findall(rf'(therock-dist-linux-{fam}-([0-9]+(?:\.[0-9]+)*)\.tar\.gz)', html)
best = None
for fname, ver in hits:
    if "-tests-" in fname:
        continue
    key = tuple(int(x) for x in ver.split("."))
    if best is None or key > best[0]:
        best = (key, fname)
if best:
    print(best[1])
PY
)"
    fi
    if [[ -z "$fname" ]]; then
      echo -e "${C_RED}Could not locate an AMD TheRock Linux tarball for family '${family}'.${C_RESET}"
      return 1
    fi
    url="https://repo.amd.com/rocm/tarball-multi-arch/${fname}"
  fi

  local tarball="${sdk_cache}/$(basename "$url")"
  echo -e "${C_CYAN}Downloading AMD TheRock ROCm SDK (${family}): ${url}${C_RESET}"
  echo -e "${C_DIM}This archive is ~1.7 GB and extracts to ~8 GB; downloads resume automatically if interrupted.${C_RESET}"
  if ! run_as_user_exec curl -fL --connect-timeout 15 --retry 3 -C - -o "$tarball" "$url"; then
    run_as_user_exec rm -f "$tarball"
    run_as_user_exec curl -fL --connect-timeout 15 --retry 3 -o "$tarball" "$url" || {
      echo -e "${C_RED}Failed to download ${url}.${C_RESET}"
      return 1
    }
  fi

  echo -e "${C_CYAN}Extracting TheRock ROCm SDK into ${sdk}...${C_RESET}"
  run_as_user_exec rm -rf "$sdk"
  run_as_user_exec mkdir -p "$sdk"
  if ! run_as_user_exec tar -xzf "$tarball" -C "$sdk"; then
    echo -e "${C_RED}Failed to extract ${tarball} (corrupt or incomplete archive); cleaning up cached files.${C_RESET}"
    run_as_user_exec rm -rf "$tarball" "$sdk"
    return 1
  fi

  resolved="$(_resolve_rocm_root_in_dir "$sdk" || true)"
  if [[ -n "$resolved" ]]; then
    sdk="$resolved"
  else
    echo -e "${C_RED}Extracted ROCm directory at ${sdk} does not appear to contain clang++ and hipblas.${C_RESET}"
    run_as_user_exec rm -rf "$sdk"
    return 1
  fi

  run_as_user_exec touch "${sdk}/.strata_extracted"
  _ACQUIRED_ROCM_SDK="$sdk"
  return 0
}

_PREPARED_STRATA_COMMIT=""
_prepare_strata_source() {
  local src_dir="$1" is_wave32="$2"; shift 2
  local targets=("$@")
  _PREPARED_STRATA_COMMIT="unknown"

  if [[ -d "${src_dir}/.git" ]]; then
    echo -e "${C_CYAN}Updating Strata source checkout at ${src_dir}...${C_RESET}"
    if ! ( run_as_user_exec git -C "$src_dir" fetch --depth 1 origin main && run_as_user_exec git -C "$src_dir" reset --hard origin/main ); then
      echo -e "${C_YELLOW}Existing checkout update failed; re-cloning cleanly...${C_RESET}"
      run_as_user_exec rm -rf "$src_dir"
    fi
  fi

  if [[ ! -d "${src_dir}/.git" ]]; then
    echo -e "${C_CYAN}Cloning https://github.com/Niko1221/Strata.git (shallow) into ${src_dir}...${C_RESET}"
    run_as_user_exec mkdir -p "$(dirname "$src_dir")"
    run_as_user_exec git clone --depth 1 https://github.com/Niko1221/Strata.git "$src_dir" || return 1
  fi

  _PREPARED_STRATA_COMMIT="$(run_as_user_exec git -C "$src_dir" rev-parse --short=9 HEAD 2>/dev/null || echo "unknown")"

  if [[ "$is_wave32" == true ]]; then
    local hip_cmake=""
    if [[ -f "${src_dir}/engine/cmake/hip_backend.cmake" ]]; then
      hip_cmake="${src_dir}/engine/cmake/hip_backend.cmake"
    elif [[ -f "${src_dir}/cmake/hip_backend.cmake" ]]; then
      hip_cmake="${src_dir}/cmake/hip_backend.cmake"
    fi
    if [[ -n "$hip_cmake" ]]; then
      local patch_msg=""
      patch_msg="$(run_as_user_exec python3 - "$hip_cmake" "${targets[@]}" <<'PY'
import re, sys

path = sys.argv[1]
targets = sys.argv[2:]
with open(path, encoding="utf-8") as f:
    text = f.read()

present = set()
for var in ("_strata_hip_validated", "_strata_hip_community", "_strata_hip_unvalidated"):
    m = re.search(rf'set\({var}\s+([^\)]+)\)', text, re.DOTALL)
    if m:
        present.update(re.findall(r'\bgfx[0-9a-f]+\b', m.group(1).lower()))

missing = [t for t in targets if t not in present]
if not missing:
    sys.exit(0)

m = re.search(r'(set\(_strata_hip_unvalidated\s+)([^\)]+)(\))', text, re.DOTALL)
if not m:
    print("WARN: could not locate _strata_hip_unvalidated in " + path)
    sys.exit(0)

suffix = "\n" if "\n" in m.group(2) else ""
updated = text[:m.start(2)] + m.group(2).rstrip() + " " + " ".join(missing) + suffix + text[m.end(2):]
with open(path, "w", encoding="utf-8") as f:
    f.write(updated)
print("PATCHED:" + ",".join(missing))
PY
)"
      if [[ "$patch_msg" == PATCHED:* ]]; then
        echo -e "${C_CYAN}Applied Issue #1217-style CMake patch in ${hip_cmake}: added ${patch_msg#PATCHED:} to _strata_hip_unvalidated.${C_RESET}"
      elif [[ -n "$patch_msg" ]]; then
        echo -e "${C_YELLOW}${patch_msg}${C_RESET}"
      fi
    fi
  fi
  return 0
}

_STRATA_WAS_ACTIVE=false
_STRATA_WAS_LAUNCH=false
_stop_strata_if_running() {
  _STRATA_WAS_ACTIVE=false
  _STRATA_WAS_LAUNCH=false
  unit_active strata.service && _STRATA_WAS_ACTIVE=true
  if [[ "$_STRATA_WAS_ACTIVE" == true ]]; then
    echo -e "${C_CYAN}Stopping strata.service before updating component files...${C_RESET}"
    service_ctl stop strata.service || true
    wait_for_strata_stopped 60 || return 1
  else
    refresh_strata_running
    if [[ -n "$STRATA_RUNNING_PRESET" && -n "$STRATA_BIN" ]]; then
      _STRATA_WAS_LAUNCH=true
      echo -e "${C_CYAN}Stopping Strata ('strata launch --stop') before updating component files...${C_RESET}"
      run_as_user_exec "$STRATA_BIN" launch --stop || true
      wait_for_strata_stopped 60 || return 1
    fi
  fi
  return 0
}

_print_local_hip_post_install_notes() {
  local comma_archs="$1" installed_path="$2" has_tuning="$3" noted=false
  echo -e "\n${C_BOLD}Next Steps & Hardware Notes:${C_RESET}"
  echo -e "  Installed component: ${C_CYAN}${installed_path}${C_RESET}"
  if [[ ",${comma_archs}," == *",gfx1150,"* ]]; then
    noted=true
    echo -e "  - Launch Strata with: ${C_BOLD}STRATA_EXPERIMENTAL_GFX1150=1 strata launch${C_RESET}"
    echo -e "    (Note: strata.service & wizard CLI calls automatically export STRATA_EXPERIMENTAL_GFX1150=1.)"
    echo -e "  - Apply ${C_BOLD}amd_apu_memory${C_RESET} (ttm.pages_limit) & ${C_BOLD}gpu_groups${C_RESET} (render/video) from the main index."
    if [[ "$has_tuning" == true ]]; then
      echo -e "  - Optional prompt speedup: set ${C_BOLD}STRATA_HIPBLASLT_TABLE=on${C_RESET} (matching gfx1150 table was staged)."
    fi
  fi
  if [[ ",${comma_archs}," == *",gfx1103,"* ]]; then
    noted=true
    echo -e "  - Launch Strata with: ${C_BOLD}STRATA_EXPERIMENTAL_GFX1103=1 strata launch${C_RESET}"
    echo -e "    (Note: strata.service & wizard CLI calls automatically export STRATA_EXPERIMENTAL_GFX1103=1.)"
    echo -e "  - Apply ${C_BOLD}amd_apu_memory${C_RESET}, ${C_BOLD}amd_cwsr_disable${C_RESET} (amdgpu.cwsr_enable=0, stops MES GPU resets), and ${C_BOLD}gpu_groups${C_RESET}."
    if [[ "$has_tuning" == true ]]; then
      echo -e "  - Optional prompt speedup: set ${C_BOLD}STRATA_HIPBLASLT_TABLE=on${C_RESET} (matching gfx1103 table was staged)."
    fi
  fi
  if [[ "$noted" == false ]]; then
    echo -e "  - Verify registered engine with: ${C_BOLD}strata components engines${C_RESET}"
    echo -e "  - Upstream setup.py does not yet list ${comma_archs} in AMD_ARCHS; you can also invoke"
    echo -e "    ${installed_path}/strata directly or via terminal/serve/server.py (see Strata docs/AMD_HIP.md & docs/OLDER_GPUS.md)."
  fi
}

explain_strata_build_hip() {
  cat <<'EOF'
Impact:
  Builds and registers a self-contained local Strata HIP engine package for AMD
  architectures that lack an official prebuilt Linux release (such as gfx1150
  Strix Point / Radeon 890M, gfx1103 Radeon 780M, gfx1152 Krackan, gfx1153,
  RDNA1 gfx1010/1011/1012, gfx1034, or wave64 Instinct MI50/MI60/MI100/MI210/
  MI250X/MI300X/MI350X).

  Workflow:
    1. Acquires AMD's TheRock ROCm SDK (or uses a compatible system /opt/rocm)
    2. Clones/updates Niko1221/Strata and patches cmake/hip_backend.cmake if needed
    3. Compiles strata (and best-effort vision readers) with Ninja & clang++
    4. Bundles ROCm runtime libraries + matching hipBLASLt tuning tables,
       verifies package integrity, installs under Strata's components folder,
       and activates it with 'strata components use'
EOF
  local info=""
  info="$(strata_local_hip_engine_info --any-local)"
  if [[ -n "$info" ]]; then
    local fn ver archs
    IFS='|' read -r fn ver archs _ <<< "$info"
    echo -e "\nInstalled local/matching HIP engine: ${C_GREEN}${fn}${C_RESET} (v${ver}, archs: ${archs})"
  fi
  if amd_missing_has_gfx "gfx1150"; then
    echo -e "Opt-in wiring: ${C_DIM}STRATA_EXPERIMENTAL_GFX1150=1 will be set automatically for wizard/service runs.${C_RESET}"
  fi
  if amd_missing_has_gfx "gfx1103"; then
    echo -e "Opt-in wiring: ${C_DIM}STRATA_EXPERIMENTAL_GFX1103=1 will be set automatically for wizard/service runs.${C_RESET}"
  fi
}

strata_action_build_hip() {
  refresh_strata_bin
  local arch_m=""
  arch_m="$(uname -m 2>/dev/null || echo unknown)"
  if [[ "$arch_m" != "x86_64" && "$arch_m" != "amd64" ]]; then
    echo -e "${C_RED}Local AMD HIP builds require Linux x86_64 (detected: ${arch_m}).${C_RESET}"
    return 1
  fi

  local existing=""
  existing="$(strata_local_hip_engine_info --any-local)"
  if [[ -n "$existing" ]]; then
    local ex_folder ex_ver ex_archs ex_cov
    IFS='|' read -r ex_folder ex_ver ex_archs ex_cov <<< "$existing"
    echo -e "${C_GREEN}Found local/matching HIP engine package: ${C_BOLD}${ex_folder}${C_RESET} (v${ex_ver}, archs: ${ex_archs})"
    echo "  1) Rebuild / update local HIP engine from latest Niko1221/Strata source"
    echo "  2) Activate / pin this local HIP engine (strata components use)"
    echo "  3) Remove this local HIP engine package"
    echo "  4) Cancel"
    local mchoice=""
    read -r -p "Choose [1-4]: " mchoice
    case "$mchoice" in
      1) ;;
      2)
        if [[ -z "$STRATA_BIN" ]]; then
          echo -e "${C_YELLOW}Strata CLI is not installed yet; install Strata first via [s1].${C_RESET}"
          return 1
        fi
        run_as_user_exec "$STRATA_BIN" components use "$ex_folder" && echo -e "${C_GREEN}Activated ${ex_folder}.${C_RESET}"
        return $?
        ;;
      3)
        confirm_yn "Remove local HIP engine package '${ex_folder}'? [y/N]: " "N" || return 0
        stop_strata_update_poller
        _stop_strata_if_running || { start_strata_update_poller; return 1; }
        if [[ -n "$STRATA_BIN" ]]; then
          run_as_user_exec "$STRATA_BIN" components use newest >/dev/null 2>&1 || true
          run_as_user_exec "$STRATA_BIN" components remove "$ex_folder" >/dev/null 2>&1 || true
        fi
        local target_rm=""
        if [[ -n "$ex_folder" && "$ex_folder" != */* && "$ex_folder" != "." && "$ex_folder" != ".." ]]; then
          target_rm="$(strata_components_engine_dir)/${ex_folder}"
          if [[ -d "$target_rm" ]]; then
            run_as_user_exec rm -rf "$target_rm" 2>/dev/null || run_root rm -rf "$target_rm"
          fi
        fi
        invalidate_local_hip_engine_cache
        echo -e "${C_GREEN}Removed ${ex_folder}.${C_RESET}"
        start_strata_update_poller
        return 0
        ;;
      4|"") return 0 ;;
      *) echo -e "${C_RED}Invalid selection '${mchoice}'. Cancelled.${C_RESET}"; return 1 ;;
    esac
  fi

  local -a targets=("${AMD_MISSING_GFX_ARCHS[@]+"${AMD_MISSING_GFX_ARCHS[@]}"}")
  if (( ${#targets[@]} == 0 )); then
    local raw_arch="" tok=""
    read -r -p "Enter target AMD gfx architecture(s) (e.g. gfx1150 or gfx1150;gfx1103): " raw_arch
    for tok in ${raw_arch//[;,]/ }; do
      tok="${tok,,}"
      if [[ "$tok" =~ ^gfx[0-9a-f]+$ ]]; then
        if (( ${#targets[@]} == 0 )) || ! _array_contains_val "$tok" "${targets[@]}"; then
          targets+=("$tok")
        fi
      elif [[ -n "$tok" ]]; then
        echo -e "${C_RED}Invalid gfx target '${tok}'.${C_RESET}"
        return 1
      fi
    done
    (( ${#targets[@]} > 0 )) || { echo -e "${C_YELLOW}No target architecture specified. Cancelled.${C_RESET}"; return 0; }
  fi

  local -a wave64_tgts=() wave32_tgts=()
  local _wt=""
  for _wt in "${targets[@]}"; do
    if amd_gfx_is_wave64 "$_wt"; then
      wave64_tgts+=("$_wt")
    else
      wave32_tgts+=("$_wt")
    fi
  done
  if (( ${#wave64_tgts[@]} > 0 && ${#wave32_tgts[@]} > 0 )); then
    echo -e "${C_YELLOW}Wave64 targets (${wave64_tgts[*]}) cannot be combined with wave32 targets (${wave32_tgts[*]}) in one Strata binary.${C_RESET}"
    echo "  1) Build for wave32 targets only (${wave32_tgts[*]})"
    echo "  2) Build for wave64 targets only (${wave64_tgts[*]})"
    local wchoice=""
    read -r -p "Choose [1-2]: " wchoice
    case "$wchoice" in
      1) targets=("${wave32_tgts[@]}") ;;
      2) targets=("${wave64_tgts[@]}") ;;
      *) echo -e "${C_YELLOW}Cancelled.${C_RESET}"; return 0 ;;
    esac
  fi
  if _array_contains_val "gfx906" "${targets[@]}" && (( ${#targets[@]} > 1 )); then
    echo -e "${C_YELLOW}gfx906 uses dedicated -DSTRATA_HIP_GFX906=ON flags and cannot combine with other wave64 targets.${C_RESET}"
    local -a non906=()
    for _wt in "${targets[@]}"; do [[ "$_wt" != "gfx906" ]] && non906+=("$_wt"); done
    echo "  1) Build for gfx906 only"
    echo "  2) Build for ${non906[*]} only"
    local g9choice=""
    read -r -p "Choose [1-2]: " g9choice
    case "$g9choice" in
      1) targets=("gfx906") ;;
      2) targets=("${non906[@]}") ;;
      *) echo -e "${C_YELLOW}Cancelled.${C_RESET}"; return 0 ;;
    esac
  fi

  local is_gfx906=false is_wave32=true
  [[ "${targets[0]}" == "gfx906" ]] && is_gfx906=true
  amd_gfx_is_wave64 "${targets[0]}" && is_wave32=false

  if [[ -z "$existing" ]]; then
    local tgt_desc="" t=""
    for t in "${targets[@]}"; do
      tgt_desc="${tgt_desc:+${tgt_desc}, }${t} ($(amd_gfx_label "$t"))"
    done
    echo -e "${C_BOLD}Local Strata HIP Engine Build Summary:${C_RESET}"
    echo -e "  Target(s):       ${C_CYAN}${tgt_desc}${C_RESET}"
    echo -e "  Disk space:      ${C_DIM}~10-15 GB temporary build/ROCm cache; ~150-400 MB installed package${C_RESET}"
    confirm_yn "Proceed with building local Strata HIP engine for ${targets[*]}? [Y/n]: " "Y" || return 0
  fi

  if [[ -z "$STRATA_BIN" ]]; then
    echo -e "${C_YELLOW}Strata CLI is not installed yet.${C_RESET}"
    if confirm_yn "Install Strata Terminal first before building the local HIP engine? [Y/n]: " "Y"; then
      command -v curl >/dev/null 2>&1 || prompt_install_deps repo curl || return 1
      run_as_user "curl -fsSL https://github.com/Niko1221/Strata/releases/latest/download/install.sh | sh"
      refresh_strata_bin
      [[ -n "$STRATA_BIN" && -z "$STRATA_POLLER_PID" ]] && start_strata_update_poller
    fi
  fi

  _ensure_hip_build_deps || return 1

  local cache_base sdk="" sys_rocm="${ROCM_PATH:-/opt/rocm}"
  local -a extra_sdks=() therock_cache_dirs=()
  cache_base="$(_user_cache_dir)/strata-performance-setup"
  run_as_user_exec mkdir -p "$cache_base" || return 1

  if [[ "$is_gfx906" == true ]]; then
    if _is_usable_rocm_root "$sys_rocm"; then
      echo -e "${C_GREEN}Using ROCm toolchain at ${sys_rocm} for gfx906.${C_RESET}"
      sdk="$sys_rocm"
    else
      echo -e "${C_YELLOW}AMD's TheRock 7.x tarballs do not support gfx906 (wave64).${C_RESET}"
      echo -e "Please build inside a ROCm 6.x / community gfx906 environment (e.g. ${C_BOLD}mixa3607/rocm-gfx906:7.14-complete${C_RESET}),"
      echo -e "or set ${C_BOLD}ROCM_PATH${C_RESET} to a compatible gfx906 ROCm root (see Strata's ${C_DIM}docs/AMD_HIP.md${C_RESET})."
      return 1
    fi
  else
    local -a therock_families=()
    local fam="" t="" use_therock=false
    for t in "${targets[@]}"; do
      fam="$(amd_gfx_therock_family "$t" || true)"
      if [[ -n "$fam" ]] && { (( ${#therock_families[@]} == 0 )) || ! _array_contains_val "$fam" "${therock_families[@]}"; }; then
        therock_families+=("$fam")
      fi
    done

    if (( ${#therock_families[@]} == 0 )); then
      if _is_usable_rocm_root "$sys_rocm"; then
        echo -e "${C_GREEN}Using system ROCm toolchain at ${sys_rocm} for ${targets[*]}.${C_RESET}"
        sdk="$sys_rocm"
      else
        echo -e "${C_RED}No AMD TheRock tarball family known for '${targets[0]}' and no usable ROCm at ${sys_rocm}.${C_RESET}"
        echo -e "Install ROCm (or set ${C_BOLD}ROCM_PATH${C_RESET} to your ROCm root) and re-run."
        return 1
      fi
    elif _is_usable_rocm_root "$sys_rocm"; then
      echo -e "\n${C_BOLD}Select ROCm toolchain for building (${targets[*]}):${C_RESET}"
      echo "  1) AMD TheRock 7.14.1 tarball (Recommended — matches shipped hipBLASLt 100401 tuning tables)"
      echo "  2) Existing system ROCm at ${sys_rocm}"
      local rchoice=""
      read -r -p "Choose [1-2, default 1]: " rchoice
      if [[ "$rchoice" == "2" ]]; then
        sdk="$sys_rocm"
      else
        use_therock=true
      fi
    else
      use_therock=true
    fi

    if [[ "$use_therock" == true ]]; then
      _acquire_therock_sdk "${therock_families[0]}" "$cache_base" || return 1
      sdk="$_ACQUIRED_ROCM_SDK"
      therock_cache_dirs+=("${cache_base}/rocm-therock-${therock_families[0]}")
      local fi_idx
      for (( fi_idx = 1; fi_idx < ${#therock_families[@]}; fi_idx++ )); do
        fam="${therock_families[$fi_idx]}"
        _acquire_therock_sdk "$fam" "$cache_base" || return 1
        extra_sdks+=("$_ACQUIRED_ROCM_SDK")
        therock_cache_dirs+=("${cache_base}/rocm-therock-${fam}")
      done
    fi
  fi

  local hip_clang="" hip_cc="" bitcode="" sysdeps_lib="" prefix_path="" sdk_ld_path=""
  IFS='|' read -r hip_clang hip_cc bitcode sysdeps_lib prefix_path sdk_ld_path <<< "$(_detect_rocm_paths "$sdk")"
  if [[ -z "$hip_clang" || ! -x "$hip_clang" ]]; then
    echo -e "${C_RED}HIP clang++ compiler not found under ${sdk}.${C_RESET}"
    return 1
  fi

  local src_dir="${cache_base}/Strata-src"
  local patch_hip_cmake=true
  [[ "$is_gfx906" == true ]] && patch_hip_cmake=false
  _prepare_strata_source "$src_dir" "$patch_hip_cmake" "${targets[@]}" || return 1
  local commit="$_PREPARED_STRATA_COMMIT"

  local jobs=4 ram_cap=4
  jobs="$(nproc 2>/dev/null || echo 4)"
  if [[ "$RAM_GB" =~ ^[0-9]+$ ]] && (( RAM_GB > 0 )); then
    ram_cap=$(( RAM_GB / 3 ))
    (( ram_cap < 2 )) && ram_cap=2
    (( jobs > ram_cap )) && jobs="$ram_cap"
  fi

  local cmake_archs="" data_archs="" space_archs=""
  {
    local IFS=';'
    cmake_archs="${targets[*]}"
  }
  {
    local IFS=','
    data_archs="${targets[*]}"
  }
  space_archs="${targets[*]}"

  local bdir="${cache_base}/build-hip-${targets[0]}"
  local stage="${bdir}/stage"
  local pkg_out="${bdir}/pkg_out"
  run_as_user_exec rm -rf "$bdir"
  run_as_user_exec mkdir -p "$bdir/engine" "$stage" "$pkg_out"

  local llvm_bin_dir
  llvm_bin_dir="$(dirname "$hip_clang")"
  local -a build_env=(
    "ROCM_PATH=${sdk}"
    "HIP_PATH=${sdk}"
    "HIP_PLATFORM=amd"
    "HIP_COMPILER=clang"
    "HIP_RUNTIME=rocclr"
    "PATH=${sdk}/bin:${llvm_bin_dir}:${PATH}"
    "LD_LIBRARY_PATH=${sdk_ld_path}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  )
  local hip_flag_str="-isystem ${sdk}/include --rocm-path=${sdk}"
  [[ -n "$bitcode" ]] && hip_flag_str+=" --rocm-device-lib-path=${bitcode}"

  echo -e "\n${C_CYAN}Configuring Strata engine for ${cmake_archs} (jobs=${jobs})...${C_RESET}"
  if [[ "$is_gfx906" == false ]]; then
    run_as_user_exec env "${build_env[@]}" cmake -G Ninja -S "${src_dir}/engine" -B "${bdir}/engine" \
      -DCMAKE_BUILD_TYPE=Release \
      -DSTRATA_ENABLE_HIP=ON \
      -DSTRATA_ENABLE_CUDA=OFF \
      -DSTRATA_BUILD_TESTS=OFF \
      -DSTRATA_PORTABLE=ON \
      "-DCMAKE_HIP_ARCHITECTURES=${cmake_archs}" \
      "-DCMAKE_HIP_COMPILER=${hip_clang}" \
      "-DCMAKE_HIP_COMPILER_ROCM_ROOT=${sdk}" \
      "-DCMAKE_PREFIX_PATH=${prefix_path}" \
      "-DCMAKE_HIP_FLAGS=${hip_flag_str}" \
      "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-rpath,'\$ORIGIN' -Wl,--enable-new-dtags" || {
      echo -e "${C_RED}CMake configuration failed for Strata HIP engine.${C_RESET}"
      return 1
    }
  else
    run_as_user_exec env "${build_env[@]}" cmake -G Ninja -S "${src_dir}/engine" -B "${bdir}/engine" \
      -DCMAKE_BUILD_TYPE=Release \
      -DSTRATA_HIP_GFX906=ON \
      -DCMAKE_HIP_ARCHITECTURES=gfx906 \
      -DSTRATA_BUILD_TESTS=OFF \
      -DSTRATA_PORTABLE=ON \
      "-DCMAKE_C_COMPILER=${hip_cc}" \
      "-DCMAKE_CXX_COMPILER=${hip_clang}" \
      "-DCMAKE_PREFIX_PATH=${prefix_path}" \
      "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-rpath,'\$ORIGIN' -Wl,--enable-new-dtags" || {
      echo -e "${C_RED}CMake configuration failed for Strata gfx906 engine.${C_RESET}"
      return 1
    }
  fi

  echo -e "${C_CYAN}Compiling Strata engine (this may take 10-20 minutes)...${C_RESET}"
  run_as_user_exec env "${build_env[@]}" cmake --build "${bdir}/engine" --target strata -j "$jobs" || {
    echo -e "${C_RED}Strata engine build failed.${C_RESET}"
    return 1
  }
  [[ -x "${bdir}/engine/strata" ]] || { echo -e "${C_RED}Built binary missing at ${bdir}/engine/strata.${C_RESET}"; return 1; }

  # Best-effort picture readers (failures never abort engine registration)
  local has_cpu_vis=false has_gpu_vis=false
  if [[ -f "${src_dir}/terminal/tools/vision/CMakeLists.txt" ]]; then
    echo -e "${C_CYAN}Building optional CPU picture reader (strata-vision)...${C_RESET}"
    if run_as_user_exec env "${build_env[@]}" cmake -G Ninja -S "${src_dir}/terminal/tools/vision" -B "${bdir}/bv" \
         -DCMAKE_BUILD_TYPE=Release -DSTRATA_VISION_CUDA=OFF -DSTRATA_PORTABLE=ON >/dev/null 2>&1 && \
       run_as_user_exec env "${build_env[@]}" cmake --build "${bdir}/bv" --target strata-vision -j "$jobs" >/dev/null 2>&1 && \
       [[ -x "${bdir}/bv/bin/strata-vision" ]]; then
      has_cpu_vis=true
    else
      echo -e "${C_YELLOW}Note: CPU picture reader build skipped/failed (text inference unaffected).${C_RESET}"
    fi
    if [[ "$is_wave32" == true ]]; then
      echo -e "${C_CYAN}Building optional HIP GPU picture reader (strata-vision-hip)...${C_RESET}"
      if run_as_user_exec env "${build_env[@]}" cmake -G Ninja -S "${src_dir}/terminal/tools/vision" -B "${bdir}/bh" \
           -DCMAKE_BUILD_TYPE=Release -DSTRATA_VISION_HIP=ON \
           "-DSTRATA_VISION_HIP_ARCHS=${cmake_archs}" -DSTRATA_PORTABLE=ON \
           "-DCMAKE_HIP_COMPILER=${hip_clang}" \
           "-DCMAKE_HIP_COMPILER_ROCM_ROOT=${sdk}" \
           "-DCMAKE_PREFIX_PATH=${prefix_path}" \
           "-DCMAKE_HIP_FLAGS=${hip_flag_str}" >/dev/null 2>&1 && \
         run_as_user_exec env "${build_env[@]}" cmake --build "${bdir}/bh" --target strata-vision -j "$jobs" >/dev/null 2>&1 && \
         [[ -x "${bdir}/bh/bin/strata-vision-hip" ]]; then
        has_gpu_vis=true
      else
        echo -e "${C_YELLOW}Note: GPU picture reader build skipped/failed (CPU reader / text unaffected).${C_RESET}"
      fi
    fi
  fi

  local eng_ver="" raw_ver=""
  raw_ver="$(run_as_user_exec env "LD_LIBRARY_PATH=${sdk_ld_path}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" "${bdir}/engine/strata" --version 2>/dev/null || true)"
  eng_ver="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$raw_ver" | head -n1 || true)"
  if [[ -z "$eng_ver" && -f "${src_dir}/engine/CMakeLists.txt" ]]; then
    eng_ver="$(sed -nE 's/^[[:space:]]*project\(strata[[:space:]]+VERSION[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)*).*/\1/p' "${src_dir}/engine/CMakeLists.txt" | head -n1 || true)"
  fi
  [[ -n "$eng_ver" ]] || eng_ver="0.1.0"

  local variant="local-${targets[0]}"
  local vision_mode="none"
  [[ "$has_cpu_vis" == true ]] && vision_mode="cpu"
  [[ "$has_gpu_vis" == true ]] && vision_mode="gpu"

  run_as_user_exec python3 - "${stage}/BUILD.json" "$eng_ver" "$commit" "$variant" "$vision_mode" "${targets[@]}" <<'PY'
import json, sys
out, ver, commit, variant, vis, *archs = sys.argv[1:]
d = {"version": ver, "source": f"local-hip {commit}", "backend": "hip", "variant": variant,
     "archs": archs, "portable": True, "vision": vis}
if vis in ("cpu", "gpu"):
    d["vision_cpu"] = "strata-vision"
if vis == "gpu":
    d["vision_gpu"] = "strata-vision-hip"
    d["vision_archs"] = archs
with open(out, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=1)
    f.write("\n")
PY

  # Collect shared libraries and ROCm kernel data
  echo -e "${C_CYAN}Collecting ROCm runtime libraries & kernel data...${C_RESET}"
  local -a collect_search=() collect_data=() data_sdks=("$sdk")
  (( ${#extra_sdks[@]} > 0 )) && data_sdks+=("${extra_sdks[@]}")
  local sdir sdk_item=""
  for sdir in "$sdk/lib" "$sdk/lib64" "$sysdeps_lib" "$sdk/lib/llvm/lib" "$sdk/llvm/lib"; do
    [[ -n "$sdir" && -d "$sdir" ]] && collect_search+=(--search "$sdir")
  done
  for sdk_item in "${data_sdks[@]}"; do
    for sdir in "$sdk_item/lib/rocblas/library" "$sdk_item/lib64/rocblas/library" "$sdk_item/rocblas/lib/library"; do
      if [[ -d "$sdir" ]]; then
        collect_data+=(--data "${sdir}=rocblas/library")
        break
      fi
    done
    for sdir in "$sdk_item/lib/hipblaslt/library" "$sdk_item/lib64/hipblaslt/library" "$sdk_item/hipblaslt/lib/library"; do
      if [[ -d "$sdir" ]]; then
        collect_data+=(--data "${sdir}=hipblaslt/library")
        break
      fi
    done
  done

  run_as_user_exec python3 "${src_dir}/tools/packaging/collect_libs.py" \
    --binary "${bdir}/engine/strata" \
    "${collect_search[@]}" \
    --also 'libamd_comgr.so*' --also 'libhiprtc*.so*' \
    --out "$stage" \
    ${collect_data[@]+"${collect_data[@]}"} --data-arch "$data_archs" || {
    echo -e "${C_RED}collect_libs.py failed.${C_RESET}"
    return 1
  }

  if [[ "$has_gpu_vis" == true ]]; then
    run_as_user_exec python3 "${src_dir}/tools/packaging/collect_libs.py" \
      --binary "${bdir}/bh/bin/strata-vision-hip" \
      "${collect_search[@]}" \
      --also 'libamd_comgr.so*' --also 'libhiprtc*.so*' \
      --out "$stage" || true
  fi

  # ROCm 10.x kpack archives if present
  local ka="" kpack_made=false
  for sdk_item in "${data_sdks[@]}"; do
    if [[ -d "${sdk_item}/.kpack" ]]; then
      if [[ "$kpack_made" == false ]]; then
        run_as_user_exec mkdir -p "${stage}/kpack"
        kpack_made=true
      fi
      for ka in "${targets[@]}"; do
        [[ -f "${sdk_item}/.kpack/blas_lib_${ka}.kpack" ]] && run_as_user_exec cp "${sdk_item}/.kpack/blas_lib_${ka}.kpack" "${stage}/kpack/"
      done
    fi
  done

  run_as_user_exec cp "${bdir}/engine/strata" "${stage}/strata"
  [[ "$has_cpu_vis" == true ]] && run_as_user_exec cp "${bdir}/bv/bin/strata-vision" "${stage}/strata-vision"
  [[ "$has_gpu_vis" == true ]] && run_as_user_exec cp "${bdir}/bh/bin/strata-vision-hip" "${stage}/strata-vision-hip"

  run_as_user_exec sh -c 'for f in "$1"/*.so "$1"/*.so.* "$1/strata" "$1/strata-vision" "$1/strata-vision-hip"; do [ -f "$f" ] && [ ! -L "$f" ] && patchelf --set-rpath '\''$ORIGIN'\'' "$f" 2>/dev/null || true; done' _ "$stage"

  # Stage matching hipBLASLt tuning tables or set fallback hipblaslt_version
  local hbl_ver="" has_tuning=false
  if [[ -f "${sdk}/include/hipblaslt/hipblaslt-version.h" ]]; then
    run_as_user_exec python3 "${src_dir}/tools/packaging/stage_tuning.py" \
      --stage "$stage" --archs "$space_archs" --rocm "$sdk" || true
  elif [[ -f "${sdk}/hipblaslt/include/hipblaslt/hipblaslt-version.h" ]]; then
    hbl_ver="$(python3 - "${sdk}/hipblaslt/include/hipblaslt/hipblaslt-version.h" <<'PY' 2>/dev/null || true
import re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    t = f.read()
vals = []
for k in ("MAJOR", "MINOR", "PATCH"):
    m = re.search(rf"#define\s+HIPBLASLT_VERSION_{k}\s+(\d+)", t)
    if not m:
        sys.exit(0)
    vals.append(int(m.group(1)))
print(vals[0]*100000 + vals[1]*100 + vals[2])
PY
)"
    if [[ "$hbl_ver" =~ ^[0-9]+$ ]]; then
      run_as_user_exec python3 "${src_dir}/tools/packaging/stage_tuning.py" \
        --stage "$stage" --archs "$space_archs" --version "$hbl_ver" || true
    fi
  fi
  if ! grep -q '"hipblaslt_version"' "${stage}/BUILD.json" 2>/dev/null; then
    run_as_user_exec python3 - "${stage}/BUILD.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as f:
    d = json.load(f)
d["hipblaslt_version"] = 1
with open(p, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=1)
    f.write("\n")
PY
  fi
  compgen -G "${stage}/tuning/*.txt" >/dev/null 2>&1 && has_tuning=true

  # Package and verify component
  local -a pkg_args=(
    --src "$stage"
    --backend hip
    --version "$eng_ver"
    --out "$pkg_out"
    --variant "$variant"
    --build-id "${commit}+local-rocm"
    --notes "Local HIP build for ${data_archs} via strata-performance-setup"
    --tree
  )
  local t=""
  for t in "${targets[@]}"; do pkg_args+=(--arch "$t"); done
  if [[ -r "${stage}/SYSTEM-LIBS.txt" ]]; then
    local slib=""
    while IFS= read -r slib; do
      [[ -n "$slib" ]] && pkg_args+=(--allow-lib "$slib")
    done < "${stage}/SYSTEM-LIBS.txt"
  fi

  echo -e "${C_CYAN}Packaging and verifying Strata HIP engine component...${C_RESET}"
  run_as_user_exec python3 "${src_dir}/tools/packaging/package_engine.py" "${pkg_args[@]}" || {
    echo -e "${C_RED}package_engine.py failed.${C_RESET}"
    return 1
  }

  local pkg_dir="" pkg_folder_name=""
  pkg_dir="$(find "$pkg_out" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
  [[ -n "$pkg_dir" && -f "${pkg_dir}/engine-component.json" ]] || {
    echo -e "${C_RED}Packaged folder not found in ${pkg_out}.${C_RESET}"
    return 1
  }
  pkg_folder_name="$(basename "$pkg_dir")"

  run_as_user_exec python3 - "${src_dir}/terminal" "$pkg_dir" <<'PY' || { echo -e "${C_RED}Package integrity verification failed for ${pkg_dir}.${C_RESET}"; return 1; }
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from strata_control import engine_component as ec
c = ec.read_manifest_any(Path(sys.argv[2]))
ec.verify(c, full=True)
print(f"Verified manifest integrity: {c.root.name} ({len(c.files)} files)")
PY
  if ! run_as_user_exec python3 "${src_dir}/tools/packaging/package_engine.py" --verify "$pkg_dir" >/dev/null 2>&1; then
    echo -e "${C_DIM}Note: standalone binary_deps check flagged host system libraries listed in SYSTEM-LIBS.txt (allowed for local-host install).${C_RESET}"
  fi

  # Install into Strata components/engine atomically
  local comp_eng_dir="" dest_dir=""
  comp_eng_dir="$(strata_components_engine_dir)"
  dest_dir="${comp_eng_dir}/${pkg_folder_name}"

  stop_strata_update_poller
  if [[ -d "$dest_dir" ]]; then
    _stop_strata_if_running || { start_strata_update_poller; return 1; }
    run_as_user_exec rm -rf "$dest_dir"
  fi
  run_as_user_exec mkdir -p "$comp_eng_dir"
  run_as_user_exec mv "$pkg_dir" "$dest_dir" || {
    echo -e "${C_RED}Failed to install package into ${dest_dir}.${C_RESET}"
    start_strata_update_poller
    return 1
  }
  invalidate_local_hip_engine_cache

  echo -e "\n${C_BGREEN}Installed local Strata HIP engine: ${dest_dir}${C_RESET}"
  if [[ -n "$STRATA_BIN" ]]; then
    if run_as_user_exec "$STRATA_BIN" components use "$pkg_folder_name"; then
      echo -e "${C_GREEN}Activated ${pkg_folder_name} via 'strata components use'.${C_RESET}"
    else
      echo -e "${C_YELLOW}Note: could not auto-pin via 'strata components use ${pkg_folder_name}'.${C_RESET}"
    fi
  fi

  if [[ "${_STRATA_WAS_ACTIVE:-false}" == true ]]; then
    if confirm_yn "Restart strata.service with the newly built HIP engine? [Y/n]: " "Y"; then
      service_ctl start strata.service && wait_for_strata_model_live 120 || true
    fi
  fi

  _print_local_hip_post_install_notes "$data_archs" "$dest_dir" "$has_tuning"

  echo ""
  if confirm_yn "Clean up temporary build files at ${bdir} (installed engine is self-contained)? [Y/n]: " "Y"; then
    run_as_user_exec rm -rf "$bdir"
  fi
  if (( ${#therock_cache_dirs[@]} > 0 )) && confirm_yn "Also remove cached TheRock ROCm SDK(s) at ${therock_cache_dirs[*]}? [y/N]: " "N"; then
    run_as_user_exec rm -rf "${therock_cache_dirs[@]}"
  fi

  refresh_strata_bin
  start_strata_update_poller
  return 0
}

run_strata_option() {
  local target_opt="$1" auto_run="${2:-false}" s_idx=0 total="${#ACTIVE_STRATA_OPTIONS[@]}" i opt action action_label
  (( total > 0 )) || return 0
  for (( i = 0; i < total; i++ )); do
    [[ "${ACTIVE_STRATA_OPTIONS[$i]}" == "$target_opt" ]] && { s_idx=$i; break; }
  done

  while true; do
    refresh_strata_bin
    refresh_strata_running
    build_strata_options
    total="${#ACTIVE_STRATA_OPTIONS[@]}"
    (( s_idx >= total )) && s_idx=$(( total - 1 ))
    opt="${ACTIVE_STRATA_OPTIONS[$s_idx]}"
    if [[ "$opt" == "history" ]]; then
      show_benchmark_history
      return 0
    fi
    print_header

    local body=""
    body+="$(echo -e "${C_BOLD}Strata Option s$((s_idx + 1)) of ${total}: $("title_strata_${opt}")${C_RESET}")"$'\n'
    body+="$(echo -e "Status: $("badge_strata_${opt}")")"$'\n'
    body+="$(echo -e "${C_DIM}----------------------------------------------------------------------${C_RESET}")"$'\n'
    body+="$("explain_strata_${opt}")"$'\n'
    body+="$(echo -e "${C_DIM}----------------------------------------------------------------------${C_RESET}")"$'\n\n'

    case "$opt" in
      install)   action_label="Install Strata" ;;
      update)    action_label="Check & install Strata update" ;;
      remove)    action_label="Remove Strata & uninstall service" ;;
      service)   action_label="Manage strata.service" ;;
      benchmark) action_label="Run Strata benchmark" ;;
      history)   action_label="View all benchmark results" ;;
      build_hip) action_label="Build / manage local Strata HIP engine" ;;
      *)         action_label="Run action" ;;
    esac

    if [[ "$opt" == "remove" ]]; then
      body+="$(echo -e "  ${C_RED}[a]${C_RESET} ${action_label}")"$'\n'
    else
      body+="$(echo -e "  ${C_GREEN}[a]${C_RESET} ${action_label}")"$'\n'
    fi
    if [[ "$opt" == "benchmark" ]] || (( $(count_bench_history) > 0 )); then
      body+="$(echo -e "  ${C_CYAN}[h]${C_RESET} Benchmark history & restore coupled options")"$'\n'
    fi
    body+="$(echo -e "  ${C_DIM}[n]${C_RESET} Next option   ${C_DIM}[b]${C_RESET} Previous option   ${C_DIM}[i/Esc]${C_RESET} Back to Index   ${C_DIM}[q]${C_RESET} Quit")"$'\n\n'

    printf "%s" "$body"
    if [[ "$auto_run" == true ]]; then
      auto_run=false
      echo ""
      if [[ "$opt" == "update" ]]; then
        perform_strata_update || true
      else
        "strata_action_${opt}" || true
      fi
      pause_prompt
      continue
    fi
    local body_lines lines_up
    body_lines="$(printf "%s" "$body" | wc -l)"
    lines_up=$(( LIVE_STATS_COUNT + POST_HEADER_LINES + body_lines ))
    read_step_action action "$lines_up"
    case "$action" in
      __refresh__) ;;
      __esc__|i|I) return 0 ;;
      a|A)
        echo ""
        "strata_action_${opt}" || true
        if [[ "$opt" == "benchmark" && "${LAST_BENCH_COMPLETED:-false}" == true ]]; then
          return 0
        fi
        [[ "$opt" != "history" ]] && pause_prompt
        ;;
      h|H)
        if [[ "$opt" == "benchmark" ]] || (( $(count_bench_history) > 0 )); then
          show_benchmark_history
        else
          echo -e "${C_RED}Invalid action '${action}'.${C_RESET}"; sleep 1
        fi
        ;;
      n|N|"")
        (( s_idx + 1 < total )) && ((s_idx++)) || return 0
        ;;
      b|B)
        (( s_idx > 0 )) && ((s_idx--))
        ;;
      q|Q) exit 0 ;;
      *) echo -e "${C_RED}Invalid action '${action}'.${C_RESET}"; sleep 1 ;;
    esac
  done
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

  local rapl_file="/sys/class/powercap/intel-rapl:0/energy_uj" rapl_can_read=false
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

  local gpu_pcts=() vram_pcts=() vram_useds=() vram_tots=() vram_labels=() pwr_ws=() pwr_lim_ws=() pwr_pcts=() gpu_temps=() gpu_notes=() gpu_thr_tags=()
  local total_gpu_pwr_w="" cpu_temp=""

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
          pw=$((pa / 1000000))
          total_gpu_pwr_w=$(( ${total_gpu_pwr_w:-0} + pw ))
          if [[ -r "$hwmon_dir/power1_cap" ]]; then
            pc="$(cat "$hwmon_dir/power1_cap" 2>/dev/null || echo 0)"
            if (( pc > 0 )); then
              plw=$((pc / 1000000))
              ppct=$((pa * 100 / pc))
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

  local sys_pwr_w="" cpu_pwr_w=""
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
      corsair-psu|acpi_power_meter|power_meter)
        if [[ -z "$sys_pwr_w" ]]; then
          local pf="" uw=0
          for pf in "$hm_dir"/power1_input "$hm_dir"/power1_average; do
            if [[ -r "$pf" ]]; then
              uw="$(cat "$pf" 2>/dev/null || echo 0)"
              (( uw > 0 )) && { sys_pwr_w=$((uw / 1000000)); break; }
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
    local bat_d bat_st cur_ua volt_uv uw
    for bat_d in /sys/class/power_supply/BAT*; do
      [[ -d "$bat_d" ]] || continue
      if [[ -r "$bat_d/power_now" ]]; then
        uw="$(cat "$bat_d/power_now" 2>/dev/null || echo 0)"
        [[ "$uw" =~ ^[0-9]+$ ]] && (( uw > 0 )) && { sys_pwr_w=$((uw / 1000000)); break; }
      elif [[ -r "$bat_d/current_now" && -r "$bat_d/voltage_now" ]]; then
        bat_st="$(cat "$bat_d/status" 2>/dev/null || true)"
        cur_ua="$(cat "$bat_d/current_now" 2>/dev/null || echo 0)"
        volt_uv="$(cat "$bat_d/voltage_now" 2>/dev/null || echo 0)"
        if [[ "$bat_st" == "Discharging" && "$cur_ua" =~ ^[0-9]+$ && "$volt_uv" =~ ^[0-9]+$ ]] && (( cur_ua > 0 && volt_uv > 0 )); then
          sys_pwr_w="$(awk -v c="$cur_ua" -v v="$volt_uv" 'BEGIN{printf "%.0f", (c/1000000.0)*(v/1000000.0)}')"
          break
        fi
      fi
    done
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
  if (( ${#gpu_pcts[@]} > 0 )) && [[ -n "$cpu_pwr_w" ]]; then true; fi
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
  elif [[ -e "$rapl_file" && "$rapl_can_read" == false ]]; then
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
  if [[ "$IS_DGX_SPARK" == true || ( "$HAS_NVIDIA_UNIFIED_MEM" == true && "$TOTAL_VRAM_MB" -eq 0 ) ]]; then
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

collect_strata_stats_lines() {
  STRATA_STAT_LINES=()
  STRATA_STAT_LINES+=("$(printf "%bStrata:%b" "${C_BOLD}" "${C_RESET}")")
  local ver_disp="${STRATA_VERSION:-Not installed}"
  [[ -z "$STRATA_BIN" && -n "$STRATA_DOCKER_CONTAINER" ]] && ver_disp="Docker (${STRATA_DOCKER_CONTAINER}, host-tuning mode)"
  STRATA_STAT_LINES+=("$(printf "  %-8s %b%s%b" "Version:" "${C_DIM}" "$ver_disp" "${C_RESET}")")
  local svc_str=""
  if strata_service_installed; then
    if unit_active strata.service; then
      svc_str="${C_GREEN}Installed (running via service)${C_RESET}"
    elif [[ -n "$STRATA_RUNNING_PRESET" ]]; then
      svc_str="${C_YELLOW}Installed (not running via service)${C_RESET}"
    else
      svc_str="${C_YELLOW}Installed (inactive)${C_RESET}"
    fi
  elif [[ -n "$STRATA_BIN" ]]; then
    svc_str="${C_DIM}Not installed${C_RESET}"
  fi

  if [[ -z "$STRATA_RUNNING_PRESET" ]]; then
    LIVE_COMPACT_STRATA=""
    [[ -n "$STRATA_BIN" ]] && LIVE_COMPACT_STRATA="Strata: idle"
    [[ -n "$STRATA_BIN" ]] && STRATA_STAT_LINES+=("$(printf "  %-8s %bNot serving%b" "Status:" "${C_DIM}" "${C_RESET}")")
    [[ -n "$svc_str" ]] && STRATA_STAT_LINES+=("$(printf "  %-8s %b" "Service:" "$svc_str")")
    return 0
  fi

  local model="" live_str="0.0 tok/s (idle)" avg_str="—"
  if [[ -n "$STRATA_RUNNING_URL" ]] && command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    local m_json curl_args=(-fsS --max-time 1)
    [[ -n "${STRATA_API_KEY:-}" ]] && curl_args+=(-H "Authorization: Bearer ${STRATA_API_KEY}" -H "X-API-Key: ${STRATA_API_KEY}")
    m_json="$(curl "${curl_args[@]}" "${STRATA_RUNNING_URL}/metrics" 2>/dev/null || true)"
    if [[ -n "$m_json" ]]; then
      local parsed=""
      parsed="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
model = (d.get("engine") or {}).get("model") or ""
live = d.get("live") or {}
state = live.get("state") or "idle"
ltok = live.get("tok_s")
if ltok is not None and isinstance(ltok, (int, float)):
    live_s = f"{ltok:.1f} tok/s ({state})"
else:
    live_s = f"0.0 tok/s ({state})"
tot = d.get("totals") or {}
out_tok = tot.get("output_tokens") or 0
dec_ms = tot.get("decode_ms") or 0
reqs = tot.get("requests") or 0
if out_tok > 0 and dec_ms > 0:
    avg_s = f"{out_tok / (dec_ms / 1000.0):.1f} tok/s ({reqs} reqs, {out_tok} tok)"
else:
    avg_s = "0.0 tok/s (no reqs)"
model = str(model).replace("|", "/").replace("\n", " ")
live_s = str(live_s).replace("|", "/").replace("\n", " ")
print(f"{model}|{live_s}|{avg_s}")
' <<< "$m_json" 2>/dev/null || true)"
      if [[ -n "$parsed" ]]; then
        IFS='|' read -r model live_str avg_str <<< "$parsed"
      fi
    fi
  fi
  local preset_disp="$STRATA_RUNNING_PRESET"
  [[ -n "$model" ]] && preset_disp+=" ($model)"
  STRATA_STAT_LINES+=("$(printf "  %-8s %s" "Preset:" "$preset_disp")")
  STRATA_STAT_LINES+=("$(printf "  %-8s %b%s%b" "Live:" "${C_CYAN}" "$live_str" "${C_RESET}")")
  STRATA_STAT_LINES+=("$(printf "  %-8s %b%s%b" "Avg:" "${C_GREEN}" "$avg_str" "${C_RESET}")")
  [[ -n "$svc_str" ]] && STRATA_STAT_LINES+=("$(printf "  %-8s %b" "Service:" "$svc_str")")
  LIVE_COMPACT_STRATA="Strata: ${live_str}"
}

format_pct_delta() {
  local pct="$1"
  [[ -n "$pct" ]] || return 1
  if [[ "$pct" == "0.0" || "$pct" == "-0.0" ]]; then
    printf "%b0.0%%%b" "${C_DIM}" "${C_RESET}"
  elif [[ "$pct" == -* ]]; then
    printf "%b%s%%%b" "${C_RED}" "$pct" "${C_RESET}"
  else
    printf "%b+%s%%%b" "${C_BGREEN}" "$pct" "${C_RESET}"
  fi
}

collect_strata_bench_lines() {
  local newest="" hist_mtime="0"
  newest="$(find_latest_results_json 0)"
  [[ -r "$STRATA_BENCH_HISTORY_FILE" ]] && hist_mtime="$(stat -c '%Y' "$STRATA_BENCH_HISTORY_FILE" 2>/dev/null || echo 0)"

  if [[ -z "$newest" && "$hist_mtime" == "0" ]]; then
    STRATA_BENCH_CACHE_KEY=""
    STRATA_BENCH_LINES=()
    STRATA_BENCH_LINES+=("$(printf "%bLatest Benchmark:%b" "${C_BOLD}" "${C_RESET}")")
    STRATA_BENCH_LINES+=("$(printf "  %-8s %bNo benchmark history found%b" "Status:" "${C_DIM}" "${C_RESET}")")
    if [[ -n "$STRATA_BIN" ]]; then
      STRATA_BENCH_LINES+=("$(printf "  %-8s %b'strata bench run' (or [s4])%b" "Run:" "${C_DIM}" "${C_RESET}")")
    fi
    return 0
  fi

  local mtime="0" cache_key
  [[ -n "$newest" ]] && mtime="$(stat -c '%Y' "$newest" 2>/dev/null || echo 0)"
  cache_key="${newest}:${mtime}:${hist_mtime}"
  if [[ "$cache_key" == "$STRATA_BENCH_CACHE_KEY" && ${#STRATA_BENCH_LINES[@]} -gt 0 ]]; then
    return 0
  fi

  local parsed=""
  if command -v python3 >/dev/null 2>&1; then
    parsed="$(python3 - "$STRATA_BENCH_HISTORY_FILE" "$PWD/bench/results" "$PWD/bench-results" "$TARGET_HOME/bench/results" "$TARGET_HOME/bench-results" "$TARGET_HOME/.local/share/strata/bench-results" "$TARGET_HOME/.config/strata/bench-results" <<'PY' 2>/dev/null || true
import datetime, glob, json, os, statistics, sys

hist_path = sys.argv[1]
search_dirs = sys.argv[2:]

def fmt_ts(ts):
    ts = (ts or "").replace("T", " ")
    if ts.endswith("Z"):
        ts = ts[:-1] + " UTC"
    if len(ts) > 20 and " UTC" in ts:
        ts = ts[:16] + " UTC"
    return ts

def from_results_file(path, hist_by_file):
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception:
        return None
    if not isinstance(d, dict):
        return None
    he = hist_by_file.get(os.path.realpath(path)) or hist_by_file.get(path)
    run = d.get("run") if isinstance(d.get("run"), dict) else {}
    ts = fmt_ts(run.get("started_at") or run.get("timestamp") or d.get("timestamp") or "")
    if not ts:
        try:
            ts = datetime.datetime.fromtimestamp(os.path.getmtime(path), tz=datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        except Exception:
            ts = "Unknown"
    cfg = d.get("configuration") if isinstance(d.get("configuration"), dict) else {}
    proto_d = d.get("protocol") if isinstance(d.get("protocol"), dict) else {}
    prof = proto_d.get("profile") or cfg.get("profile") or ""
    proto = proto_d.get("id") or d.get("protocol_id") or d.get("format") or ""
    tag = prof or ("standard-v1" if "standard" in proto else proto) or (he.get("tag") if he else "")
    mdl = d.get("model")
    if isinstance(mdl, dict):
        m_name = mdl.get("name") or mdl.get("id") or ""
        m_quant = mdl.get("quantization") or ""
        if m_name and m_quant and m_quant.lower() not in m_name.lower():
            model_s = f"{m_name} ({m_quant})"
        else:
            model_s = m_name or m_quant or "Unknown"
    elif isinstance(mdl, str) and mdl:
        model_s = mdl
    else:
        model_s = (he.get("model") if he else None) or "Unknown"
    sums_raw = d.get("summaries") if "summaries" in d else d.get("summary")
    reqs = d.get("requests") if isinstance(d.get("requests"), list) else []
    dec = None
    pre = None
    tot_r = None
    fail_r = 0
    if isinstance(sums_raw, list):
        perf_dec = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("phase") == "performance" and s.get("metric") == "decode_tps" and isinstance(s.get("median"), (int, float))]
        all_dec = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("metric") == "decode_tps" and isinstance(s.get("median"), (int, float))]
        perf_pre = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("phase") == "performance" and s.get("metric") == "prompt_tps" and isinstance(s.get("median"), (int, float))]
        all_pre = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("metric") == "prompt_tps" and isinstance(s.get("median"), (int, float))]
        if perf_dec:
            dec = statistics.median(perf_dec)
        elif all_dec:
            dec = statistics.median(all_dec)
        if perf_pre:
            pre = statistics.median(perf_pre)
        elif all_pre:
            pre = statistics.median(all_pre)
    elif isinstance(sums_raw, dict):
        dec = sums_raw.get("median_decode_tok_s") or sums_raw.get("decode_tps") or sums_raw.get("decode_tok_s")
        pre = sums_raw.get("median_prefill_tok_s") or sums_raw.get("prompt_tps") or sums_raw.get("prefill_tok_s")
        tot_r = sums_raw.get("total_requests")
        fail_r = sums_raw.get("failed_requests") if isinstance(sums_raw.get("failed_requests"), int) else 0
    if dec is None:
        vals = [r.get("decode_tok_s") for r in reqs if isinstance(r, dict) and isinstance(r.get("decode_tok_s"), (int, float))]
        if vals:
            dec = statistics.median(vals)
    if pre is None:
        vals = [r.get("prefill_tok_s") for r in reqs if isinstance(r, dict) and isinstance(r.get("prefill_tok_s"), (int, float))]
        if vals:
            pre = statistics.median(vals)
    perf_reqs = [r for r in reqs if isinstance(r, dict) and r.get("phase") == "performance"]
    req_pool = perf_reqs if perf_reqs else [r for r in reqs if isinstance(r, dict) and r.get("phase") != "warmup"]
    avg_dec_vals = []
    avg_pre_vals = []
    for r in req_pool:
        m = r.get("metrics") if isinstance(r.get("metrics"), dict) else {}
        dv = m.get("decode_tps") if isinstance(m.get("decode_tps"), (int, float)) else r.get("decode_tok_s")
        pv = m.get("prompt_tps") if isinstance(m.get("prompt_tps"), (int, float)) else r.get("prefill_tok_s")
        if dv is None:
            tk = r.get("tokens") if isinstance(r.get("tokens"), dict) else {}
            tm = r.get("timings") if isinstance(r.get("timings"), dict) else {}
            if isinstance(tk.get("decode_tokens"), (int, float)) and isinstance(tm.get("decode_s"), (int, float)) and tm["decode_s"] > 0:
                dv = tk["decode_tokens"] / tm["decode_s"]
        if pv is None:
            tk = r.get("tokens") if isinstance(r.get("tokens"), dict) else {}
            tm = r.get("timings") if isinstance(r.get("timings"), dict) else {}
            rtok = tk.get("read_tokens") if isinstance(tk.get("read_tokens"), (int, float)) else tk.get("input_tokens")
            if isinstance(rtok, (int, float)) and isinstance(tm.get("prompt_s"), (int, float)) and tm["prompt_s"] > 0:
                pv = rtok / tm["prompt_s"]
        if isinstance(dv, (int, float)):
            avg_dec_vals.append(dv)
        if isinstance(pv, (int, float)):
            avg_pre_vals.append(pv)
    avg_dec = statistics.mean(avg_dec_vals) if avg_dec_vals else (he.get("avg_decode_tok_s") if he else None)
    avg_pre = statistics.mean(avg_pre_vals) if avg_pre_vals else (he.get("avg_prefill_tok_s") if he else None)
    rcounts = d.get("request_counts") if isinstance(d.get("request_counts"), dict) else {}
    if not isinstance(tot_r, int) and rcounts:
        tot_r = sum(v.get("attempted", 0) for v in rcounts.values() if isinstance(v, dict) and isinstance(v.get("attempted"), int))
        fail_r = sum(v.get("failed", 0) for v in rcounts.values() if isinstance(v, dict) and isinstance(v.get("failed"), int))
    if not isinstance(tot_r, int) and reqs:
        tot_r = len(reqs)
        fail_r = sum(1 for r in reqs if isinstance(r, dict) and r.get("status") not in (None, "ok", "completed"))
    req_s = f"{tot_r - fail_r}/{tot_r} ok" if isinstance(tot_r, int) and tot_r > 0 else ""
    qual = d.get("quality") if isinstance(d.get("quality"), dict) else {}
    qp = qual.get("sanity_checks_passed") if qual.get("sanity_checks_passed") is not None else qual.get("passed")
    qt = qual.get("sanity_checks_total") if qual.get("sanity_checks_total") is not None else qual.get("total")
    qual_s = f"Sanity: {qp}/{qt}" if isinstance(qp, int) and isinstance(qt, int) and qt > 0 else ""
    pwr = (he.get("avg_power") if isinstance((he or {}).get("avg_power"), dict) else {})
    return {
        "ts": ts, "tag": tag, "model": model_s,
        "dec": float(dec) if isinstance(dec, (int, float)) else None,
        "pre": float(pre) if isinstance(pre, (int, float)) else None,
        "avg_dec": float(avg_dec) if isinstance(avg_dec, (int, float)) else None,
        "avg_pre": float(avg_pre) if isinstance(avg_pre, (int, float)) else None,
        "req_s": req_s, "qual_s": qual_s,
        "sw": str(pwr.get("sys_w") or ""), "gw": str(pwr.get("gpu_w") or ""), "cw": str(pwr.get("cpu_w") or ""),
        "key": os.path.realpath(path),
    }

def from_hist_entry(e):
    ts = fmt_ts(e.get("timestamp"))
    tag = e.get("tag") or e.get("mode") or ""
    model_s = e.get("model") or "Unknown"
    dec = e.get("decode_tok_s")
    pre = e.get("prefill_tok_s")
    avg_dec = e.get("avg_decode_tok_s")
    avg_pre = e.get("avg_prefill_tok_s")
    tot_r = e.get("total_requests")
    fail_r = e.get("failed_requests") if isinstance(e.get("failed_requests"), int) else 0
    req_s = f"{tot_r - fail_r}/{tot_r} ok" if isinstance(tot_r, int) and tot_r > 0 else ""
    qp, qt = e.get("sanity_checks_passed"), e.get("sanity_checks_total")
    qual_s = f"Sanity: {qp}/{qt}" if isinstance(qp, int) and isinstance(qt, int) and qt > 0 else ""
    pwr = e.get("avg_power") if isinstance(e.get("avg_power"), dict) else {}
    rf = e.get("results_file") or ""
    return {
        "ts": ts, "tag": tag, "model": model_s,
        "dec": float(dec) if isinstance(dec, (int, float)) else None,
        "pre": float(pre) if isinstance(pre, (int, float)) else None,
        "avg_dec": float(avg_dec) if isinstance(avg_dec, (int, float)) else None,
        "avg_pre": float(avg_pre) if isinstance(avg_pre, (int, float)) else None,
        "req_s": req_s, "qual_s": qual_s,
        "sw": str(pwr.get("sys_w") or ""), "gw": str(pwr.get("gpu_w") or ""), "cw": str(pwr.get("cpu_w") or ""),
        "key": os.path.realpath(rf) if rf else f"hist:{e.get('id') or ts}",
    }

hist_list = []
hist_by_file = {}
if hist_path and os.path.exists(hist_path):
    try:
        with open(hist_path) as f:
            loaded = json.load(f)
        if isinstance(loaded, list):
            hist_list = [e for e in loaded if isinstance(e, dict)]
            for e in hist_list:
                rf = e.get("results_file")
                if rf:
                    hist_by_file[rf] = e
                    hist_by_file[os.path.realpath(rf)] = e
    except Exception:
        pass

items = []
seen = set()
# Prefer coupled host history (newest first)
for e in reversed(hist_list):
    rf = e.get("results_file") or ""
    rec = from_results_file(rf, hist_by_file) if (rf and os.path.exists(rf)) else from_hist_entry(e)
    if rec and rec["key"] not in seen:
        seen.add(rec["key"])
        items.append(rec)

# Include raw results.json files on disk (newest mtime first)
found_files = []
for d in search_dirs:
    if not os.path.isdir(d):
        continue
    for pat in (os.path.join(d, "*", "results.json"), os.path.join(d, "results.json")):
        for p in glob.glob(pat):
            try:
                found_files.append((os.path.getmtime(p), os.path.realpath(p), p))
            except Exception:
                pass
found_files.sort(reverse=True)
for _, rp, p in found_files:
    if rp in seen:
        continue
    rec = from_results_file(p, hist_by_file)
    if rec:
        seen.add(rp)
        items.append(rec)

if not items:
    sys.exit(0)

def fmt_rec(kind, rec, d_pct="", p_pct="", prev_d_pct="", prev_p_pct=""):
    dec_s = f"{rec['dec']:.1f} tok/s" if rec["dec"] is not None else "—"
    pre_s = f"{rec['pre']:.1f} tok/s" if rec["pre"] is not None else "—"
    avg_dec_s = f"{rec['avg_dec']:.1f} tok/s" if rec.get("avg_dec") is not None else ""
    avg_pre_s = f"{rec['avg_pre']:.1f} tok/s" if rec.get("avg_pre") is not None else ""
    cols = [kind, rec["ts"], rec["tag"], rec["model"], dec_s, pre_s, rec["req_s"], rec["qual_s"], rec["sw"], rec["gw"], rec["cw"], d_pct, p_pct, avg_dec_s, avg_pre_s, prev_d_pct, prev_p_pct]
    return "|".join(str(c).replace("|", "/").replace("\n", " ").replace("\r", "") for c in cols)

def score_key(rec):
    d = rec.get("avg_dec") if rec.get("avg_dec") is not None else rec.get("dec")
    p = rec.get("avg_pre") if rec.get("avg_pre") is not None else rec.get("pre")
    return (d if isinstance(d, (int, float)) else -1.0, p if isinstance(p, (int, float)) else -1.0)

def pct_vs_ref(rec, ref_rec):
    rec_d = rec.get("avg_dec") if rec.get("avg_dec") is not None else rec.get("dec")
    ref_d = ref_rec.get("avg_dec") if ref_rec.get("avg_dec") is not None else ref_rec.get("dec")
    rec_p = rec.get("avg_pre") if rec.get("avg_pre") is not None else rec.get("pre")
    ref_p = ref_rec.get("avg_pre") if ref_rec.get("avg_pre") is not None else ref_rec.get("pre")
    dp = f"{((rec_d - ref_d) / ref_d) * 100.0:.1f}" if (isinstance(rec_d, (int, float)) and isinstance(ref_d, (int, float)) and ref_d > 0) else ""
    pp = f"{((rec_p - ref_p) / ref_p) * 100.0:.1f}" if (isinstance(rec_p, (int, float)) and isinstance(ref_p, (int, float)) and ref_p > 0) else ""
    return dp, pp

best = max(items, key=score_key)
if len(items) >= 2:
    cur_dp, cur_pp = pct_vs_ref(items[0], best)
    cur_prev_dp, cur_prev_pp = pct_vs_ref(items[0], items[1])
    print(fmt_rec("CUR", items[0], cur_dp, cur_pp, cur_prev_dp, cur_prev_pp))
    prev_dp, prev_pp = pct_vs_ref(items[1], best)
    print(fmt_rec("PREV", items[1], prev_dp, prev_pp))
    print(fmt_rec("BEST", best))
else:
    print(fmt_rec("CUR", items[0]))
PY
)"
  fi

  STRATA_BENCH_CACHE_KEY="$cache_key"
  STRATA_BENCH_LINES=()
  if [[ -z "$parsed" ]]; then
    STRATA_BENCH_LINES+=("$(printf "%bLatest Benchmark:%b" "${C_BOLD}" "${C_RESET}")")
    STRATA_BENCH_LINES+=("$(printf "  %-8s %bNo readable benchmark data%b" "Status:" "${C_DIM}" "${C_RESET}")")
    return 0
  fi

  local line kind b_ts b_tag b_model b_dec b_pre b_req b_qual b_sw b_gw b_cw b_dpct b_ppct b_avg_dec b_avg_pre b_pdpct b_pppct
  while IFS='|' read -r kind b_ts b_tag b_model b_dec b_pre b_req b_qual b_sw b_gw b_cw b_dpct b_ppct b_avg_dec b_avg_pre b_pdpct b_pppct; do
    [[ -n "$kind" ]] || continue
    if [[ "$kind" == "CUR" ]]; then
      STRATA_BENCH_LINES+=("$(printf "%bLatest Benchmark:%b" "${C_BOLD}" "${C_RESET}")")
    elif [[ "$kind" == "PREV" ]]; then
      STRATA_BENCH_LINES+=("$(printf "%bPrevious Benchmark:%b" "${C_BOLD}" "${C_RESET}")")
    else
      STRATA_BENCH_LINES+=("$(printf "%bBest Benchmark:%b" "${C_BOLD}" "${C_RESET}")")
    fi
    local date_disp="${b_ts:-Unknown}"
    [[ -n "$b_tag" ]] && date_disp+=" (${b_tag})"
    STRATA_BENCH_LINES+=("$(printf "  %-8s %b%s%b" "Date:" "${C_DIM}" "$date_disp" "${C_RESET}")")
    STRATA_BENCH_LINES+=("$(printf "  %-8s %s" "Model:" "$b_model")")
    if [[ -n "$b_avg_dec" || -n "$b_avg_pre" ]]; then
      local avg_parts=()
      [[ -n "$b_avg_dec" ]] && avg_parts+=("${b_avg_dec} decode")
      [[ -n "$b_avg_pre" ]] && avg_parts+=("${b_avg_pre} prefill")
      local avg_str="${avg_parts[0]}"
      (( ${#avg_parts[@]} > 1 )) && avg_str+=" | ${avg_parts[1]}"
      STRATA_BENCH_LINES+=("$(printf "  %-8s %b%s%b" "Avg:" "${C_CYAN}" "$avg_str" "${C_RESET}")")
    fi
    local b_pwr
    b_pwr="$(format_avg_power_str "$b_sw" "$b_gw" "$b_cw")"
    if [[ -n "$b_pwr" ]]; then
      STRATA_BENCH_LINES+=("$(printf "  %-8s %s" "Power:" "$b_pwr")")
    else
      STRATA_BENCH_LINES+=("$(printf "  %-8s %bn/a (not recorded)%b" "Power:" "${C_DIM}" "${C_RESET}")")
    fi
    STRATA_BENCH_LINES+=("$(printf "  %-8s %b%s%b | Prefill: %b%s%b" "Decode:" "${C_CYAN}" "$b_dec" "${C_RESET}" "${C_CYAN}" "$b_pre" "${C_RESET}")")
    if [[ "$kind" == "CUR" ]]; then
      local pdiff_parts=()
      [[ -n "$b_pdpct" ]] && pdiff_parts+=("Decode $(format_pct_delta "$b_pdpct")")
      [[ -n "$b_pppct" ]] && pdiff_parts+=("Prefill $(format_pct_delta "$b_pppct")")
      if (( ${#pdiff_parts[@]} > 0 )); then
        local pdiff_str="" pdi=0
        for ((pdi=0; pdi<${#pdiff_parts[@]}; pdi++)); do
          (( pdi > 0 )) && pdiff_str+=" | "
          pdiff_str+="${pdiff_parts[$pdi]}"
        done
        pdiff_str+=" ${C_DIM}(vs prev)${C_RESET}"
        STRATA_BENCH_LINES+=("$(printf "  %-8s %b" "Diff:" "$pdiff_str")")
      fi
    fi
    if [[ "$kind" == "CUR" || "$kind" == "PREV" ]]; then
      local diff_parts=()
      [[ -n "$b_dpct" ]] && diff_parts+=("Decode $(format_pct_delta "$b_dpct")")
      [[ -n "$b_ppct" ]] && diff_parts+=("Prefill $(format_pct_delta "$b_ppct")")
      if (( ${#diff_parts[@]} > 0 )); then
        local diff_str="" di=0
        for ((di=0; di<${#diff_parts[@]}; di++)); do
          (( di > 0 )) && diff_str+=" | "
          diff_str+="${diff_parts[$di]}"
        done
        diff_str+=" ${C_DIM}(vs best)${C_RESET}"
        STRATA_BENCH_LINES+=("$(printf "  %-8s %b" "Diff:" "$diff_str")")
      fi
    fi
    local summary_tail=""
    [[ -n "$b_req" ]] && summary_tail="Reqs: ${b_req}"
    if [[ -n "$b_qual" ]]; then
      [[ -n "$summary_tail" ]] && summary_tail+=" | "
      summary_tail+="$b_qual"
    fi
    [[ -n "$summary_tail" ]] && STRATA_BENCH_LINES+=("$(printf "  %-8s %b%s%b" "Checks:" "${C_DIM}" "$summary_tail" "${C_RESET}")")
    STRATA_BENCH_LINES+=("")
  done <<< "$parsed"
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
  collect_strata_stats_lines
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

format_strata_toggle_row() {
  local selected="${1:-false}"
  local ptr=" " tag="[STRATA]" title="Strata Options & Management" sub="(Install / Update / Service / Benchmark / History)"
  if [[ "$selected" == true ]]; then
    ptr="${C_CYAN}>${C_RESET}"
    printf "%b %b%s%b %b%s%b  %b%s%b" "$ptr" "${C_BGREEN}${C_BOLD}" "$tag" "${C_RESET}" "${C_CYAN}${C_BOLD}" "$title" "${C_RESET}" "${C_CYAN}" "$sub" "${C_RESET}"
  else
    printf "%b %b%s%b %b%s%b  %b%s%b" "$ptr" "${C_YELLOW}${C_BOLD}" "$tag" "${C_RESET}" "${C_BOLD}" "$title" "${C_RESET}" "${C_DIM}" "$sub" "${C_RESET}"
  fi
}

format_strata_update_banner() {
  local rule_w="${1:-117}"
  [[ "$STRATA_UPDATE_AVAILABLE" == true ]] || return 0
  local msg=" [UPDATE AVAILABLE] Strata update ready — Press [u] to install & restart service "
  if (( rule_w > 10 && ${#msg} > rule_w )); then
    msg="${msg:0:$((rule_w - 3))}..."
  fi
  local pad=$(( rule_w - ${#msg} ))
  local spaces=""
  (( pad > 0 )) && printf -v spaces "%*s" "$pad" ""
  printf "%b%s%s%b" "${C_UPDATE_BANNER}" "$msg" "$spaces" "${C_RESET}"
}

_render_update_banner_inplace() {
  local banner_up="$1" term_lines="${2:-40}"
  (( banner_up > 0 && banner_up < term_lines )) || return 1
  local rule_w=120
  [[ -t 1 ]] && rule_w="$(tput cols 2>/dev/null || echo 117)"
  (( rule_w > 117 )) && rule_w=117
  local banner_line
  banner_line="$(format_strata_update_banner "$rule_w")"
  printf "\033[?2026h\033[?25l\033[s\033[%dA\r\033[2K%s\033[u\033[?25h\033[?2026l" "$banner_up" "$banner_line"
  return 0
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
  load_strata_update_state
  if [[ "$hdr_mode" == "toggle" ]]; then
    LIVE_STATS_COUNT=0
    LIVE_STAT_LINES=()
    echo ""
    local _tgl_sel=false _str_sel=false
    (( INDEX_SELECTED == 0 )) && _tgl_sel=true
    (( INDEX_SELECTED == 1 )) && _str_sel=true
    printf "%s\n" "$(format_stats_toggle_row "$_tgl_sel")"
    echo ""
    printf "%s\n" "$(format_strata_toggle_row "$_str_sel")"
    echo ""
    POST_HEADER_LINES=5
    UPDATE_BANNER_OFFSET=5
  elif [[ "$hdr_mode" == "stats" ]]; then
    refresh_strata_running
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
  if [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
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

read_line_with_live_stats() {
  local -n _line_out="$1"
  local prompt_str="${2:-Select action: }"
  local lines_up="${3:-0}"
  local total_rows="${4:-0}"
  if [[ ! -t 0 || ! -t 1 ]]; then
    read -r -p "$prompt_str" _line_out || exit 0
    return 0
  fi

  local term_lines=40 compact_bar=false
  term_lines="$(tput lines 2>/dev/null || echo 40)"
  if (( LIVE_STATS_COUNT > 0 )) && ! _can_live_stats "$lines_up" "$term_lines"; then
    compact_bar=true
    local _bar0
    _bar0="$(format_compact_live_bar)"
    if [[ -n "$_bar0" ]]; then
      printf "%s\n" "$_bar0"
      local _hi
      for (( _hi = 0; _hi < ${#HIST_HDR_LINES[@]}; _hi++ )); do
        HIST_HDR_LINES[$_hi]=$(( HIST_HDR_LINES[_hi] + 1 ))
      done
    fi
  fi

  local tmp_file="" sampler_pid=""
  if (( LIVE_STATS_COUNT > 0 )); then
    tmp_file="$(mktemp /tmp/strata-stats.XXXXXX 2>/dev/null || echo "")"
  fi
  if [[ -n "$tmp_file" ]]; then
    (
      trap 'exit 0' TERM INT
      while true; do
        sleep 1 &
        wait $! 2>/dev/null || exit 0
        refresh_strata_running
        if print_stats_and_info_grid true > "${tmp_file}.tmp" 2>/dev/null; then
          format_compact_live_bar > "${tmp_file}.bar.tmp" 2>/dev/null || true
          mv -f "${tmp_file}.bar.tmp" "${tmp_file}.bar" 2>/dev/null || true
          printf "%s\n" "$LIVE_STATS_COUNT" > "${tmp_file}.meta.tmp" 2>/dev/null || true
          mv -f "${tmp_file}.meta.tmp" "${tmp_file}.meta" 2>/dev/null || true
          mv -f "${tmp_file}.tmp" "$tmp_file" 2>/dev/null || true
        fi
      done
    ) &
    sampler_pid=$!
    ACTIVE_SAMPLER_PID="$sampler_pid"
    ACTIVE_SAMPLER_TMP="$tmp_file"
  fi

  local saved_tty=""
  saved_tty="$(stty -g 2>/dev/null || true)"
  stty -echo 2>/dev/null || true
  _cleanup_line_live() {
    [[ -n "$sampler_pid" ]] && { kill "$sampler_pid" 2>/dev/null || true; wait "$sampler_pid" 2>/dev/null || true; sampler_pid=""; }
    [[ -n "$tmp_file" ]] && { rm -f "$tmp_file" "${tmp_file}.tmp" "${tmp_file}.bar" "${tmp_file}.bar.tmp" "${tmp_file}.meta" "${tmp_file}.meta.tmp" 2>/dev/null || true; tmp_file=""; }
    ACTIVE_SAMPLER_PID="" ACTIVE_SAMPLER_TMP=""
    if [[ -n "$saved_tty" ]]; then
      stty "$saved_tty" 2>/dev/null || stty echo 2>/dev/null || true
    else
      stty echo 2>/dev/null || true
    fi
  }
  trap '_cleanup_line_live; exit 0' INT TERM

  local buf="" ch="" rc=0 stats_block="" new_lines=""
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
        local _esc="" _ec="" _en=0
        IFS= read -rsn2 -t 0.01 _esc || true
        if [[ -z "$_esc" ]]; then
          _cleanup_line_live; trap - INT TERM; printf "\n"
          _line_out="__esc__"; return 0
        fi
        if [[ "$_esc" == \[* || "$_esc" == O* ]] && [[ ! "$_esc" =~ [A-Za-z~]$ ]]; then
          while (( _en++ < 8 )) && IFS= read -rsn1 -t 0.01 _ec; do
            [[ "$_ec" =~ [A-Za-z~] ]] && break
          done
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
          if (( total_rows == 0 || (10#_cand >= 1 && 10#_cand <= total_rows) )); then
            _accept=true
          fi
        fi
        if [[ "$_accept" == true ]]; then
          buf+="$ch"; printf "%s" "$ch"
        fi
      fi
    elif (( rc > 128 )); then
      local prev_upd="$STRATA_UPDATE_AVAILABLE"
      load_strata_update_state
      if [[ "$prev_upd" == false && "$STRATA_UPDATE_AVAILABLE" == true ]]; then
        local _b_up=$(( lines_up - LIVE_STATS_COUNT - UPDATE_BANNER_OFFSET ))
        if ! _render_update_banner_inplace "$_b_up" "$term_lines" && [[ -z "$buf" ]]; then
          _cleanup_line_live; trap - INT TERM; printf "\n"
          _line_out="__refresh__"; return 0
        fi
      fi
      new_lines="$LIVE_STATS_COUNT"
      [[ -n "$tmp_file" && -s "${tmp_file}.meta" ]] && read -r new_lines < "${tmp_file}.meta" || true
      if [[ "$compact_bar" == true ]]; then
        [[ -n "$tmp_file" && -s "${tmp_file}.bar" ]] && _render_live_bar_inplace "$(<"${tmp_file}.bar")"
      elif [[ "$new_lines" =~ ^[0-9]+$ ]] && (( new_lines != LIVE_STATS_COUNT )); then
        if [[ -z "$buf" ]]; then
          _cleanup_line_live; trap - INT TERM; printf "\n"
          _line_out="__refresh__"; return 0
        fi
      elif [[ -n "$tmp_file" && -s "$tmp_file" ]]; then
        stats_block="$(<"$tmp_file")"
        _render_live_stats_inplace "$lines_up" "$term_lines" "$stats_block"
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

  local term_lines=40 compact_bar=false
  term_lines="$(tput lines 2>/dev/null || echo 40)"
  if (( LIVE_STATS_COUNT > 0 )) && ! _can_live_stats "$lines_up" "$term_lines"; then
    compact_bar=true
    local _bar0
    _bar0="$(format_compact_live_bar)"
    if [[ -n "$_bar0" ]]; then
      printf "%s\n" "$_bar0"
      local _hi
      for (( _hi = 0; _hi < ${#HIST_HDR_LINES[@]}; _hi++ )); do
        HIST_HDR_LINES[$_hi]=$(( HIST_HDR_LINES[_hi] + 1 ))
      done
    fi
  fi

  local tmp_file="" sampler_pid=""
  if (( LIVE_STATS_COUNT > 0 )); then
    tmp_file="$(mktemp /tmp/strata-stats.XXXXXX 2>/dev/null || echo "")"
  fi
  if [[ -n "$tmp_file" ]]; then
    (
      trap 'exit 0' TERM INT
      while true; do
        sleep 1 &
        wait $! 2>/dev/null || exit 0
        refresh_strata_running
        if print_stats_and_info_grid true > "${tmp_file}.tmp" 2>/dev/null; then
          format_compact_live_bar > "${tmp_file}.bar.tmp" 2>/dev/null || true
          mv -f "${tmp_file}.bar.tmp" "${tmp_file}.bar" 2>/dev/null || true
          printf "%s\n" "$LIVE_STATS_COUNT" > "${tmp_file}.meta.tmp" 2>/dev/null || true
          mv -f "${tmp_file}.meta.tmp" "${tmp_file}.meta" 2>/dev/null || true
          mv -f "${tmp_file}.tmp" "$tmp_file" 2>/dev/null || true
        fi
      done
    ) &
    sampler_pid=$!
    ACTIVE_SAMPLER_PID="$sampler_pid"
    ACTIVE_SAMPLER_TMP="$tmp_file"
  fi

  local saved_tty=""
  saved_tty="$(stty -g 2>/dev/null || true)"
  stty -echo 2>/dev/null || true
  _restore_step_tty() {
    [[ -n "$sampler_pid" ]] && { kill "$sampler_pid" 2>/dev/null || true; wait "$sampler_pid" 2>/dev/null || true; sampler_pid=""; }
    [[ -n "$tmp_file" ]] && { rm -f "$tmp_file" "${tmp_file}.tmp" "${tmp_file}.bar" "${tmp_file}.bar.tmp" "${tmp_file}.meta" "${tmp_file}.meta.tmp" 2>/dev/null || true; tmp_file=""; }
    ACTIVE_SAMPLER_PID="" ACTIVE_SAMPLER_TMP=""
    if [[ -n "$saved_tty" ]]; then
      stty "$saved_tty" 2>/dev/null || stty echo 2>/dev/null || true
    else
      stty echo 2>/dev/null || true
    fi
  }
  trap '_restore_step_tty; exit 0' INT TERM

  local buf="" ch="" esc_seq="" rc=0 stats_block="" new_lines=""
  printf "Select action: "
  while true; do
    rc=0
    IFS= read -rsn1 -t 1 ch || rc=$?
    if (( rc == 0 )); then
      if [[ -z "$ch" ]]; then
        _restore_step_tty
        trap - INT TERM
        printf "\n"
        _act_out="$buf"
        return 0
      elif [[ "$ch" == $'\177' || "$ch" == $'\b' ]]; then
        if [[ -n "$buf" ]]; then
          buf="${buf%?}"
          printf "\b \b"
        fi
      elif [[ "$ch" == $'\e' ]]; then
        esc_seq=""
        IFS= read -rsn2 -t 0.01 esc_seq || true
        if [[ -z "$esc_seq" ]]; then
          _restore_step_tty
          trap - INT TERM
          printf "\n"
          _act_out="__esc__"
          return 0
        fi
        if [[ "$esc_seq" == \[* || "$esc_seq" == O* ]] && [[ ! "$esc_seq" =~ [A-Za-z~]$ ]]; then
          local _esc_ch="" _esc_n=0
          while (( _esc_n++ < 8 )) && IFS= read -rsn1 -t 0.01 _esc_ch; do
            [[ "$_esc_ch" =~ [A-Za-z~] ]] && break
          done
        fi
      elif [[ -z "$buf" && "$ch" =~ ^[aArRuUhHnNbBiIqQ]$ ]]; then
        buf="$ch"
        printf "%s" "$ch"
      fi
    elif (( rc > 128 )); then
      local prev_upd="$STRATA_UPDATE_AVAILABLE"
      load_strata_update_state
      if [[ "$prev_upd" == false && "$STRATA_UPDATE_AVAILABLE" == true ]]; then
        local _b_up=$(( lines_up - LIVE_STATS_COUNT - UPDATE_BANNER_OFFSET ))
        if ! _render_update_banner_inplace "$_b_up" "$term_lines" && [[ -z "$buf" ]]; then
          _restore_step_tty; trap - INT TERM; printf "\n"
          _act_out="__refresh__"; return 0
        fi
      fi
      new_lines="$LIVE_STATS_COUNT"
      [[ -n "$tmp_file" && -s "${tmp_file}.meta" ]] && read -r new_lines < "${tmp_file}.meta" || true
      if [[ "$compact_bar" == true ]]; then
        [[ -n "$tmp_file" && -s "${tmp_file}.bar" ]] && _render_live_bar_inplace "$(<"${tmp_file}.bar")"
      elif [[ "$new_lines" =~ ^[0-9]+$ ]] && (( new_lines != LIVE_STATS_COUNT )); then
        if [[ -z "$buf" ]]; then
          _restore_step_tty; trap - INT TERM; printf "\n"
          _act_out="__refresh__"; return 0
        fi
      elif [[ -n "$tmp_file" && -s "$tmp_file" ]]; then
        stats_block="$(<"$tmp_file")"
        _render_live_stats_inplace "$lines_up" "$term_lines" "$stats_block"
      fi
    else
      _restore_step_tty
      trap - INT TERM
      printf "\n"
      exit 0
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
    body_lines="$(printf "%s" "$body" | wc -l)"
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

  _restore_index_tty() {
    if [[ -n "$saved_tty" ]]; then
      stty "$saved_tty" 2>/dev/null || stty echo 2>/dev/null || true
    else
      stty echo 2>/dev/null || true
    fi
  }
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
        IFS= read -rsn2 -t 0.01 esc_seq || true
        if [[ -z "$esc_seq" && -n "$buf" ]]; then
          while [[ -n "$buf" ]]; do
            buf="${buf%?}"
            printf "\b \b"
          done
          continue
        fi
        if [[ "$esc_seq" == \[* || "$esc_seq" == O* ]] && [[ ! "$esc_seq" =~ [A-Za-z~]$ ]]; then
          local _esc_ch="" _esc_n=0
          while (( _esc_n++ < 8 )) && IFS= read -rsn1 -t 0.01 _esc_ch; do
            [[ "$_esc_ch" =~ [A-Za-z~] ]] && break
          done
        fi
        local n_opt="${#ACTIVE_STEPS[@]}"
        local total_rows=$(( 2 + n_opt ))
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
      load_strata_update_state
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

# Relative performance/utility rating per step on a 5-point scale (0 = no rating/stars, 1 = 1 star, 5 = 5 stars).
declare -A STEP_GAIN_PTS=(
  [nvidia_fabricmanager]=5
  [gpu_unlock]=5
  [amd_apu_memory]=5
  [amd_cwsr_disable]=4
  [nvidia_mig_disable]=4
  [nvidia_sm70_table]=4
  [nvidia_pstate]=4
  [gpu_groups]=4
  [intel_compute_stack]=4
  [lact_overclock]=4
  [jetson_perf]=4
  [nvidia_power_limit]=2
  [nvidia_power_cap]=3
  [pcie_acs_disable]=3
  [amd_instinct_partition]=3
  [amd_gpu_perf]=4
  [intel_gpu_perf]=4
  [ryzenadj_tdp]=4
  [nvidia_ecc]=4
  [nvidia_compute_mode]=3
  [headless_target]=4
  [numactl_interleave]=3
  [amd_x3d_mode]=4
  [intel_rapl]=4
  [msi_cooling]=4
  [lenovo_legion]=4
  [jetson_fan]=3
  [asus_perf]=3
  [dell_thermal]=3
  [system76_perf]=3
  [tuxedo_perf]=3
  [acpi_platform_profile]=3
  [intel_pcore_pinning]=3
  [zram_swap]=3
  [numa_balancing]=2
  [sysctl_tuning]=3
  [memlock_realtime]=3
  [nvme_tuning]=3
  [nvidia_persistenced]=2
  [nvidia_powerd]=2
  [intel_thermald]=2
  [iommu_pt]=2
  [scx_scheduler]=2
  [net_tuning]=2
  [irq_balance]=2
  [prevent_sleep]=1
  [hugepages_1g]=1
  [cpu_performance]=1
  [cstate_limit]=1
  [pcie_aspm]=1
  [nvidia_clock_lock]=1
  [tuned_profile]=1
)

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

format_strata_row() {
  local s_idx="$1" selected="${2:-false}"
  local opt="${ACTIVE_STRATA_OPTIONS[$s_idx]}"
  local badge title_txt ptr row_tag
  badge="$("badge_strata_${opt}")"
  title_txt="$("title_strata_${opt}")"
  if [[ "$selected" == true ]]; then
    ptr="${C_CYAN}>${C_RESET}"
    row_tag="${C_CYAN}${C_BOLD}s$((s_idx + 1))${C_RESET}"
    title_txt="${C_CYAN}${C_BOLD}${title_txt}${C_RESET}"
  else
    ptr=" "
    row_tag="s$((s_idx + 1))"
  fi
  printf "%b %b  | %b | %b" "$ptr" "$row_tag" "$badge" "$title_txt"
}

render_any_index_row() {
  local idx="$1" selected="${2:-false}"
  if (( idx == 0 )); then
    format_stats_toggle_row "$selected"
  elif (( idx == 1 )); then
    format_strata_toggle_row "$selected"
  else
    format_index_row "$((idx - 2))" "$selected"
  fi
}

index_row_up_offset() {
  local idx="$1" n_opt="$2" n_str="$3" footer_menu_lines="$4" toggle_up="${5:-0}"
  if (( idx == 0 )); then
    echo "$toggle_up"
  elif (( idx == 1 )); then
    echo $(( toggle_up - 2 ))
  else
    local o_idx=$(( idx - 2 ))
    local leg_lines=$(( INDEX_LEGEND_LINES > 0 ? INDEX_LEGEND_LINES + 1 : 0 ))
    echo $(( (n_opt - o_idx) + leg_lines + footer_menu_lines ))
  fi
}

show_stats_page() {
  while true; do
    print_header stats
    local body=""
    body+="$(echo -e "  ${C_DIM}Live-updating every 1s. Press ${C_BOLD}[i / b / Enter / Esc]${C_RESET}${C_DIM} to return to Index, or ${C_BOLD}[q]${C_RESET}${C_DIM} to Quit.${C_RESET}")"$'\n\n'
    printf "%s" "$body"
    local body_lines lines_up action=""
    body_lines="$(printf "%s" "$body" | wc -l)"
    lines_up=$(( LIVE_STATS_COUNT + POST_HEADER_LINES + body_lines ))
    read_step_action action "$lines_up"
    case "$action" in
      __refresh__) ;;
      __esc__|""|b|B|i|I) return 0 ;;
      q|Q) exit 0 ;;
      u|U)
        if [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
          run_strata_option "update" true
        fi
        ;;
      *) ;;
    esac
  done
}

STRATA_PAGE_SELECTED=0

read_strata_page_choice() {
  local -n _out_var="$1"
  local footer_lines="${2:-0}"
  local n_str="${#ACTIVE_STRATA_OPTIONS[@]}"
  if [[ ! -t 1 || ! -t 0 ]]; then
    read -r -p "Select action: " _out_var || exit 0
    return 0
  fi

  local term_lines=40
  term_lines="$(tput lines 2>/dev/null || echo 40)"

  local init_upd="$STRATA_UPDATE_AVAILABLE"
  local cur_running_url="$STRATA_RUNNING_URL" cur_running_preset="$STRATA_RUNNING_PRESET" cur_svc_active="0"
  unit_active strata.service && cur_svc_active="1"

  local tmp_file="" poller_pid=""
  tmp_file="$(mktemp /tmp/strata-page.XXXXXX 2>/dev/null || echo "")"
  if [[ -n "$tmp_file" ]]; then
    (
      trap 'exit 0' TERM INT
      while true; do
        sleep 2 &
        wait $! 2>/dev/null || exit 0
        refresh_strata_running
        local _svc="0"
        unit_active strata.service && _svc="1"
        printf '%s|%s|%s\n' "$STRATA_RUNNING_URL" "$STRATA_RUNNING_PRESET" "$_svc" > "${tmp_file}.tmp" 2>/dev/null || true
        mv -f "${tmp_file}.tmp" "$tmp_file" 2>/dev/null || true
      done
    ) &
    poller_pid=$!
    ACTIVE_SAMPLER_PID="$poller_pid"
    ACTIVE_SAMPLER_TMP="$tmp_file"
  fi

  local saved_tty=""
  saved_tty="$(stty -g 2>/dev/null || true)"
  stty -echo 2>/dev/null || true

  _cleanup_strata_tty() {
    [[ -n "$poller_pid" ]] && { kill "$poller_pid" 2>/dev/null || true; wait "$poller_pid" 2>/dev/null || true; poller_pid=""; }
    [[ -n "$tmp_file" ]] && { rm -f "$tmp_file" "${tmp_file}.tmp" 2>/dev/null || true; tmp_file=""; }
    ACTIVE_SAMPLER_PID="" ACTIVE_SAMPLER_TMP=""
    if [[ -n "$saved_tty" ]]; then
      stty "$saved_tty" 2>/dev/null || stty echo 2>/dev/null || true
    else
      stty echo 2>/dev/null || true
    fi
  }
  trap '_cleanup_strata_tty; exit 0' INT TERM

  local buf="" ch="" rc=0
  printf "Select action: "
  while true; do
    rc=0
    IFS= read -rsn1 -t 1 ch || rc=$?
    if (( rc == 0 )); then
      if [[ -z "$ch" ]]; then
        _cleanup_strata_tty
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
        IFS= read -rsn2 -t 0.01 esc_seq || true
        if [[ -z "$esc_seq" ]]; then
          if [[ -n "$buf" ]]; then
            while [[ -n "$buf" ]]; do
              buf="${buf%?}"
              printf "\b \b"
            done
            continue
          fi
          _cleanup_strata_tty
          trap - INT TERM
          printf "\n"
          _out_var="__esc__"
          return 0
        fi
        if [[ "$esc_seq" == \[* || "$esc_seq" == O* ]] && [[ ! "$esc_seq" =~ [A-Za-z~]$ ]]; then
          local _esc_ch="" _esc_n=0
          while (( _esc_n++ < 8 )) && IFS= read -rsn1 -t 0.01 _esc_ch; do
            [[ "$_esc_ch" =~ [A-Za-z~] ]] && break
          done
        fi
        if (( footer_lines > 0 && n_str > 0 )); then
          local old_idx="$STRATA_PAGE_SELECTED" new_idx="$STRATA_PAGE_SELECTED"
          if [[ "$esc_seq" == "[A" || "$esc_seq" == "OA" ]]; then
            new_idx=$(( (old_idx - 1 + n_str) % n_str ))
          elif [[ "$esc_seq" == "[B" || "$esc_seq" == "OB" ]]; then
            new_idx=$(( (old_idx + 1) % n_str ))
          fi
          if (( new_idx != old_idx )); then
            STRATA_PAGE_SELECTED="$new_idx"
            local old_up=$(( (n_str - old_idx) + footer_lines ))
            local new_up=$(( (n_str - new_idx) + footer_lines ))
            if (( old_up < term_lines && new_up < term_lines )); then
              local old_row new_row
              old_row="$(format_strata_row "$old_idx" false)"
              new_row="$(format_strata_row "$new_idx" true)"
              printf "\033[?2026h\033[?25l\033[s\033[%dA\r\033[2K%s\033[u\033[s\033[%dA\r\033[2K%s\033[u\033[?25h\033[?2026l" \
                "$old_up" "$old_row" "$new_up" "$new_row"
            else
              _cleanup_strata_tty
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
          if [[ "$ch" =~ ^[uUhHiIbBqQsS]$ ]] || { [[ "$ch" =~ ^[1-9]$ ]] && (( 10#$ch <= n_str )); }; then
            accept=true
          fi
        elif [[ "$buf" =~ ^[sS]$ ]]; then
          if [[ "$ch" =~ ^[1-9]$ ]] && (( 10#$ch <= n_str )); then
            accept=true
          fi
        fi
        if [[ "$accept" == true ]]; then
          buf+="$ch"
          printf "%s" "$ch"
        fi
      fi
    elif (( rc > 128 )); then
      load_strata_update_state
      if [[ "$init_upd" == false && "$STRATA_UPDATE_AVAILABLE" == true ]] && [[ -z "$buf" ]]; then
        _cleanup_strata_tty
        trap - INT TERM
        printf "\n"
        _out_var="__refresh__"
        return 0
      fi
      if [[ -n "$tmp_file" && -s "$tmp_file" ]]; then
        local new_running_url="$cur_running_url" new_running_preset="$cur_running_preset" new_svc_active="$cur_svc_active"
        IFS='|' read -r new_running_url new_running_preset new_svc_active < "$tmp_file" || true
        if [[ "$new_running_url" != "$cur_running_url" || "$new_running_preset" != "$cur_running_preset" || "$new_svc_active" != "$cur_svc_active" ]]; then
          cur_running_url="$new_running_url"
          cur_running_preset="$new_running_preset"
          cur_svc_active="$new_svc_active"
          STRATA_RUNNING_URL="$new_running_url"
          STRATA_RUNNING_PRESET="$new_running_preset"
          local s_i row_up row_str is_sel
          for (( s_i = 0; s_i < n_str; s_i++ )); do
            if [[ "${ACTIVE_STRATA_OPTIONS[$s_i]}" == "service" || "${ACTIVE_STRATA_OPTIONS[$s_i]}" == "benchmark" ]]; then
              row_up=$(( (n_str - s_i) + footer_lines ))
              if (( row_up > 0 && row_up < term_lines )); then
                is_sel=false
                (( s_i == STRATA_PAGE_SELECTED )) && is_sel=true
                row_str="$(format_strata_row "$s_i" "$is_sel")"
                printf "\033[?2026h\033[?25l\033[s\033[%dA\r\033[2K%s\033[u\033[?25h\033[?2026l" "$row_up" "$row_str"
              fi
            fi
          done
        fi
      fi
    else
      _cleanup_strata_tty
      trap - INT TERM
      printf "\n"
      exit 0
    fi
  done
}

show_strata_options_page() {
  while true; do
    refresh_strata_bin
    refresh_strata_running
    build_strata_options
    local n_str="${#ACTIVE_STRATA_OPTIONS[@]}"
    if (( n_str == 0 )); then
      STRATA_PAGE_SELECTED=0
    elif (( STRATA_PAGE_SELECTED >= n_str )); then
      STRATA_PAGE_SELECTED=$(( n_str - 1 ))
    elif (( STRATA_PAGE_SELECTED < 0 )); then
      STRATA_PAGE_SELECTED=0
    fi
    print_header

    collect_strata_bench_lines
    local body="" _sl
    for _sl in "${STRATA_BENCH_LINES[@]}"; do
      body+="${_sl}"$'\n'
    done
    if (( ${#STRATA_BENCH_LINES[@]} > 0 )) && [[ -n "${STRATA_BENCH_LINES[-1]}" ]]; then
      body+=$'\n'
    fi
    body+="$(echo -e "${C_BOLD}Strata Options:${C_RESET}")"$'\n\n'
    body+="$(printf "  ${C_BOLD}%-3s | %-15s | %s${C_RESET}" "#" "Status" "Option")"$'\n'
    body+="$(printf "  %s" "----+-----------------+-------------------------------------------------------")"$'\n'
    local s_idx
    for (( s_idx = 0; s_idx < n_str; s_idx++ )); do
      if (( s_idx == STRATA_PAGE_SELECTED )); then
        body+="$(format_strata_row "$s_idx" true)"$'\n'
      else
        body+="$(format_strata_row "$s_idx" false)"$'\n'
      fi
    done

    local footer_lines=5 hist_count s_range="s1" num_range="1"
    (( n_str > 1 )) && { s_range="s1-${n_str}"; num_range="1-${n_str}"; }
    hist_count="$(count_bench_history)"
    body+=$'\n'"$(echo -e "  ${C_BOLD}[${s_range} / ${num_range} / ↑↓+Enter]${C_RESET} Select an option")"$'\n'
    if [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
      body+="$(echo -e "  ${C_BGREEN}[u]${C_RESET} Install Strata update (${STRATA_UPDATE_SUMMARY})")"$'\n'
      ((footer_lines++))
    fi
    if (( hist_count > 0 )); then
      body+="$(echo -e "  ${C_CYAN}[h]${C_RESET} Benchmark history & restore coupled options (${hist_count})")"$'\n'
      ((footer_lines++))
    fi
    body+="$(echo -e "  ${C_DIM}[i / b / Esc]${C_RESET} Back to Index")"$'\n'
    body+="$(echo -e "  ${C_BOLD}[q]${C_RESET} Quit")"$'\n\n'

    printf "%s" "$body"
    local choice=""
    read_strata_page_choice choice "$footer_lines"
    case "$choice" in
      __refresh__) ;;
      __esc__|i|I|b|B) return 0 ;;
      "")
        (( STRATA_PAGE_SELECTED >= 0 && STRATA_PAGE_SELECTED < n_str )) && run_strata_option "${ACTIVE_STRATA_OPTIONS[$STRATA_PAGE_SELECTED]}"
        ;;
      u|U)
        if [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
          run_strata_option "update" true
        else
          echo -e "${C_YELLOW}No Strata update available.${C_RESET}"; sleep 1
        fi
        ;;
      h|H) show_benchmark_history ;;
      q|Q) exit 0 ;;
      s[1-9]|S[1-9])
        local sn=$(( 10#${choice:1} - 1 ))
        if (( sn >= 0 && sn < n_str )); then
          run_strata_option "${ACTIVE_STRATA_OPTIONS[$sn]}"
        else
          echo -e "${C_RED}Invalid choice '${choice}'. Cancelled.${C_RESET}"; sleep 1
        fi
        ;;
      [1-9])
        local sn=$(( 10#$choice - 1 ))
        if (( sn >= 0 && sn < n_str )); then
          run_strata_option "${ACTIVE_STRATA_OPTIONS[$sn]}"
        else
          echo -e "${C_RED}Invalid choice '${choice}'. Cancelled.${C_RESET}"; sleep 1
        fi
        ;;
      *)
        echo -e "${C_RED}Invalid choice '${choice}'. Cancelled.${C_RESET}"; sleep 1
        ;;
    esac
  done
}

show_index() {
  while true; do
    refresh_strata_bin
    build_active_steps
    local total_rows=$(( 2 + ${#ACTIVE_STEPS[@]} ))
    if (( total_rows == 0 )); then
      INDEX_SELECTED=0
    elif (( INDEX_SELECTED >= total_rows )); then
      INDEX_SELECTED=$(( total_rows - 1 ))
    elif (( INDEX_SELECTED < 0 )); then
      INDEX_SELECTED=0
    fi
    print_header toggle

    local body="" hw_warns=""
    hw_warns="$(format_strata_hw_warnings)"
    if [[ -n "$hw_warns" ]]; then
      body+="${hw_warns}"$'\n'
      body+="$(echo -e "${C_DIM}          You can still apply any host optimizations applicable to this machine below.${C_RESET}")"$'\n\n'
    fi

    body+="$(echo -e "${C_BOLD}Optimization Index (Applicable to this machine):${C_RESET}")"$'\n\n'
    body+="$(printf "  ${C_BOLD}%-3s | %-13s | %-74s | %-9s | %s${C_RESET}" "#" "Status" "Optimization" "Potential" "")"$'\n'
    body+="$(printf "  %s" "----+---------------+----------------------------------------------------------------------------+-----------+-----")"$'\n'
    local idx
    for (( idx = 0; idx < ${#ACTIVE_STEPS[@]}; idx++ )); do
      if (( idx + 2 == INDEX_SELECTED )); then
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
    [[ "$has_warn_flag" == true ]] && legend_items+=("$(echo -e "${C_YELLOW}[!]${C_RESET} ${C_DIM}Higher idle power, minimal gain${C_RESET}")")
    [[ "$has_opt_flag" == true ]] && legend_items+=("$(echo -e "${C_BLUE}[OPT]${C_RESET} ${C_DIM}Opt-in trade-off (power cap / partitioning / RAM reserve)${C_RESET}")")
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

    local footer_lines=9 hist_count
    hist_count="$(count_bench_history)"
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
    local -a excl_parts=("high-idle-power options")
    [[ "$has_opt_flag" == true ]] && excl_parts+=("opt-in trade-offs")
    [[ "$has_exp_flag" == true ]] && excl_parts+=("experimental options")
    local rec_excl="${excl_parts[0]}"
    if (( ${#excl_parts[@]} == 2 )); then
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
    body_lines="$(printf "%s" "$body" | wc -l)"
    toggle_up=$(( 1 + POST_HEADER_LINES + body_lines ))
    read_choice_with_live_stats choice "$footer_lines" "$toggle_up"

    case "$choice" in
      __refresh__) ;;
      "")
        if (( INDEX_SELECTED == 0 )); then
          show_stats_page
        elif (( INDEX_SELECTED == 1 )); then
          show_strata_options_page
        else
          run_step_view $(( INDEX_SELECTED - 2 )) "single"
        fi
        ;;
      c|C) show_check_page ;;
      u|U)
        if [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
          run_strata_option "update" true
        else
          echo -e "${C_YELLOW}No Strata update available.${C_RESET}"; sleep 1
        fi
        ;;
      h|H) show_benchmark_history ;;
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
        confirm_yn "Reboot this system now? [y/N]: " "N" && { if [[ "$HAS_SYSTEMD" == true ]]; then run_root systemctl reboot; else run_root reboot; fi; exit 0; }
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
  stop_strata_update_poller
  stop_bench_power_sampler
  [[ -n "$BENCH_POWER_TMP_FILE" ]] && rm -f "$BENCH_POWER_TMP_FILE" 2>/dev/null || true
  if [[ -n "$ACTIVE_SAMPLER_PID" ]]; then
    kill "$ACTIVE_SAMPLER_PID" 2>/dev/null || true
    wait "$ACTIVE_SAMPLER_PID" 2>/dev/null || true
    ACTIVE_SAMPLER_PID=""
  fi
  if [[ -n "$ACTIVE_SAMPLER_TMP" ]]; then
    rm -f "$ACTIVE_SAMPLER_TMP" "${ACTIVE_SAMPLER_TMP}.tmp" "${ACTIVE_SAMPLER_TMP}.meta" "${ACTIVE_SAMPLER_TMP}.meta.tmp" 2>/dev/null || true
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
optimizations for running Strata LLM inference.

Options:
  --check                 Run hardware, OS, Strata, and step-applicability
                          detection in read-only mode, print a summary, and exit
                          without modifying the system or prompting for sudo.
  --strata-api-key KEY    API key used for all requests to Strata (live /metrics
                          polling, 'strata bench run' benchmarking, and Strata
                          CLI calls); overrides the STRATA_API_KEY environment
                          variable if set.
  -h, --help              Show this help message and exit.

Environment:
  STRATA_API_KEY          Fallback API key used for all Strata requests when
                          --strata-api-key is not provided.
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
    pcie_aspm)           [[ -f /etc/udev/rules.d/99-strata-pcie-aspm.rules ]] || grep -q "pcie_aspm=off" /proc/cmdline 2>/dev/null ;;
    *)                   return 0 ;;
  esac
}

print_check_summary() {
  build_active_steps

  local init_desc="systemd"
  [[ "$HAS_SYSTEMD" != true ]] && init_desc="non-systemd"
  local platform_tags=()
  [[ "$IS_UNRAID" == true ]] && platform_tags+=("Unraid")
  [[ "$IS_TRUENAS" == true ]] && platform_tags+=("TrueNAS")
  [[ "$IS_SYNOLOGY" == true ]] && platform_tags+=("Synology")
  [[ "$IS_JETSON" == true ]] && platform_tags+=("Jetson")
  [[ -n "$IS_VIRT" ]] && platform_tags+=("VM:${IS_VIRT}")
  local tag_str=""
  [[ ${#platform_tags[@]} -gt 0 ]] && tag_str=" (${platform_tags[*]})"

  local strata_desc="not detected"
  if [[ -n "$STRATA_BIN" ]]; then
    strata_desc="installed (${STRATA_VERSION:-unknown} at ${STRATA_BIN})"
  elif [[ -n "$STRATA_DOCKER_CONTAINER" ]]; then
    local memlock_st="not set (pass --ulimit memlock=-1:-1)"
    status_memlock_realtime && memlock_st="unlimited (-1:-1)"
    local img_part=""
    [[ -n "$STRATA_DOCKER_IMAGE" ]] && img_part=", image: ${STRATA_DOCKER_IMAGE}"
    strata_desc="Docker container (${STRATA_DOCKER_CONTAINER}${img_part}, memlock: ${memlock_st})"
  fi

  echo -e "${C_BOLD}System:${C_RESET}"
  echo "  OS:       ${OS_PRETTY:-Unknown} (family: ${DISTRO_FAMILY}, kernel: ${KERNEL_VER:-unknown})"
  echo "  Init:     ${init_desc}${tag_str}"
  echo "  CPU:      ${CPU_SUMMARY:-Unknown} (sockets: ${CPU_SOCKETS}, NUMA nodes: ${NUMA_NODES})"
  echo "  RAM:      ${RAM_GB} GiB${RAM_DETAILS}"
  echo "  GPU(s):   ${GPU_SUMMARY:-Unknown}"
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
        if _amd_gfx_covered_by_local_hip "$_ag"; then
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
  echo "  Strata:   ${strata_desc}"
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
    refresh_strata_bin
    print_header
    local body=""
    body+="$(echo -e "${C_BOLD}Read-Only Detection & Applicability Summary${C_RESET}")"$'\n\n'
    body+="$(print_check_summary)"$'\n\n'
    body+="$(echo -e "  ${C_DIM}Read-only summary. Press ${C_BOLD}[i / b / Enter / Esc]${C_RESET}${C_DIM} to return to Index, or ${C_BOLD}[q]${C_RESET}${C_DIM} to Quit.${C_RESET}")"$'\n\n'
    printf "%s" "$body"
    local body_lines lines_up action=""
    body_lines="$(printf "%s" "$body" | wc -l)"
    lines_up=$(( LIVE_STATS_COUNT + POST_HEADER_LINES + body_lines ))
    read_step_action action "$lines_up"
    case "$action" in
      __refresh__) ;;
      __esc__|""|b|B|i|I) return 0 ;;
      q|Q) exit 0 ;;
      u|U)
        if [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
          run_strata_option "update" true
        fi
        ;;
      *) ;;
    esac
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=true ;;
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

trap 'cleanup_all_on_exit' EXIT
if [[ "$CHECK_ONLY" == true ]]; then
  detect_environment
  run_check_mode
  exit 0
fi

if [[ $EUID -ne 0 && -t 0 ]] && command -v sudo >/dev/null 2>&1 && ! sudo -n true >/dev/null 2>&1; then
  echo -e "${C_DIM}Sudo access is used for hardware sensors (RAPL CPU power, DMI RAM info) and applying optimizations.${C_RESET}"
  sudo -v || true
fi
detect_platform_basics
ensure_script_tools
detect_environment
start_strata_update_poller
show_index
