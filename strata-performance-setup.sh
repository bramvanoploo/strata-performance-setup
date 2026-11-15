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
  C_RED='\033[0;31m' C_GREEN='\033[0;32m' C_BGREEN='\033[1;32m' C_YELLOW='\033[0;33m' C_CYAN='\033[0;36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_BGREEN='' C_YELLOW='' C_CYAN=''
fi

TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
[[ -n "$TARGET_HOME" ]] || TARGET_HOME="$HOME"
STRATA_BIN="" STRATA_VERSION="" STRATA_RUNNING_PRESET="" STRATA_RUNNING_URL=""
DISTRO_FAMILY="unknown" DISTRO_ID="unknown" OS_PRETTY="" KERNEL_VER="" AUR_HELPER="" HAS_SYSTEMD=true
HAS_NVIDIA=false HAS_NVIDIA_POWERD=false HAS_AMD=false HAS_INTEL_GPU=false HAS_INTEL_ARC=false
HAS_NVIDIA_TESLA=false HAS_NVIDIA_NON_TESLA=false NVIDIA_COMPUTE_MODE_NON_DEFAULT=false
GPU_SUMMARY="" GPU_RAW="" CPU_SUMMARY="" RAM_GB=0 RAM_DETAILS="" NVIDIA_VRAM_MB=0 TOTAL_VRAM_MB=0
HAS_MSI_EC=false SYS_VENDOR="" PRODUCT_NAME="" IS_LAPTOP=false HAS_ASPM=false
IS_JETSON=false IS_JETSON_TX2=false JETSON_MODEL="" JETSON_L4T_REL="" JETSON_SOC=""
NVIDIA_DEFAULT_PL="" NVIDIA_MAX_PL="" NVIDIA_CURRENT_PL=""
NVIDIA_MAX_GFX_CLK="" NVIDIA_MAX_MEM_CLK="" NVIDIA_ECC_CUR="" NVIDIA_ECC_PEND=""
IS_VIRT="" NUMA_NODES=1 CPU_SOCKETS=1 DISCRETE_GPU_COUNT=0 DMI_MEM_CACHE=""
declare -a RAM_HEALTH_LINES=() GPU_TOPO_LINES=()
declare -a NVIDIA_GPU_INDICES=() NVIDIA_GPU_NAMES=() NVIDIA_GPU_CUR_PL=() NVIDIA_GPU_DEF_PL=() NVIDIA_GPU_MAX_PL=() NVIDIA_GPU_VRAM=() NVIDIA_GPU_COMPUTE_MODE=() NVIDIA_GPU_IS_TESLA=() NVIDIA_GPU_PL_SUPPORTED=()
declare -a NVIDIA_GPU_MAX_GFX_CLK=() NVIDIA_GPU_MAX_MEM_CLK=() NVIDIA_ECC_INDICES=()
RYZENADJ_MARKER="/etc/strata-ryzenadj.prev" RAPL_MARKER="/etc/strata-rapl.prev" TUNED_MARKER="/etc/strata-tuned.prev" NUMACTL_MARKER="/etc/strata-numactl.enabled"
HEADLESS_MARKER="/etc/strata-headless.prev" PSTATE_MARKER="/etc/strata-pstate.prev" GPU_GROUPS_MARKER="/etc/strata-gpu-groups.added"
NVIDIA_COMPUTE_PREV_MARKER="/etc/strata-nvidia-compute-mode.prev"
REBOOT_REQUIRED=false REBOOT_PROMPT_PENDING=false
PREV_CPU_TOTAL="" PREV_CPU_IDLE="" PREV_RAPL_UJ="" PREV_RAPL_US="" LIVE_STATS_COUNT=0 POST_HEADER_LINES=0
TERM_COLS_CACHED=120 LIVE_COMPACT_SYS="" LIVE_COMPACT_STRATA=""
declare -a LIVE_STAT_LINES=() SYS_INFO_LINES=() STRATA_STAT_LINES=() STRATA_BENCH_LINES=()
STRATA_BENCH_CACHE_KEY=""
BENCH_HISTORY_COUNT_KEY="" BENCH_HISTORY_COUNT_CACHE=0
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
  if [[ $EUID -eq 0 ]]; then "$@"
  else sudo "$@"; fi
}

run_as_user() {
  if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$TARGET_USER" -- bash -c "$*"
    else
      su - "$TARGET_USER" -c "$*"
    fi
  else
    bash -c "$*"
  fi
}

# Argument-safe execution as TARGET_USER without extra shell interpolation.
run_as_user_exec() {
  if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$TARGET_USER" -- "$@"
    else
      local cmd=""
      printf -v cmd '%q ' "$@"
      su - "$TARGET_USER" -c "$cmd"
    fi
  else
    "$@"
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

service_installed() {
  local unit="$1"
  if [[ "$HAS_SYSTEMD" == true ]]; then
    [[ -f "/etc/systemd/system/${unit}" ]]
  else
    [[ -x "/etc/rc.d/rc.strata.${unit%.service}" ]]
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
  local content start_cmds="" stop_cmds="" line cmd ignore_err
  content="$(cat)"
  while IFS= read -r line; do
    if [[ "$line" =~ ^ExecStart=(.*)$ ]]; then
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
case "\$1" in
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
  if [[ ! -f /etc/rc.d/rc.local ]]; then
    printf '#!/bin/sh\n' | run_root tee /etc/rc.d/rc.local >/dev/null
  fi
  run_root chmod +x /etc/rc.d/rc.local
  local hook="[ -x ${rc_script} ] && ${rc_script} start # strata:${name}"
  if ! grep -qF "# strata:${name}" /etc/rc.d/rc.local 2>/dev/null; then
    [[ -s /etc/rc.d/rc.local && -n "$(tail -c1 /etc/rc.d/rc.local 2>/dev/null)" ]] && printf '\n' | run_root tee -a /etc/rc.d/rc.local >/dev/null
    printf '%s\n' "$hook" | run_root tee -a /etc/rc.d/rc.local >/dev/null
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

  local name="${unit%.service}" rc_script="/etc/rc.d/rc.strata.${unit%.service}"
  if [[ -x "$rc_script" ]]; then
    run_root "$rc_script" stop >/dev/null 2>&1 || true
  fi
  run_root rm -f "$rc_script"
  if [[ -f /etc/rc.d/rc.local ]] && grep -qF "# strata:${name}" /etc/rc.d/rc.local 2>/dev/null; then
    local tmp_rc
    tmp_rc="$(awk -v tag="# strata:${name}" 'index($0, tag) == 0 {print}' /etc/rc.d/rc.local)"
    printf '%s\n' "$tmp_rc" | run_root tee /etc/rc.d/rc.local >/dev/null
  fi
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
      debian)    [[ "$mode" == "repo" ]] && apt-cache show "$pkg" >/dev/null 2>&1 && rc=0 ;;
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
    debian)    run_root apt-get update -qq && run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" || rc=$? ;;
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
  IS_JETSON=false IS_JETSON_TX2=false JETSON_MODEL="" JETSON_L4T_REL="" JETSON_SOC=""
  local dt_model="" dt_compat="" tegra_rel=""
  [[ -r /proc/device-tree/model ]] && dt_model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
  [[ -r /proc/device-tree/compatible ]] && dt_compat="$(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null || true)"
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
  if grep -qi "nvidia,tegra186" <<< "$dt_compat" || grep -qiE "t186ref|t186" <<< "$tegra_rel" || grep -qiE "TX2|quill|storm|lanai" <<< "$dt_model"; then
    IS_JETSON_TX2=true
    JETSON_SOC="tegra186"
    if [[ -z "$dt_model" || "$dt_model" =~ ^(quill|storm|lanai|p2771|p3636) ]]; then
      JETSON_MODEL="NVIDIA Jetson TX2"
    fi
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
    elif [[ "$DISTRO_ID" == "slackware" ]] || [[ "$id_like" == *slackware* ]]; then
      DISTRO_FAMILY="slackware"
    fi
  elif [[ -r /etc/slackware-version ]]; then
    DISTRO_ID="slackware"
    DISTRO_FAMILY="slackware"
    OS_PRETTY="$(cat /etc/slackware-version 2>/dev/null || echo "Slackware Linux")"
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
  [[ "$DISTRO_FAMILY" != "unknown" ]] || return 0
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

detect_environment() {
  detect_platform_basics

  if command -v nvidia-smi >/dev/null 2>&1; then
    local nv_q
    nv_q="$(nvidia-smi --query-gpu=index,name,power.limit,power.default_limit,power.max_limit,memory.total,compute_mode --format=csv,noheader,nounits 2>/dev/null || true)"
    if [[ -n "$nv_q" ]]; then
      HAS_NVIDIA=true
      NVIDIA_GPU_INDICES=() NVIDIA_GPU_NAMES=() NVIDIA_GPU_CUR_PL=() NVIDIA_GPU_DEF_PL=() NVIDIA_GPU_MAX_PL=() NVIDIA_GPU_VRAM=() NVIDIA_GPU_COMPUTE_MODE=() NVIDIA_GPU_IS_TESLA=() NVIDIA_GPU_PL_SUPPORTED=()
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
        if grep -qi "tesla" <<<"$g_name"; then
          is_tesla=true
          HAS_NVIDIA_TESLA=true
        else
          HAS_NVIDIA_NON_TESLA=true
        fi
        pl_ok=false
        if [[ -n "$g_def" && -n "$g_mx" && "$g_mx" -gt "$g_def" ]] && ! grep -qiE "Laptop GPU|Mobile|Max-Q" <<<"$g_name"; then
          pl_ok=true
          if (( EUID == 0 )) && [[ -n "$g_cur" ]] && grep -qi "not supported" <<<"$(nvidia-smi -i "$g_idx" -pl "$g_cur" 2>&1 || true)"; then
            pl_ok=false
          fi
        fi
        NVIDIA_GPU_INDICES+=("$g_idx")
        NVIDIA_GPU_NAMES+=("$g_name")
        NVIDIA_GPU_CUR_PL+=("$g_cur")
        NVIDIA_GPU_DEF_PL+=("$g_def")
        NVIDIA_GPU_MAX_PL+=("$g_mx")
        NVIDIA_GPU_VRAM+=("$g_vram")
        NVIDIA_GPU_COMPUTE_MODE+=("$g_cmode")
        NVIDIA_GPU_IS_TESLA+=("$is_tesla")
        NVIDIA_GPU_PL_SUPPORTED+=("$pl_ok")
        [[ -n "$g_cmode" && "$g_cmode" != "Default" ]] && NVIDIA_COMPUTE_MODE_NON_DEFAULT=true
        [[ "$g_vram" =~ ^[0-9]+$ ]] && nv_vram_sum=$((nv_vram_sum + g_vram))
        if [[ -n "$g_def" && -n "$g_mx" && "$g_mx" -gt "$g_def" ]]; then
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
    fi
  fi
  local gpu_lines
  gpu_lines="$(lspci 2>/dev/null | grep -iE "vga|3d|display" || true)"
  if [[ "$HAS_NVIDIA" == false ]] && grep -qi "nvidia" <<< "$gpu_lines"; then
    HAS_NVIDIA=true
  fi
  if [[ "$HAS_NVIDIA_TESLA" == false ]] && grep -qiE "nvidia.*tesla|tesla.*(k80|k40|k20|m40|m60|m10|p4|p40|p100|v100|t4)" <<< "$gpu_lines"; then
    HAS_NVIDIA_TESLA=true
  fi
  GPU_RAW="$gpu_lines"
  GPU_SUMMARY="$(echo "$gpu_lines" | sed -E 's/^[^ ]+ [^:]+: //; s/ \((rev|prog-if)[^)]*\)//g; s/.*\[([^][]+)\][[:space:]]*$/\1/' | awk 'NF {s = (s ? s "; " $0 : $0)} END {print s}')"
  [[ -z "$GPU_SUMMARY" ]] && GPU_SUMMARY="Unknown"
  echo "$gpu_lines" | grep -qiE "amd|ati|radeon" && HAS_AMD=true
  if [[ "$HAS_AMD" == true ]]; then
    local vram_file vt
    for vram_file in /sys/class/drm/card*/device/mem_info_vram_total; do
      [[ -r "$vram_file" ]] || continue
      vt="$(cat "$vram_file" 2>/dev/null || echo 0)"
      [[ "$vt" =~ ^[0-9]+$ ]] && (( vt > 0 )) && TOTAL_VRAM_MB=$((TOTAL_VRAM_MB + vt / 1048576))
    done
  fi
  if echo "$gpu_lines" | grep -qi "intel"; then
    HAS_INTEL_GPU=true
    echo "$gpu_lines" | grep -qiE "Arc|DG2|Battlemage|Alchemist" && HAS_INTEL_ARC=true
  fi

  if [[ "$IS_JETSON" == true && "$HAS_NVIDIA" == false ]]; then
    HAS_NVIDIA=true
    if [[ "$IS_JETSON_TX2" == true ]]; then
      GPU_SUMMARY="NVIDIA Tegra X2 (Pascal, 256 CUDA cores, Unified)"
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

  local dev cls ven gn=0
  for dev in /sys/bus/pci/devices/*; do
    cls="$(cat "$dev/class" 2>/dev/null || true)"; [[ "$cls" == 0x03* ]] || continue
    ven="$(cat "$dev/vendor" 2>/dev/null || true)"; [[ "$ven" == "0x10de" || "$ven" == "0x1002" ]] && ((gn++))
  done
  DISCRETE_GPU_COUNT="$gn"

  unit_exists nvidia-powerd.service && HAS_NVIDIA_POWERD=true
  SYS_VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
  PRODUCT_NAME="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
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
        if [[ -n "${NVIDIA_GPU_MAX_PL[$i]}" && -n "${NVIDIA_GPU_DEF_PL[$i]}" && "${NVIDIA_GPU_MAX_PL[$i]}" -gt "${NVIDIA_GPU_DEF_PL[$i]}" ]]; then
          NVIDIA_CURRENT_PL="$g_cur"
        fi
      fi
    done
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

detect_gpu_topology() {
  GPU_TOPO_LINES=()
  local dev cls ven numa n_gpu=0 n_nv=0 nodes=() distinct
  for dev in /sys/bus/pci/devices/*; do
    cls="$(cat "$dev/class" 2>/dev/null || true)"
    [[ "$cls" == 0x03* ]] || continue
    ven="$(cat "$dev/vendor" 2>/dev/null || true)"
    [[ "$ven" == "0x10de" || "$ven" == "0x1002" ]] || continue
    ((n_gpu++))
    [[ "$ven" == "0x10de" ]] && ((n_nv++))
    numa="$(cat "$dev/numa_node" 2>/dev/null || true)"
    [[ "$numa" =~ ^[0-9]+$ ]] && nodes+=("$numa")
  done
  (( n_gpu >= 2 )) || return 0
  if (( ${#nodes[@]} > 1 )); then
    distinct="$(printf '%s\n' "${nodes[@]}" | sort -u | wc -l)"
    (( distinct > 1 )) && GPU_TOPO_LINES+=("$(printf "%bMulti-GPU: %b[!] GPUs sit on %s NUMA nodes (cross-socket traffic; keep a model on one node)%b" "${C_DIM}" "${C_YELLOW}" "$distinct" "${C_RESET}")")
  fi
  if (( n_nv >= 2 )) && command -v nvidia-smi >/dev/null 2>&1; then
    if nvidia-smi nvlink -s 2>/dev/null | grep -q "GB/s"; then
      GPU_TOPO_LINES+=("$(printf "%bMulti-GPU: NVLink active%b" "${C_DIM}" "${C_RESET}")")
    else
      GPU_TOPO_LINES+=("$(printf "%bMulti-GPU: no NVLink (GPU-to-GPU traffic uses PCIe)%b" "${C_DIM}" "${C_RESET}")")
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
  local dev cls ven cs ms cw mw cg mg addr line rebar max_bar s e f size vt
  for dev in /sys/bus/pci/devices/*; do
    cls="$(cat "$dev/class" 2>/dev/null || true)"
    [[ "$cls" == 0x03* ]] || continue
    ven="$(cat "$dev/vendor" 2>/dev/null || true)"
    [[ "$ven" == "0x10de" || "$ven" == "0x1002" || "$ven" == "0x8086" ]] || continue
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
    if [[ "$ven" != "0x8086" || "$HAS_INTEL_ARC" == true ]]; then
      max_bar=0
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
      fi
    fi
    if [[ "$rebar" == "on" ]]; then
      line+=" | ReBAR: on"
    elif [[ "$rebar" == "off" ]]; then
      line+=" | ${C_YELLOW}[!] ReBAR: off${C_RESET}${C_DIM} (enable Resizable BAR in BIOS)"
    fi
    SYS_INFO_LINES+=("$(printf "PCIe:   %b%b%b" "${C_DIM}" "$line" "${C_RESET}")")
  done
}

# ------------------------------------------------------------------------------
# Step Registry
# ------------------------------------------------------------------------------
ALL_STEPS=(
  gpu_unlock amd_apu_memory
  gpu_groups intel_compute_stack lact_overclock jetson_perf jetson_fan
  nvidia_power_limit amd_gpu_perf intel_gpu_perf ryzenadj_tdp nvidia_ecc nvidia_compute_mode
  headless_target numactl_interleave amd_x3d_mode intel_rapl msi_cooling lenovo_legion
  asus_perf dell_thermal system76_perf tuxedo_perf acpi_platform_profile intel_pcore_pinning zram_swap numa_balancing
  sysctl_tuning memlock_realtime nvme_tuning
  nvidia_persistenced nvidia_powerd intel_thermald iommu_pt scx_scheduler
  net_tuning irq_balance
  prevent_sleep hugepages_1g
  cpu_performance cstate_limit pcie_aspm nvidia_clock_lock tuned_profile
)
ACTIVE_STEPS=()

VM_HIDDEN_STEPS=" msi_cooling acpi_platform_profile asus_perf dell_thermal lenovo_legion system76_perf tuxedo_perf cpu_performance cstate_limit pcie_aspm ryzenadj_tdp intel_rapl intel_thermald amd_x3d_mode intel_pcore_pinning tuned_profile jetson_perf jetson_fan "
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

is_recommended_step() {
  case "$1" in
    cpu_performance|pcie_aspm|cstate_limit|nvidia_clock_lock|tuned_profile|hugepages_1g) return 1 ;;
    *) return 0 ;;
  esac
}

run_recommended_batch() {
  local mode="$1" step targets=()
  for step in "${ACTIVE_STEPS[@]}"; do
    is_recommended_step "$step" || continue
    if [[ "$mode" == "apply" ]]; then
      "status_${step}" || targets+=("$step")
    else
      "status_${step}" && targets+=("$step")
    fi
  done

  print_header
  if [[ "$mode" == "apply" ]]; then
    echo -e "${C_BOLD}Apply Recommended Performance Optimizations${C_RESET}"
  else
    echo -e "${C_BOLD}Revert Recommended Performance Optimizations${C_RESET}"
  fi
  echo -e "${C_DIM}Excluded: CPU Performance, PCIe ASPM, CPU C-State Limit, NVIDIA Clock Lock, tuned profile (minimal gain / higher idle power), 1 GiB hugepages (reserves RAM), Strata setup.${C_RESET}\n"

  if [[ ${#targets[@]} -eq 0 ]]; then
    if [[ "$mode" == "apply" ]]; then
      echo -e "${C_GREEN}All recommended optimizations for this machine are already applied.${C_RESET}"
    else
      echo -e "${C_YELLOW}No applied recommended optimizations found to revert.${C_RESET}"
    fi
    pause_prompt
    return 0
  fi

  local i=1
  for step in "${targets[@]}"; do
    echo -e "  $i) $("title_${step}")"
    ((i++))
  done
  echo ""

  local prompt_verb="Apply"
  [[ "$mode" == "revert" ]] && prompt_verb="Revert"
  if ! confirm_yn "${prompt_verb} these ${#targets[@]} recommended optimization(s)? [y/N]: " "N"; then
    echo -e "${C_DIM}Cancelled.${C_RESET}"
    pause_prompt
    return 0
  fi

  for step in "${targets[@]}"; do
    echo -e "\n${C_BOLD}${C_CYAN}>>> ${prompt_verb}ing: $("title_${step}")${C_RESET}"
    "${mode}_${step}" || echo -e "${C_YELLOW}Step '${step}' exited with a warning or was skipped.${C_RESET}"
  done
  echo -e "\n${C_GREEN}Finished ${mode}ing recommended optimizations.${C_RESET}"
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
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '[ -w /sys/firmware/acpi/platform_profile ] && echo performance > /sys/firmware/acpi/platform_profile || true'
ExecStop=/bin/sh -c '[ -w /sys/firmware/acpi/platform_profile ] && echo balanced > /sys/firmware/acpi/platform_profile || true'

[Install]
WantedBy=multi-user.target
EOF
}
revert_acpi_platform_profile() {
  remove_service strata-acpi-profile.service
  run_root sh -c '[ -w /sys/firmware/acpi/platform_profile ] && echo balanced > /sys/firmware/acpi/platform_profile' 2>/dev/null || true
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
  run_root smbios-thermal-ctl --set-thermal-mode=performance 2>/dev/null || true
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
  [[ -f /etc/security/limits.d/99-strata-memlock.conf ]] && return 0
  [[ -f /etc/security/limits.d/99-realtime-privileges.conf ]] && id -nG "$TARGET_USER" 2>/dev/null | grep -qw realtime
}
explain_memlock_realtime() {
  cat <<'EOF'
Impact:
  Grants unlimited locked memory (memlock unlimited) and rtprio/nice limits so
  Strata can pin model weights and KV caches in RAM without swapping.
EOF
}
apply_memlock_realtime() {
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
applicable_nvidia_persistenced() { [[ "$HAS_NVIDIA" == true ]] && unit_exists nvidia-persistenced.service; }
title_nvidia_persistenced() { echo "NVIDIA Persistence Mode (nvidia-persistenced)"; }
status_nvidia_persistenced() { unit_enabled nvidia-persistenced.service && unit_active nvidia-persistenced.service; }
explain_nvidia_persistenced() { echo -e "Impact:\n  Keeps the NVIDIA driver initialized on headless servers to avoid cold-start delays."; }
apply_nvidia_persistenced() { run_root systemctl enable --now nvidia-persistenced.service; }
revert_nvidia_persistenced() { run_root systemctl disable --now nvidia-persistenced.service; }

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
    local i="${idxs[0]}"
    echo "NVIDIA Persistent Max GPU Power Limit (${NVIDIA_GPU_DEF_PL[$i]}W -> ${NVIDIA_GPU_MAX_PL[$i]}W)"
  else
    echo "NVIDIA Persistent Max GPU Power Limit (${#idxs[@]} GPUs)"
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
  local idxs=() i
  mapfile -t idxs < <(nvidia_tunable_pl_indices)
  if (( ${#idxs[@]} == 1 )); then
    i="${idxs[0]}"
    echo -e "Impact:\n  Raises GPU power ceiling from ${NVIDIA_GPU_DEF_PL[$i]}W to ${NVIDIA_GPU_MAX_PL[$i]}W via persistent systemd service."
  else
    echo -e "Impact:\n  Raises GPU power ceilings to maximum per GPU via persistent systemd service:"
    for i in "${idxs[@]}"; do
      echo -e "  - GPU ${NVIDIA_GPU_INDICES[$i]} (${NVIDIA_GPU_NAMES[$i]}): ${NVIDIA_GPU_DEF_PL[$i]}W -> ${NVIDIA_GPU_MAX_PL[$i]}W"
    done
  fi
}
apply_nvidia_power_limit() {
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

# 10. LACT GPU Overclocking
applicable_lact_overclock() {
  [[ "$IS_JETSON" == true ]] && return 1
  [[ "$HAS_NVIDIA" == true || "$HAS_AMD" == true ]] || return 1
  if [[ "$HAS_AMD" == false && "$HAS_INTEL_GPU" == false && "$HAS_NVIDIA_TESLA" == true && "$HAS_NVIDIA_NON_TESLA" == false ]]; then
    return 1
  fi
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
applicable_gpu_unlock() {
  [[ "$HAS_NVIDIA" == true && "$DISTRO_FAMILY" == "arch" ]] || return 1
  [[ "$HAS_NVIDIA_TESLA" == true && "$HAS_NVIDIA_NON_TESLA" == false ]] && return 1
  grep -qiE "TU10|TU11|GA10|AD10|RTX 20|RTX 30|RTX 40|GTX 16|A100|A10|A40|L40|RTX A" <<< "${GPU_RAW:-$GPU_SUMMARY}" || return 1
  pkg_installed gpu-unlock-dkms || pkg_available repo gpu-unlock-dkms || pkg_available aur gpu-unlock-dkms
}
title_gpu_unlock() { echo "NVIDIA GPU Unlock Module & Kernel Param (gpu-unlock-dkms)"; }
status_gpu_unlock() { has_kernel_param "gpu_unlock.targets=all" && ([[ -d /sys/module/gpu_unlock ]] || lsmod 2>/dev/null | grep -E "gpu_unlock" >/dev/null || pkg_installed gpu-unlock-dkms); }
explain_gpu_unlock() {
  cat <<'EOF'
Impact:
  Installs gpu-unlock-dkms + gpu-unlock-firmware and adds
  'gpu_unlock.targets=all' to the bootloader kernel command line.
EOF
  echo -e "\n${C_BGREEN}[HIGH IMPACT] Big performance gains can be achieved with gpu-unlock on${C_RESET}"
  echo -e "${C_BGREEN}              supported Turing/Ampere/Ada GPUs (RTX 20/30/40 series),${C_RESET}"
  echo -e "${C_BGREEN}              unlocking hardware compute, clock, and power capabilities.${C_RESET}"
}
apply_gpu_unlock() {
  if ! pkg_installed gpu-unlock-dkms; then
    prompt_install_repo_or_aur gpu-unlock-dkms gpu-unlock-firmware || return 0
  fi
  add_kernel_param "gpu_unlock.targets=all"
}
revert_gpu_unlock() { remove_kernel_param "gpu_unlock.targets=all"; }

# 11b. AMD GPU DPM
applicable_amd_gpu_perf() { [[ "$HAS_AMD" == true ]] && compgen -G "/sys/class/drm/card*/device/power_dpm_force_performance_level" >/dev/null 2>&1; }
title_amd_gpu_perf() { echo "AMD Radeon GPU High Performance DPM Level (amdgpu)"; }
status_amd_gpu_perf() {
  local f
  for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
    [[ -f "$f" ]] && grep -q "high" "$f" 2>/dev/null && return 0
  done
  return 1
}
explain_amd_gpu_perf() { echo -e "Impact:\n  Sets amdgpu power_dpm_force_performance_level='high' via systemd for ROCm/HIP."; }
apply_amd_gpu_perf() {
  install_service strata-amd-gpu-perf.service <<'EOF'
[Unit]
Description=Set AMD GPU DPM Performance Level to High for Strata
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do [ -w "$f" ] && echo high > "$f"; done; true'
ExecStop=/bin/sh -c 'for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do [ -w "$f" ] && echo auto > "$f"; done; true'

[Install]
WantedBy=multi-user.target
EOF
}
revert_amd_gpu_perf() {
  remove_service strata-amd-gpu-perf.service
  run_root sh -c 'for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do [ -w "$f" ] && echo auto > "$f"; done' 2>/dev/null || true
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
title_numa_balancing() { echo "Disable Automatic NUMA Balancing ($(cpu_socket_count) socket(s), $(numa_node_count) NUMA nodes)"; }
status_numa_balancing() {
  [[ -f /etc/sysctl.d/99-strata-numa.conf ]] && [[ "$(cat /proc/sys/kernel/numa_balancing 2>/dev/null)" == "0" ]]
}
explain_numa_balancing() {
  echo -e "Impact:\n  Sets kernel.numa_balancing=0 (persistent via /etc/sysctl.d/99-strata-numa.conf).\n  Stops the kernel from periodically unmapping pages to migrate them between NUMA\n  nodes, which causes page-fault stalls and jitter for large, pinned model memory."
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
  supported) via 'nvidia-smi -lgc/-lmc' (or '-ac' application clocks on older Tesla
  Kepler/Maxwell GPUs) and a persistent systemd service. Removes clock ramp-up delay
  for stable, lowest-latency token decode.
EOF
  echo -e "\n${C_YELLOW}[WARNING] Locked clocks keep the GPU at high power even when idle${C_RESET}"
  echo -e "${C_YELLOW}          and hardly provide gains for sustained, GPU-bound generation.${C_RESET}"
}
apply_nvidia_clock_lock() {
  local smi_bin out i idx max_gfx max_mem exec_start="" exec_stop="" applied=0
  smi_bin="$(command -v nvidia-smi)"
  for (( i = 0; i < ${#NVIDIA_GPU_INDICES[@]}; i++ )); do
    idx="${NVIDIA_GPU_INDICES[$i]}"
    max_gfx="${NVIDIA_GPU_MAX_GFX_CLK[$i]}"
    max_mem="${NVIDIA_GPU_MAX_MEM_CLK[$i]}"
    [[ -n "$max_gfx" ]] || continue
    if out="$(run_root "$smi_bin" -i "$idx" -lgc "${max_gfx},${max_gfx}" 2>&1)"; then
      exec_start+="ExecStart=${smi_bin} -i ${idx} -lgc ${max_gfx},${max_gfx}"$'\n'
      exec_stop+="ExecStop=-${smi_bin} -i ${idx} -rgc"$'\n'
      if [[ -n "$max_mem" ]]; then
        run_root "$smi_bin" -i "$idx" -lmc "${max_mem},${max_mem}" >/dev/null 2>&1 || true
        exec_start+="ExecStart=-${smi_bin} -i ${idx} -lmc ${max_mem},${max_mem}"$'\n'
        exec_stop+="ExecStop=-${smi_bin} -i ${idx} -rmc"$'\n'
      fi
      applied=$((applied + 1))
    elif [[ -n "$max_mem" ]] && out="$(run_root "$smi_bin" -i "$idx" -ac "${max_mem},${max_gfx}" 2>&1)"; then
      exec_start+="ExecStart=${smi_bin} -i ${idx} -ac ${max_mem},${max_gfx}"$'\n'
      exec_stop+="ExecStop=-${smi_bin} -i ${idx} -rac"$'\n'
      applied=$((applied + 1))
    else
      echo -e "${C_YELLOW}nvidia-smi clock lock (-lgc/-ac) is not supported on GPU ${idx} (${NVIDIA_GPU_NAMES[$i]}): ${out}${C_RESET}"
    fi
  done
  if (( applied == 0 )); then
    return 1
  fi
  install_service nvidia-clock-lock.service <<EOF
[Unit]
Description=Lock NVIDIA GPU Clocks at Maximum for Strata
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
}
revert_nvidia_clock_lock() {
  remove_service nvidia-clock-lock.service
  local idx
  for idx in "${NVIDIA_GPU_INDICES[@]}"; do
    run_root nvidia-smi -i "$idx" -rgc >/dev/null 2>&1 || true
    run_root nvidia-smi -i "$idx" -rmc >/dev/null 2>&1 || true
    run_root nvidia-smi -i "$idx" -rac >/dev/null 2>&1 || true
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

# 12j. AMD APU Unified Memory Limit
amd_apu_gtt_pages() {
  local kb reserve
  kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  reserve=$((4 * 1048576))
  (( kb / 8 > reserve )) && reserve=$((kb / 8))
  echo $(( (kb - reserve) / 4 ))
}
applicable_amd_apu_memory() {
  [[ "$HAS_AMD" == true ]] || return 1
  compgen -G "/sys/class/drm/card*/device/mem_info_gtt_total" >/dev/null 2>&1 || return 1
  grep -iE "AMD|ATI|Radeon" <<<"$GPU_RAW" | grep -qiE "Strix|Phoenix|Hawk Point|Rembrandt|Barcelo|Cezanne|Renoir|Lucienne|Raphael|Granite Ridge|Mendocino|Krackan|Kraken|Picasso|Raven|Van Gogh|Vega Series|Vega Mobile|Radeon Graphics|Radeon [0-9]{3}M|Radeon 8[0-9]{2,3}S"
}
title_amd_apu_memory() { echo "AMD APU Unified Memory GPU Limit (ttm.pages_limit ~ $(( $(amd_apu_gtt_pages) * 4 / 1048576 )) GiB)"; }
status_amd_apu_memory() { [[ -n "$(kernel_param_value ttm.pages_limit || true)" ]]; }
explain_amd_apu_memory() {
  cat <<EOF
Impact:
  Raises the amount of system RAM the GPU can address (GTT) from the default of
  about half of RAM to ~$(( $(amd_apu_gtt_pages) * 4 / 1048576 )) GiB (all RAM minus a 4 GiB / 12.5% reserve) by adding
  'ttm.pages_limit' and 'ttm.page_pool_size' to the bootloader kernel command line.
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
  [[ -n "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]] && (( $(gpu_pci_count) >= 2 ))
}
title_iommu_pt() { echo "IOMMU Passthrough Mode (iommu=pt, lower multi-GPU DMA overhead)"; }
status_iommu_pt() { has_kernel_param "iommu=pt" || has_kernel_param "iommu.passthrough=1"; }
explain_iommu_pt() { echo -e "Impact:\n  Adds 'iommu=pt' to the kernel command line so host devices skip IOMMU address\n  translation (lower DMA overhead for multi-GPU transfers and fast NICs). VFIO\n  device passthrough keeps working. Requires a reboot."; }
apply_iommu_pt() { add_kernel_param "iommu=pt"; }
revert_iommu_pt() { remove_kernel_param "iommu=pt"; remove_kernel_param "iommu.passthrough=1"; }

# 12r. Intel compute stack
intel_compute_pkgs() {
  case "$DISTRO_FAMILY" in
    arch)   echo "intel-compute-runtime level-zero-loader" ;;
    fedora) echo "intel-compute-runtime oneapi-level-zero" ;;
    debian) echo "intel-opencl-icd libze-intel-gpu1 libze1" ;;
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
    if grep -qiE "pwm-?fan" "$hm/name" 2>/dev/null && [[ -e "$hm/pwm1" ]]; then
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
  (( $(numa_node_count) > 1 )) || return 1
  [[ -f "$NUMACTL_MARKER" ]] || command -v numactl >/dev/null 2>&1 || pkg_available repo numactl
}
title_numactl_interleave() { echo "NUMA Memory Interleaving for Strata (numactl --interleave=all)"; }
status_numactl_interleave() { [[ -f "$NUMACTL_MARKER" ]] && command -v numactl >/dev/null 2>&1; }
explain_numactl_interleave() {
  cat <<'EOF'
Impact:
  Installs numactl and starts Strata (strata.service) under 'numactl --interleave=all',
  spreading CPU-resident model weights across all NUMA nodes so memory bandwidth
  from every socket is used. Helps CPU/offload inference on multi-socket servers;
  restart strata.service after applying.
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
note_hugepages_1g() { echo -e "${C_YELLOW}[!] Reserves RAM, minimal gain${C_RESET}"; }
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
  for u in scx.service scx_loader.service; do
    if unit_exists "$u" || systemctl cat "$u" >/dev/null 2>&1; then
      echo "$u"; return 0
    fi
  done
  return 1
}
applicable_scx_scheduler() {
  [[ -d /sys/kernel/sched_ext ]] || return 1
  scx_unit >/dev/null 2>&1 || pkg_available repo scx-scheds
}
title_scx_scheduler() { echo "sched_ext BPF CPU Scheduler (scx, lower scheduling latency)"; }
status_scx_scheduler() { [[ "$(cat /sys/kernel/sched_ext/state 2>/dev/null)" == "enabled" ]]; }
explain_scx_scheduler() { echo -e "Impact:\n  Installs scx-scheds (if needed) and enables its service so a sched_ext BPF\n  scheduler (default: scx_bpfland) replaces the kernel CPU scheduler, improving\n  responsiveness of the API/server threads when CPU cores are saturated."; }
apply_scx_scheduler() {
  scx_unit >/dev/null 2>&1 || prompt_install_deps repo scx-scheds || return 0
  local u
  u="$(scx_unit)" || { echo -e "${C_YELLOW}No scx service found after installation.${C_RESET}"; return 1; }
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
      run_root "$scxctl_bin" start -s bpfland
    fi
  else
    run_root systemctl enable --now "$u"
  fi
}
revert_scx_scheduler() {
  command -v scxctl >/dev/null 2>&1 && run_root scxctl stop 2>/dev/null || true
  if [[ -f /etc/systemd/system/scx_loader.service.d/strata.conf ]]; then
    run_root rm -f /etc/systemd/system/scx_loader.service.d/strata.conf
    run_root rmdir /etc/systemd/system/scx_loader.service.d 2>/dev/null || true
    run_root systemctl daemon-reload
  fi
  local u
  u="$(scx_unit)" && run_root systemctl disable --now "$u" 2>/dev/null || true
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
strata_service_installed() { [[ -f /etc/systemd/system/strata.service ]]; }

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
}

start_strata_update_poller() {
  [[ -n "$STRATA_BIN" ]] || return 0
  [[ -n "$STRATA_UPDATE_CACHE_FILE" ]] || STRATA_UPDATE_CACHE_FILE="$(mktemp /tmp/strata-update-check.XXXXXX 2>/dev/null || echo "")"
  [[ -n "$STRATA_UPDATE_CACHE_FILE" ]] || return 0
  (
    trap 'exit 0' TERM INT
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

perform_strata_update() {
  refresh_strata_bin
  if [[ -z "$STRATA_BIN" ]]; then
    echo -e "${C_YELLOW}Strata is not installed.${C_RESET}"
    return 1
  fi

  local was_active=false
  unit_active strata.service && was_active=true

  echo -e "${C_BOLD}Strata Update${C_RESET}"
  [[ -n "$STRATA_UPDATE_SUMMARY" ]] && echo -e "Pending update: ${C_CYAN}${STRATA_UPDATE_SUMMARY}${C_RESET}"
  echo -e "Service status: $([[ "$was_active" == true ]] && echo "${C_GREEN}active (will stop & restart)${C_RESET}" || echo "${C_DIM}inactive${C_RESET}")\n"

  if ! confirm_yn "Install Strata update now? [Y/n]: " "Y"; then
    echo -e "${C_DIM}Update cancelled.${C_RESET}"
    return 0
  fi

  if [[ "$was_active" == true ]]; then
    echo -e "\n${C_CYAN}Stopping strata.service before updating...${C_RESET}"
    run_root systemctl stop strata.service || true
  fi

  echo -e "\n${C_CYAN}Running 'strata update --yes'...${C_RESET}"
  local rc=0
  run_as_user_exec "$STRATA_BIN" update --yes || rc=$?

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
    if run_root systemctl start strata.service; then
      wait_for_strata_model_live 120
    else
      echo -e "${C_RED}Failed to start strata.service (check 'journalctl -u strata -n 50').${C_RESET}"
    fi
  elif strata_service_installed; then
    echo ""
    if confirm_yn "strata.service is installed but was stopped. Start it now? [y/N]: " "N"; then
      if run_root systemctl start strata.service; then
        wait_for_strata_model_live 120
      else
        echo -e "${C_RED}Failed to start strata.service.${C_RESET}"
      fi
    fi
  fi
}
format_strata_hw_warnings() {
  if (( RAM_GB > 0 && RAM_GB < 32 )); then
    echo -e "${C_YELLOW}[WARNING] System RAM is ${RAM_GB} GiB (< 32 GiB). Larger Strata models may not fit or may swap.${C_RESET}"
  fi
  if [[ "$IS_JETSON" == true ]]; then
    return 0
  elif [[ "$HAS_NVIDIA" == false && "$HAS_AMD" == false && "$HAS_INTEL_ARC" == false ]]; then
    echo -e "${C_YELLOW}[WARNING] No dedicated NVIDIA, AMD Radeon, or Intel Arc GPU detected (${GPU_SUMMARY}). Strata models may not run.${C_RESET}"
  elif [[ "$HAS_NVIDIA" == true && "$NVIDIA_VRAM_MB" -gt 0 && "$NVIDIA_VRAM_MB" -lt 6144 ]]; then
    echo -e "${C_YELLOW}[WARNING] NVIDIA GPU VRAM is $((NVIDIA_VRAM_MB / 1024)) GiB (< 6 GiB). Larger Strata models may not fit in VRAM.${C_RESET}"
  fi
  if [[ "$HAS_NVIDIA_TESLA" == true && ${#NVIDIA_GPU_INDICES[@]} -eq 0 ]]; then
    echo -e "${C_YELLOW}[WARNING] NVIDIA Tesla GPU detected without active nvidia-smi. Ensure Above 4G Decoding is enabled in BIOS and use the proprietary nvidia driver (not nvidia-open) for pre-Turing Tesla (V100/P100/P40/P4/M40/M60), or R470 legacy for Kepler (K80/K40).${C_RESET}"
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
  local numa_prefix=""
  [[ -f "$NUMACTL_MARKER" ]] && command -v numactl >/dev/null 2>&1 && numa_prefix="$(command -v numactl) --interleave=all "

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
ExecStart=${numa_prefix}${STRATA_BIN} launch --preset "${selected_preset}" --no-tui --yes
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
  local d ch rname pval sw="" gw="" cw=""
  for d in /sys/bus/i2c/drivers/ina3221x/*/iio:device*; do
    [[ -d "$d" ]] || continue
    for ch in 0 1 2; do
      [[ -r "$d/rail_name_${ch}" && -r "$d/in_power${ch}_input" ]] || continue
      rname="$(cat "$d/rail_name_${ch}" 2>/dev/null || true)"
      pval="$(cat "$d/in_power${ch}_input" 2>/dev/null || true)"
      [[ "$pval" =~ ^[0-9]+$ ]] || continue
      case "$rname" in
        VDD_IN|POM_5V_IN)   [[ -z "$sw" ]] && sw="$(awk -v m="$pval" 'BEGIN{printf "%.2f", m/1000.0}')" ;;
        VDD_GPU|POM_5V_GPU) [[ -z "$gw" ]] && gw="$(awk -v m="$pval" 'BEGIN{printf "%.2f", m/1000.0}')" ;;
        VDD_CPU|POM_5V_CPU|VDD_SYS_CPU) [[ -z "$cw" ]] && cw="$(awk -v m="$pval" 'BEGIN{printf "%.2f", m/1000.0}')" ;;
      esac
    done
  done
  printf "%s|%s|%s" "$sw" "$gw" "$cw"
}

start_bench_power_sampler() {
  local out_file="$1"
  (
    local n=0 gpu_sum="0" cpu_sum="0" sys_sum="0" gpu_n=0 cpu_n=0 sys_n=0
    local prev_uj="" prev_us="" rapl_f="/sys/class/powercap/intel-rapl:0/energy_uj" rapl_mode="none"
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
        local card_dir hwmon_dir pa
        for card_dir in /sys/class/drm/card*/device; do
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
      sleep 1 &
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

build_strata_options() {
  if [[ -z "$STRATA_BIN" ]]; then
    ACTIVE_STRATA_OPTIONS=(install)
  else
    ACTIVE_STRATA_OPTIONS=(update remove service benchmark history)
  fi
}

title_strata_install()   { echo "Install Strata (Niko1221/Strata)"; }
title_strata_update()    { echo "Update Strata (strata update)"; }
title_strata_remove()    { echo "Remove Strata & Uninstall Service"; }
title_strata_service()   { echo "Manage Strata Systemd Service (strata.service)"; }
title_strata_benchmark() { echo "Run Strata Benchmark (strata bench run)"; }
title_strata_history()   { echo "View All Benchmark Results & Coupled Options"; }

badge_strata_install() {
  [[ -n "$STRATA_BIN" ]] && echo "${C_GREEN}[INSTALLED]    ${C_RESET}" || echo "${C_YELLOW}[NOT INSTALLED]${C_RESET}"
}
badge_strata_update() {
  if [[ -z "$STRATA_BIN" ]]; then
    echo "${C_DIM}[NOT INSTALLED]${C_RESET}"
  elif [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
    echo "${C_BGREEN}[UPDATE READY] ${C_RESET}"
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
  fi
}

strata_action_update() {
  refresh_strata_bin
  if [[ -z "$STRATA_BIN" ]]; then
    echo -e "${C_YELLOW}Strata is not installed. Run [s1] to install Strata first.${C_RESET}"
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
    echo -e "${C_YELLOW}Strata is not installed. Run [s1] to install Strata first.${C_RESET}"
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
        if run_root systemctl restart strata.service; then
          wait_for_strata_model_live 120
        else
          echo -e "${C_RED}Failed to start strata.service (check 'journalctl -u strata -n 50').${C_RESET}"
        fi
        ;;
      2)
        run_root systemctl stop strata.service && echo -e "${C_GREEN}strata.service stopped.${C_RESET}"
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
  'strata update --yes'. If strata.service is active, stops it cleanly before
  updating and restarts it once the model is ready.
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

run_strata_option() {
  local target_opt="$1" s_idx=0 total="${#ACTIVE_STRATA_OPTIONS[@]}" i opt action action_label
  (( total > 0 )) || return 0
  for (( i = 0; i < total; i++ )); do
    [[ "${ACTIVE_STRATA_OPTIONS[$i]}" == "$target_opt" ]] && { s_idx=$i; break; }
  done

  while true; do
    refresh_strata_bin
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
          show_stats_page
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

  local gpu_pcts=() vram_pcts=() vram_useds=() vram_tots=() pwr_ws=() pwr_lim_ws=() pwr_pcts=() gpu_temps=()
  local total_gpu_pwr_w="" cpu_temp=""

  # GPU, VRAM, Power, and Temp (supports multiple NVIDIA and/or AMD GPUs)
  if [[ "$HAS_NVIDIA" == true ]] && command -v nvidia-smi >/dev/null 2>&1; then
    local nv_lines nv_parsed nv_line
    nv_lines="$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,power.draw,power.limit,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || true)"
    if [[ -n "$nv_lines" ]]; then
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
      while IFS= read -r nv_line; do
        [[ -n "$nv_line" ]] || continue
        local g_pct="" v_pct="" v_used="" v_tot="" pw="" plw="" ppct="" gtmp=""
        IFS='|' read -r g_pct v_pct v_used v_tot pw plw ppct gtmp <<< "$nv_line"
        [[ -n "$pw" ]] && total_gpu_pwr_w=$(( ${total_gpu_pwr_w:-0} + pw ))
        gpu_pcts+=("$g_pct")
        vram_pcts+=("$v_pct")
        vram_useds+=("$v_used")
        vram_tots+=("$v_tot")
        pwr_ws+=("$pw")
        pwr_lim_ws+=("$plw")
        pwr_pcts+=("$ppct")
        gpu_temps+=("$gtmp")
      done <<< "$nv_parsed"
    fi
  fi
  if [[ "$HAS_AMD" == true ]]; then
    local card_dir
    for card_dir in /sys/class/drm/card*/device; do
      [[ -r "$card_dir/gpu_busy_percent" ]] || continue
      local g_pct="" v_pct="" v_used="" v_tot="" pw="" plw="" ppct="" gtmp=""
      g_pct="$(cat "$card_dir/gpu_busy_percent" 2>/dev/null || true)"
      if [[ -r "$card_dir/mem_info_vram_used" && -r "$card_dir/mem_info_vram_total" ]]; then
        local vu vt
        vu="$(cat "$card_dir/mem_info_vram_used" 2>/dev/null || echo 0)"
        vt="$(cat "$card_dir/mem_info_vram_total" 2>/dev/null || echo 0)"
        if (( vt > 0 )); then
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
      pwr_ws+=("$pw")
      pwr_lim_ws+=("$plw")
      pwr_pcts+=("$ppct")
      gpu_temps+=("$gtmp")
    done
  fi

  if [[ "$IS_JETSON" == true && ${#gpu_pcts[@]} -eq 0 ]]; then
    local j_load_f="" j_load="" j_gp="" j_gt="" tz_d tz_t j_mc
    for j_load_f in /sys/devices/gpu.0/load /sys/devices/*.gp10b/load /sys/devices/platform/host1x/*.gp10b/load; do
      if [[ -r "$j_load_f" ]]; then
        j_load="$(cat "$j_load_f" 2>/dev/null || true)"
        [[ "$j_load" =~ ^[0-9]+$ ]] && { j_gp=$(( j_load / 10 )); break; }
      fi
    done
    for tz_d in /sys/class/thermal/thermal_zone*; do
      [[ -r "$tz_d/type" && -r "$tz_d/temp" ]] || continue
      tz_t="$(cat "$tz_d/type" 2>/dev/null || true)"
      if [[ "$tz_t" == "GPU-therm" ]]; then
        j_mc="$(cat "$tz_d/temp" 2>/dev/null || echo 0)"
        [[ "$j_mc" =~ ^[0-9]+$ ]] && (( j_mc > 0 )) && { j_gt=$(( j_mc / 1000 )); break; }
      fi
    done
    if [[ -n "$j_gp" || -n "$j_gt" ]]; then
      gpu_pcts+=("${j_gp:-0}")
      vram_pcts+=("")
      vram_useds+=("")
      vram_tots+=("")
      pwr_ws+=("")
      pwr_lim_ws+=("")
      pwr_pcts+=("")
      gpu_temps+=("$j_gt")
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
    if [[ -n "${gpu_pcts[$gi]}" ]]; then
      local gpu_t_str=""
      [[ -n "${gpu_temps[$gi]}" ]] && gpu_t_str=" ($(format_temp "${gpu_temps[$gi]}"))"
      LIVE_STAT_LINES+=("$(printf "  %-8s [%s] %3d%%%s" "$g_lbl" "$(render_bar "${gpu_pcts[$gi]}")" "${gpu_pcts[$gi]}" "$gpu_t_str")")
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
    [[ -n "${gpu_pcts[$gi]}" ]] && _cparts+=("${_gl} ${gpu_pcts[$gi]}%${gpu_temps[$gi]:+ (${gpu_temps[$gi]}°C)}")
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
  if (( TOTAL_VRAM_MB > 0 )); then
    local total_vram_gb
    total_vram_gb="$(awk "BEGIN {g=$TOTAL_VRAM_MB/1024; if (g == int(g)) printf \"%d\", g; else printf \"%.1f\", g}")"
    SYS_INFO_LINES+=("$(printf "VRAM:   %b%s GiB%b" "${C_DIM}" "$total_vram_gb" "${C_RESET}")")
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
  STRATA_STAT_LINES+=("$(printf "  %-8s %b%s%b" "Version:" "${C_DIM}" "${STRATA_VERSION:-Not installed}" "${C_RESET}")")
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
    local m_json
    m_json="$(curl -fsS --max-time 0.3 "${STRATA_RUNNING_URL}/metrics" 2>/dev/null || true)"
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
    if len(items) >= 2:
        break

# Fill remaining slots from raw results.json files on disk (newest mtime first)
if len(items) < 2:
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
        if len(items) >= 2:
            break

if not items:
    sys.exit(0)

def fmt_rec(kind, rec, d_pct="", p_pct=""):
    dec_s = f"{rec['dec']:.1f} tok/s" if rec["dec"] is not None else "—"
    pre_s = f"{rec['pre']:.1f} tok/s" if rec["pre"] is not None else "—"
    avg_dec_s = f"{rec['avg_dec']:.1f} tok/s" if rec.get("avg_dec") is not None else ""
    avg_pre_s = f"{rec['avg_pre']:.1f} tok/s" if rec.get("avg_pre") is not None else ""
    cols = [kind, rec["ts"], rec["tag"], rec["model"], dec_s, pre_s, rec["req_s"], rec["qual_s"], rec["sw"], rec["gw"], rec["cw"], d_pct, p_pct, avg_dec_s, avg_pre_s]
    return "|".join(str(c).replace("|", "/").replace("\n", " ").replace("\r", "") for c in cols)

d_pct = ""
p_pct = ""
if len(items) >= 2:
    cur, prev = items[0], items[1]
    cur_d = cur.get("avg_dec") if cur.get("avg_dec") is not None else cur.get("dec")
    prev_d = prev.get("avg_dec") if prev.get("avg_dec") is not None else prev.get("dec")
    cur_p = cur.get("avg_pre") if cur.get("avg_pre") is not None else cur.get("pre")
    prev_p = prev.get("avg_pre") if prev.get("avg_pre") is not None else prev.get("pre")
    if cur_d is not None and prev_d is not None and prev_d > 0:
        d_pct = f"{((cur_d - prev_d) / prev_d) * 100.0:.1f}"
    if cur_p is not None and prev_p is not None and prev_p > 0:
        p_pct = f"{((cur_p - prev_p) / prev_p) * 100.0:.1f}"

print(fmt_rec("CUR", items[0], d_pct, p_pct))
if len(items) >= 2:
    print(fmt_rec("PREV", items[1]))
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

  local line kind b_ts b_tag b_model b_dec b_pre b_req b_qual b_sw b_gw b_cw b_dpct b_ppct b_avg_dec b_avg_pre
  while IFS='|' read -r kind b_ts b_tag b_model b_dec b_pre b_req b_qual b_sw b_gw b_cw b_dpct b_ppct b_avg_dec b_avg_pre; do
    [[ -n "$kind" ]] || continue
    if [[ "$kind" == "CUR" ]]; then
      STRATA_BENCH_LINES+=("$(printf "%bLatest Benchmark:%b" "${C_BOLD}" "${C_RESET}")")
    else
      STRATA_BENCH_LINES+=("$(printf "%bPrevious Benchmark:%b" "${C_BOLD}" "${C_RESET}")")
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
    local has_diff=false
    if [[ "$kind" == "CUR" ]]; then
      local diff_parts=()
      [[ -n "$b_dpct" ]] && diff_parts+=("Decode $(format_pct_delta "$b_dpct")")
      [[ -n "$b_ppct" ]] && diff_parts+=("Prefill $(format_pct_delta "$b_ppct")")
      if (( ${#diff_parts[@]} > 0 )); then
        local diff_str="" di=0
        for ((di=0; di<${#diff_parts[@]}; di++)); do
          (( di > 0 )) && diff_str+=" | "
          diff_str+="${diff_parts[$di]}"
        done
        STRATA_BENCH_LINES+=("$(printf "  %-8s %s" "Diff:" "$diff_str")")
        has_diff=true
      fi
    fi
    local summary_tail=""
    [[ -n "$b_req" ]] && summary_tail="Reqs: ${b_req}"
    if [[ -n "$b_qual" ]]; then
      [[ -n "$summary_tail" ]] && summary_tail+=" | "
      summary_tail+="$b_qual"
    fi
    [[ -n "$summary_tail" ]] && STRATA_BENCH_LINES+=("$(printf "  %-8s %b%s%b" "Checks:" "${C_DIM}" "$summary_tail" "${C_RESET}")")
    if [[ "$has_diff" == true || -n "$summary_tail" ]]; then
      STRATA_BENCH_LINES+=("")
    fi
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
  collect_strata_bench_lines
  _append_grid_section "${SYS_INFO_LINES[@]}"
  _append_grid_section "${LIVE_STAT_LINES[@]}"
  _append_grid_section "${STRATA_STAT_LINES[@]}"
  _append_grid_section "${STRATA_BENCH_LINES[@]}"
  unset -f _append_grid_section
  LIVE_STATS_COUNT="$total_lines"
  printf "%s\n" "$out"
}

format_stats_toggle_row() {
  local selected="${1:-false}"
  local ptr=" " tag="[STATS]" title="View Live System, Strata & Benchmark Statistics" sub="(CPU / RAM / GPU / Power / Live tok/s)"
  if [[ "$selected" == true ]]; then
    ptr="${C_CYAN}>${C_RESET}"
    printf "%b %b%s%b  %b%s%b  %b%s%b" "$ptr" "${C_BGREEN}${C_BOLD}" "$tag" "${C_RESET}" "${C_CYAN}${C_BOLD}" "$title" "${C_RESET}" "${C_CYAN}" "$sub" "${C_RESET}"
  else
    printf "%b %b%s%b  %b%s%b  %b%s%b" "$ptr" "${C_YELLOW}${C_BOLD}" "$tag" "${C_RESET}" "${C_BOLD}" "$title" "${C_RESET}" "${C_DIM}" "$sub" "${C_RESET}"
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
  load_strata_update_state
  refresh_strata_running
  if [[ "$hdr_mode" == "toggle" ]]; then
    LIVE_STATS_COUNT=0
    LIVE_STAT_LINES=()
    echo ""
    local _tgl_sel=false
    (( INDEX_SELECTED == 0 )) && _tgl_sel=true
    printf "%s\n" "$(format_stats_toggle_row "$_tgl_sel")"
    echo ""
    POST_HEADER_LINES=3
  elif [[ "$hdr_mode" == "stats" ]]; then
    build_sys_info_lines
    print_stats_and_info_grid false
    POST_HEADER_LINES=2
  else
    LIVE_STATS_COUNT=0
    LIVE_STAT_LINES=()
    POST_HEADER_LINES=2
  fi
  if [[ "$skip_rule" != true ]]; then
    printf -v _hdr_rule "%*s" "$_rule_w" ""
    echo -e "${C_DIM}${_hdr_rule// /─}${C_RESET}"
  else
    POST_HEADER_LINES=$((POST_HEADER_LINES - 1))
  fi
  if [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
    echo -e "\n${C_BGREEN}[UPDATE AVAILABLE]${C_RESET} ${C_CYAN}Strata update ready (${STRATA_UPDATE_SUMMARY}). Press [u] to install & restart service.${C_RESET}"
    ((POST_HEADER_LINES += 2))
  fi
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
      if [[ "$prev_upd" == false && "$STRATA_UPDATE_AVAILABLE" == true && -z "$buf" ]]; then
        _cleanup_line_live; trap - INT TERM; printf "\n"
        _line_out="__refresh__"; return 0
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
      if [[ "$prev_upd" == false && "$STRATA_UPDATE_AVAILABLE" == true && -z "$buf" ]]; then
        _restore_step_tty; trap - INT TERM; printf "\n"
        _act_out="__refresh__"; return 0
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
          echo ""; perform_strata_update; pause_prompt
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
  local lines_up="$2"
  local footer_lines="${3:-0}"
  local toggle_up="${4:-0}"
  local term_lines=40
  if [[ ! -t 1 || ! -t 0 ]]; then
    read -r -p "Select action: " _out_var || exit 0
    return 0
  fi

  term_lines="$(tput lines 2>/dev/null || echo 40)"

  local tmp_file="" sampler_pid=""
  local cur_running_url="$STRATA_RUNNING_URL" cur_svc_active="0"
  unit_active strata.service && cur_svc_active="1"

  local saved_tty=""
  saved_tty="$(stty -g 2>/dev/null || true)"
  stty -echo 2>/dev/null || true

  _cleanup_live_sampler() {
    [[ -n "$sampler_pid" ]] && { kill "$sampler_pid" 2>/dev/null || true; wait "$sampler_pid" 2>/dev/null || true; sampler_pid=""; }
    [[ -n "$tmp_file" ]] && { rm -f "$tmp_file" "${tmp_file}.tmp" "${tmp_file}.bar" "${tmp_file}.bar.tmp" "${tmp_file}.meta" "${tmp_file}.meta.tmp" 2>/dev/null || true; tmp_file=""; }
    ACTIVE_SAMPLER_PID="" ACTIVE_SAMPLER_TMP=""
    if [[ -n "$saved_tty" ]]; then
      stty "$saved_tty" 2>/dev/null || stty echo 2>/dev/null || true
    else
      stty echo 2>/dev/null || true
    fi
  }
  trap '_cleanup_live_sampler; exit 0' INT TERM

  local buf="" ch="" rc=0 stats_block=""
  printf "Select action: "
  while true; do
    rc=0
    IFS= read -rsn1 -t 1 ch || rc=$?
    if (( rc == 0 )); then
      if [[ -z "$ch" ]]; then
        _cleanup_live_sampler
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
        local n_opt="${#ACTIVE_STEPS[@]}" n_str="${#ACTIVE_STRATA_OPTIONS[@]}"
        local total_rows=$(( 1 + n_opt + n_str ))
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
            old_up="$(index_row_up_offset "$old_idx" "$n_opt" "$n_str" "$footer_lines" "$toggle_up")"
            new_up="$(index_row_up_offset "$new_idx" "$n_opt" "$n_str" "$footer_lines" "$toggle_up")"
            if (( old_up < term_lines && new_up < term_lines )); then
              local old_row new_row
              old_row="$(render_any_index_row "$old_idx" false)"
              new_row="$(render_any_index_row "$new_idx" true)"
              printf "\033[?2026h\033[?25l\033[s\033[%dA\r\033[2K%s\033[u\033[s\033[%dA\r\033[2K%s\033[u\033[?25h\033[?2026l" \
                "$old_up" "$old_row" "$new_up" "$new_row"
            else
              _cleanup_live_sampler
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
          if [[ "$ch" =~ ^[wWuUhHaAxXrRqQsS]$ ]] || [[ "$ch" =~ ^[1-9]$ ]]; then
            accept=true
          fi
        elif [[ "$buf" =~ ^[sS]$ ]]; then
          if [[ "$ch" =~ ^[1-9]$ ]] && (( 10#$ch <= ${#ACTIVE_STRATA_OPTIONS[@]} )); then
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
      local prev_upd="$STRATA_UPDATE_AVAILABLE"
      load_strata_update_state
      if [[ "$prev_upd" == false && "$STRATA_UPDATE_AVAILABLE" == true && -z "$buf" ]]; then
        _cleanup_live_sampler
        trap - INT TERM
        printf "\n"
        _out_var="__refresh__"
        return 0
      fi
      local new_lines="$LIVE_STATS_COUNT" new_running_url="$cur_running_url" new_svc_active="$cur_svc_active"
      if [[ -n "$tmp_file" && -s "${tmp_file}.meta" ]]; then
        IFS='|' read -r new_lines new_running_url new_svc_active < "${tmp_file}.meta" || true
      fi
      if [[ "$new_lines" =~ ^[0-9]+$ ]] && (( new_lines != LIVE_STATS_COUNT )); then
        if [[ -z "$buf" ]]; then
          _cleanup_live_sampler
          trap - INT TERM
          printf "\n"
          _out_var="__refresh__"
          return 0
        fi
      else
        if [[ -n "$tmp_file" && -s "$tmp_file" ]]; then
          stats_block="$(<"$tmp_file")"
          _render_live_stats_inplace "$lines_up" "$term_lines" "$stats_block"
        fi
      fi
      if [[ "$new_running_url" != "$cur_running_url" || "$new_svc_active" != "$cur_svc_active" ]]; then
          cur_running_url="$new_running_url"
          cur_svc_active="$new_svc_active"
          STRATA_RUNNING_URL="$new_running_url"
          local n_opt="${#ACTIVE_STEPS[@]}" n_str="${#ACTIVE_STRATA_OPTIONS[@]}" s_i abs_i row_up row_str is_sel
          if (( footer_lines > 0 && n_str > 0 )); then
            for (( s_i = 0; s_i < n_str; s_i++ )); do
              if [[ "${ACTIVE_STRATA_OPTIONS[$s_i]}" == "service" || "${ACTIVE_STRATA_OPTIONS[$s_i]}" == "benchmark" ]]; then
                abs_i=$(( 1 + n_opt + s_i ))
                row_up="$(index_row_up_offset "$abs_i" "$n_opt" "$n_str" "$footer_lines" "$toggle_up")"
                if (( row_up > 0 && row_up < term_lines )); then
                  is_sel=false
                  (( abs_i == INDEX_SELECTED )) && is_sel=true
                  row_str="$(render_any_index_row "$abs_i" "$is_sel")"
                  printf "\033[?2026h\033[?25l\033[s\033[%dA\r\033[2K%s\033[u\033[?25h\033[?2026l" "$row_up" "$row_str"
                fi
              fi
            done
          fi
        fi
    else
      _cleanup_live_sampler
      trap - INT TERM
      printf "\n"
      exit 0
    fi
  done
}

INDEX_SELECTED=0

# Relative performance/utility rating per step on a 5-point scale (0 = no rating/stars, 1 = 1 star, 5 = 5 stars).
declare -A STEP_GAIN_PTS=(
  [gpu_unlock]=5
  [amd_apu_memory]=5
  [gpu_groups]=4
  [intel_compute_stack]=4
  [lact_overclock]=4
  [jetson_perf]=4
  [nvidia_power_limit]=4
  [amd_gpu_perf]=4
  [intel_gpu_perf]=4
  [ryzenadj_tdp]=4
  [nvidia_ecc]=4
  [nvidia_compute_mode]=3
  [headless_target]=4
  [numactl_interleave]=4
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
  [numa_balancing]=3
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
  if declare -F "note_${step}" >/dev/null 2>&1; then
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
  local n_opt="${#ACTIVE_STEPS[@]}"
  if (( idx == 0 )); then
    format_stats_toggle_row "$selected"
  elif (( idx <= n_opt )); then
    format_index_row "$((idx - 1))" "$selected"
  else
    format_strata_row "$((idx - 1 - n_opt))" "$selected"
  fi
}

index_row_up_offset() {
  local idx="$1" n_opt="$2" n_str="$3" footer_menu_lines="$4" toggle_up="${5:-0}"
  if (( idx == 0 )); then
    echo "$toggle_up"
  elif (( idx <= n_opt )); then
    local o_idx=$(( idx - 1 ))
    # Below opt table: blank + legend + blank + Strata title + blank + header + sep (7 lines) + n_str rows + footer_menu_lines
    echo $(( (n_opt - o_idx) + 7 + n_str + footer_menu_lines ))
  else
    local s_idx=$(( idx - 1 - n_opt ))
    echo $(( (n_str - s_idx) + footer_menu_lines ))
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
          echo ""; perform_strata_update; pause_prompt
        fi
        ;;
      *) ;;
    esac
  done
}

show_index() {
  while true; do
    refresh_strata_bin
    build_active_steps
    build_strata_options
    local total_rows=$(( 1 + ${#ACTIVE_STEPS[@]} + ${#ACTIVE_STRATA_OPTIONS[@]} ))
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
      if (( idx + 1 == INDEX_SELECTED )); then
        body+="$(format_index_row "$idx" true)"$'\n'
      else
        body+="$(format_index_row "$idx" false)"$'\n'
      fi
    done
    body+=$'\n'"$(echo -e "  ${C_YELLOW}[!]${C_RESET} ${C_DIM}Higher idle power, minimal gain${C_RESET}")"$'\n'

    body+=$'\n'"$(echo -e "${C_BOLD}Strata Options:${C_RESET}")"$'\n\n'
    body+="$(printf "  ${C_BOLD}%-3s | %-15s | %s${C_RESET}" "#" "Status" "Option")"$'\n'
    body+="$(printf "  %s" "----+-----------------+-------------------------------------------------------")"$'\n'
    local s_idx abs_idx
    for (( s_idx = 0; s_idx < ${#ACTIVE_STRATA_OPTIONS[@]}; s_idx++ )); do
      abs_idx=$(( 1 + ${#ACTIVE_STEPS[@]} + s_idx ))
      if (( abs_idx == INDEX_SELECTED )); then
        body+="$(format_strata_row "$s_idx" true)"$'\n'
      else
        body+="$(format_strata_row "$s_idx" false)"$'\n'
      fi
    done

    local footer_lines=8 hist_count s_range="s1"
    (( ${#ACTIVE_STRATA_OPTIONS[@]} > 1 )) && s_range="s1-${#ACTIVE_STRATA_OPTIONS[@]}"
    hist_count="$(count_bench_history)"
    body+=$'\n'"$(echo -e "  ${C_BOLD}[w]${C_RESET} Start guided wizard from Step 1")"$'\n'
    if [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
      body+="$(echo -e "  ${C_BGREEN}[u]${C_RESET} Install Strata update (${STRATA_UPDATE_SUMMARY})")"$'\n'
      ((footer_lines++))
    fi
    if (( hist_count > 0 )); then
      body+="$(echo -e "  ${C_CYAN}[h]${C_RESET} Benchmark history & restore coupled options (${hist_count})")"$'\n'
      ((footer_lines++))
    fi
    body+="$(echo -e "  ${C_GREEN}[a]${C_RESET} Apply all recommended optimizations (excludes high-idle-power options)")"$'\n'
    body+="$(echo -e "  ${C_RED}[x]${C_RESET} Revert all recommended optimizations")"$'\n'
    body+="$(echo -e "  ${C_BOLD}[1-${#ACTIVE_STEPS[@]}, ${s_range} / ↑↓+Enter]${C_RESET} Select an option")"$'\n'
    body+="$(echo -e "  ${C_BOLD}[r]${C_RESET} Reboot system")"$'\n'
    body+="$(echo -e "  ${C_BOLD}[q]${C_RESET} Quit")"$'\n\n'

    printf "%s" "$body"
    local body_lines toggle_up
    body_lines="$(printf "%s" "$body" | wc -l)"
    toggle_up=$(( 1 + POST_HEADER_LINES + body_lines ))
    read_choice_with_live_stats choice 0 "$footer_lines" "$toggle_up"

    case "$choice" in
      __refresh__) ;;
      "")
        if (( INDEX_SELECTED == 0 )); then
          show_stats_page
        elif (( INDEX_SELECTED <= ${#ACTIVE_STEPS[@]} )); then
          run_step_view $(( INDEX_SELECTED - 1 )) "single"
        else
          local sel_s=$(( INDEX_SELECTED - 1 - ${#ACTIVE_STEPS[@]} ))
          (( sel_s >= 0 && sel_s < ${#ACTIVE_STRATA_OPTIONS[@]} )) && run_strata_option "${ACTIVE_STRATA_OPTIONS[$sel_s]}"
        fi
        ;;
      u|U)
        if [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
          echo ""; perform_strata_update; pause_prompt
        else
          echo -e "${C_YELLOW}No Strata update available.${C_RESET}"; sleep 1
        fi
        ;;
      h|H) show_benchmark_history ;;
      w|W) run_step_view 0 "wizard" ;;
      a|A) run_recommended_batch "apply" ;;
      x|X) run_recommended_batch "revert" ;;
      r|R)
        confirm_yn "Reboot this system now? [y/N]: " "N" && { run_root systemctl reboot; exit 0; }
        sleep 1
        ;;
      q|Q) exit 0 ;;
      s[1-9]|S[1-9])
        local sn=$(( 10#${choice:1} - 1 ))
        if (( sn >= 0 && sn < ${#ACTIVE_STRATA_OPTIONS[@]} )); then
          run_strata_option "${ACTIVE_STRATA_OPTIONS[$sn]}"
        else
          echo -e "${C_RED}Invalid choice '${choice}'. Cancelled.${C_RESET}"; sleep 1
        fi
        ;;
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

trap 'cleanup_all_on_exit' EXIT
if [[ $EUID -ne 0 && -t 0 ]] && command -v sudo >/dev/null 2>&1 && ! sudo -n true >/dev/null 2>&1; then
  echo -e "${C_DIM}Sudo access is used for hardware sensors (RAPL CPU power, DMI RAM info) and applying optimizations.${C_RESET}"
  sudo -v || true
fi
detect_platform_basics
ensure_script_tools
detect_environment
start_strata_update_poller
show_index
