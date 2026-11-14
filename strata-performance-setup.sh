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
DISTRO_FAMILY="unknown" DISTRO_ID="unknown" OS_PRETTY="" KERNEL_VER="" AUR_HELPER=""
HAS_NVIDIA=false HAS_NVIDIA_POWERD=false HAS_AMD=false HAS_INTEL_GPU=false HAS_INTEL_ARC=false
GPU_SUMMARY="" GPU_RAW="" CPU_SUMMARY="" RAM_GB=0 RAM_DETAILS="" NVIDIA_VRAM_MB=0 TOTAL_VRAM_MB=0
HAS_MSI_EC=false SYS_VENDOR="" PRODUCT_NAME="" IS_LAPTOP=false HAS_ASPM=false
NVIDIA_DEFAULT_PL="" NVIDIA_MAX_PL="" NVIDIA_CURRENT_PL=""
NVIDIA_MAX_GFX_CLK="" NVIDIA_MAX_MEM_CLK="" NVIDIA_ECC_CUR="" NVIDIA_ECC_PEND=""
IS_VIRT="" NUMA_NODES=1 CPU_SOCKETS=1 DISCRETE_GPU_COUNT=0 DMI_MEM_CACHE=""
declare -a RAM_HEALTH_LINES=() GPU_TOPO_LINES=()
RYZENADJ_MARKER="/etc/strata-ryzenadj.prev" RAPL_MARKER="/etc/strata-rapl.prev" TUNED_MARKER="/etc/strata-tuned.prev" NUMACTL_MARKER="/etc/strata-numactl.enabled"
HEADLESS_MARKER="/etc/strata-headless.prev" PSTATE_MARKER="/etc/strata-pstate.prev" GPU_GROUPS_MARKER="/etc/strata-gpu-groups.added"
REBOOT_REQUIRED=false REBOOT_PROMPT_PENDING=false
PREV_CPU_TOTAL="" PREV_CPU_IDLE="" PREV_RAPL_UJ="" PREV_RAPL_US="" LIVE_STATS_COUNT=0 POST_HEADER_LINES=0
declare -a LIVE_STAT_LINES=() SYS_INFO_LINES=() STRATA_STAT_LINES=()
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

unit_exists() {
  awk -v u="$1" '$1 == u {found=1; exit} END {exit !found}' <<< "$UNIT_FILES_CACHE"
}

unit_enabled() {
  systemctl is-enabled "$1" >/dev/null 2>&1
}

unit_active() {
  systemctl is-active "$1" >/dev/null 2>&1
}

install_service() {
  local unit="$1"
  run_root tee "/etc/systemd/system/${unit}" >/dev/null
  run_root systemctl daemon-reload
  run_root systemctl enable --now "$unit"
}

remove_service() {
  local unit="$1"
  run_root systemctl disable --now "$unit" 2>/dev/null || true
  run_root rm -f "/etc/systemd/system/${unit}"
  run_root systemctl daemon-reload
}

pkg_installed() {
  local pkg="$1" rc=1
  [[ -n "${PKG_INST_CACHE[$pkg]+x}" ]] && return "${PKG_INST_CACHE[$pkg]}"
  case "$DISTRO_FAMILY" in
    arch)   pacman -Qi "$pkg" >/dev/null 2>&1 && rc=0 ;;
    fedora) rpm -q "$pkg" >/dev/null 2>&1 && rc=0 ;;
    debian) dpkg -s "$pkg" >/dev/null 2>&1 && rc=0 ;;
    suse)   rpm -q "$pkg" >/dev/null 2>&1 && rc=0 ;;
    *)      return 1 ;;
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
      fedora) [[ "$mode" == "repo" ]] && dnf info --available "$pkg" >/dev/null 2>&1 && rc=0 ;;
      debian) [[ "$mode" == "repo" ]] && apt-cache show "$pkg" >/dev/null 2>&1 && rc=0 ;;
      suse)   [[ "$mode" == "repo" ]] && zypper --non-interactive info "$pkg" 2>/dev/null | grep -qi "^Repository" && rc=0 ;;
    esac
  fi
  PKG_AVAIL_CACHE[$key]=$rc
  return "$rc"
}

pkg_install() {
  local rc=0
  case "$DISTRO_FAMILY" in
    arch)   run_root pacman -S --needed --noconfirm "$@" || rc=$? ;;
    fedora) run_root dnf install -y "$@" || rc=$? ;;
    debian) run_root apt-get update -qq && run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" || rc=$? ;;
    suse)   run_root zypper --non-interactive install "$@" || rc=$? ;;
    *)      echo -e "${C_RED}Unsupported package manager.${C_RESET}"; return 1 ;;
  esac
  PKG_INST_CACHE=()
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
  grep -v '^[[:space:]]*#' "$file" | grep -Eq "(^|[[:space:]\"'])${esc}([[:space:]\"']|\$)"
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
  for f in /etc/default/limine /etc/default/grub /etc/kernel/cmdline /boot/refind_linux.conf /boot/loader/entries/*.conf /efi/loader/entries/*.conf /boot/efi/loader/entries/*.conf; do
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
  else
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_YELLOW}Please add '${param}' to your bootloader kernel command line manually.${C_RESET}"
  fi
}

remove_kernel_param() {
  local param="$1"
  if _file_has_kparam "$param" /etc/default/limine; then
    _remove_kparam_from_file "$param" /etc/default/limine
    command -v limine-mkinitcpio >/dev/null 2>&1 && run_root limine-mkinitcpio || true
  fi
  if _file_has_kparam "$param" /etc/default/grub; then
    _remove_kparam_from_file "$param" /etc/default/grub
    if command -v grub-mkconfig >/dev/null 2>&1; then
      run_root grub-mkconfig -o /boot/grub/grub.cfg || true
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
      run_root grub2-mkconfig -o /boot/grub2/grub.cfg || true
    fi
  fi
  if _file_has_kparam "$param" /etc/kernel/cmdline; then
    _remove_kparam_from_file "$param" /etc/kernel/cmdline
    command -v bootctl >/dev/null 2>&1 && run_root bootctl update >/dev/null 2>&1 || true
  fi
  if [[ "$DISTRO_FAMILY" == "fedora" || "$DISTRO_FAMILY" == "suse" ]] && command -v grubby >/dev/null 2>&1; then
    run_root grubby --update-kernel=ALL --remove-args="$param" >/dev/null 2>&1 || true
  fi
  local ef
  for ef in /boot/loader/entries/*.conf /efi/loader/entries/*.conf /boot/efi/loader/entries/*.conf; do
    [[ -f "$ef" ]] && _file_has_kparam "$param" "$ef" && _remove_kparam_from_file "$param" "$ef"
  done
  if _file_has_kparam "$param" /boot/refind_linux.conf; then
    _remove_kparam_from_file "$param" /boot/refind_linux.conf
  fi
}

pause_prompt() { echo ""; read -r -p "Press [Enter] to continue..." _; }

prompt_reboot_if_needed() {
  [[ "$REBOOT_PROMPT_PENDING" == true ]] || return 0
  REBOOT_PROMPT_PENDING=false
  echo -e "\n${C_YELLOW}[REBOOT REQUIRED] One or more applied optimizations require a reboot to take effect.${C_RESET}"
  if confirm_yn "Reboot this system now? [y/N]: " "N"; then
    run_root systemctl reboot
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
        print((r.get("name") or "") + "|" + (r.get("url") or ""))
    break
' <<< "$st_json" 2>/dev/null || true)"
    if [[ -n "$parsed" ]]; then
      IFS='|' read -r STRATA_RUNNING_PRESET STRATA_RUNNING_URL <<< "$parsed"
    fi
  fi
}

detect_environment() {
  UNIT_FILES_CACHE="$(systemctl list-unit-files --no-legend --no-pager 2>/dev/null || true)"
  IS_VIRT="$(systemd-detect-virt 2>/dev/null || true)"
  [[ "$IS_VIRT" == "none" ]] && IS_VIRT=""

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
    fi
  fi

  if [[ "$DISTRO_FAMILY" == "arch" ]]; then
    if command -v yay >/dev/null 2>&1; then
      AUR_HELPER="yay"
    elif command -v paru >/dev/null 2>&1; then
      AUR_HELPER="paru"
    fi
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    local nv_q
    nv_q="$(nvidia-smi --query-gpu=power.limit,power.default_limit,power.max_limit,memory.total --format=csv,noheader,nounits 2>/dev/null || true)"
    if [[ -n "$nv_q" ]]; then
      HAS_NVIDIA=true
      local nv_parsed nv_vram_sum
      nv_parsed="$(awk -F', *' '
        NR == 1 {
          cur = ($1 ~ /^[0-9]+(\.[0-9]+)?$/ ? sprintf("%.0f", $1) : "")
          def = ($2 ~ /^[0-9]+(\.[0-9]+)?$/ ? sprintf("%.0f", $2) : "")
          mx  = ($3 ~ /^[0-9]+(\.[0-9]+)?$/ ? sprintf("%.0f", $3) : "")
          v0  = ($4 ~ /^[0-9]+$/ ? $4 : "")
        }
        { if ($4 ~ /^[0-9]+$/) vsum += $4 }
        END { printf "%s|%s|%s|%s|%d", cur, def, mx, v0, vsum+0 }
      ' <<<"$nv_q")"
      IFS='|' read -r NVIDIA_CURRENT_PL NVIDIA_DEFAULT_PL NVIDIA_MAX_PL NVIDIA_VRAM_MB nv_vram_sum <<< "$nv_parsed"
      [[ "$nv_vram_sum" =~ ^[0-9]+$ ]] && TOTAL_VRAM_MB=$((TOTAL_VRAM_MB + nv_vram_sum))
      refresh_nvidia_clocks
      refresh_nvidia_ecc
    fi
  fi
  if [[ "$HAS_NVIDIA" == false ]] && lspci 2>/dev/null | grep -iE "vga|3d|display" | grep -qi "nvidia"; then
    HAS_NVIDIA=true
  fi

  local gpu_lines
  gpu_lines="$(lspci 2>/dev/null | grep -iE "vga|3d|display" || true)"
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

  if [[ -z "$IS_VIRT" ]] && command -v dmidecode >/dev/null 2>&1; then
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
  CPU_SUMMARY="${cpu_model:-Unknown CPU} (${cpu_threads} threads)"

  local nd=0 d
  for d in /sys/devices/system/node/node[0-9]*; do [[ -d "$d" ]] && ((nd++)); done
  NUMA_NODES=$(( nd > 0 ? nd : 1 ))
  local sk
  sk="$(cat /sys/devices/system/cpu/cpu[0-9]*/topology/physical_package_id 2>/dev/null | sort -u | wc -l)"
  [[ "$sk" =~ ^[0-9]+$ ]] && (( sk > 0 )) || sk="$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/ {gsub(/ /,"",$2); print $2}')"
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
  v="$(tr ' ' '\n' </proc/cmdline 2>/dev/null | grep -m1 "^${name}=" | cut -d= -f2-)"
  [[ -n "$v" ]] && { echo "$v"; return 0; }
  for f in /etc/default/limine /etc/default/grub /etc/kernel/cmdline /boot/refind_linux.conf /boot/loader/entries/*.conf /efi/loader/entries/*.conf /boot/efi/loader/entries/*.conf; do
    [[ -r "$f" ]] || continue
    v="$(grep -v '^[[:space:]]*#' "$f" | grep -oE "(^|[[:space:]\"'])${esc}=[^ \"']+" | head -n1 | sed -E 's/^[[:space:]"'\'']+//' | cut -d= -f2-)"
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

refresh_nvidia_clocks() {
  local v
  v="$(nvidia-smi --query-gpu=clocks.max.graphics --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ' || true)"
  [[ "$v" =~ ^[0-9]+$ ]] && NVIDIA_MAX_GFX_CLK="$v" || NVIDIA_MAX_GFX_CLK=""
  v="$(nvidia-smi --query-gpu=clocks.max.memory --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ' || true)"
  [[ "$v" =~ ^[0-9]+$ ]] && NVIDIA_MAX_MEM_CLK="$v" || NVIDIA_MAX_MEM_CLK=""
}
refresh_nvidia_ecc() {
  local raw cur pend
  raw="$(nvidia-smi --query-gpu=ecc.mode.current,ecc.mode.pending --format=csv,noheader 2>/dev/null | head -n1 || true)"
  cur="$(awk -F', *' '{print $1}' <<<"$raw")"
  pend="$(awk -F', *' '{print $2}' <<<"$raw")"
  [[ "$cur" == "Enabled" || "$cur" == "Disabled" ]] && NVIDIA_ECC_CUR="$cur" || NVIDIA_ECC_CUR=""
  [[ "$pend" == "Enabled" || "$pend" == "Disabled" ]] && NVIDIA_ECC_PEND="$pend" || NVIDIA_ECC_PEND="$NVIDIA_ECC_CUR"
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
    SYS_INFO_LINES+=("$(printf "%bPCIe:   %b%b" "${C_DIM}" "$line" "${C_RESET}")")
  done
}

# ------------------------------------------------------------------------------
# Step Registry
# ------------------------------------------------------------------------------
ALL_STEPS=(
  base_tools prevent_sleep headless_target msi_cooling acpi_platform_profile
  asus_perf dell_thermal lenovo_legion system76_perf tuxedo_perf
  cpu_performance ryzenadj_tdp intel_rapl intel_thermald amd_x3d_mode intel_pcore_pinning cstate_limit tuned_profile memlock_realtime pcie_aspm iommu_pt gpu_groups
  nvidia_persistenced nvidia_powerd nvidia_power_limit nvidia_clock_lock nvidia_ecc lact_overclock gpu_unlock
  amd_gpu_perf amd_apu_memory intel_gpu_perf intel_compute_stack jetson_perf
  sysctl_tuning nvme_tuning net_tuning zram_swap irq_balance numa_balancing numactl_interleave hugepages_1g scx_scheduler strata_manager
)
ACTIVE_STEPS=()

VM_HIDDEN_STEPS=" msi_cooling acpi_platform_profile asus_perf dell_thermal lenovo_legion system76_perf tuxedo_perf cpu_performance cstate_limit pcie_aspm ryzenadj_tdp intel_rapl intel_thermald amd_x3d_mode intel_pcore_pinning tuned_profile jetson_perf "
build_active_steps() {
  ACTIVE_STEPS=()
  local step
  for step in "${ALL_STEPS[@]}"; do
    [[ -n "$IS_VIRT" && "$VM_HIDDEN_STEPS" == *" $step "* ]] && continue
    "applicable_${step}" && ACTIVE_STEPS+=("$step")
  done
}

is_recommended_step() {
  case "$1" in
    cpu_performance|pcie_aspm|cstate_limit|nvidia_clock_lock|tuned_profile|hugepages_1g|strata_manager) return 1 ;;
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
      [[ "$step" == "base_tools" ]] && continue
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
  [[ "$mode" == "apply" ]] && prompt_reboot_if_needed
  pause_prompt
}

# 1. Base Tools
applicable_base_tools() { return 0; }
title_base_tools() { echo "Base Diagnostic & System Tools (curl, pciutils, lm_sensors)"; }
status_base_tools() { command -v curl >/dev/null 2>&1 && command -v lspci >/dev/null 2>&1 && command -v sensors >/dev/null 2>&1; }
explain_base_tools() {
  cat <<'EOF'
Impact:
  Installs curl, pciutils (lspci), and lm_sensors for downloading Strata and
  monitoring GPU, PCIe, and chassis temperatures under sustained AI load.
EOF
}
apply_base_tools() {
  case "$DISTRO_FAMILY" in
    arch|fedora) prompt_install_deps repo curl pciutils lm_sensors || return 0 ;;
    debian)      prompt_install_deps repo curl pciutils lm-sensors || return 0 ;;
    suse)        prompt_install_deps repo curl pciutils sensors || return 0 ;;
  esac
  command -v sensors-detect >/dev/null 2>&1 && run_root sensors-detect --auto >/dev/null 2>&1 || true
}
revert_base_tools() { echo -e "${C_YELLOW}Base tools are shared system utilities and are kept installed.${C_RESET}"; }

# 2. Prevent Sleep
applicable_prevent_sleep() { return 0; }
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
status_msi_cooling() { [[ -f /etc/systemd/system/msi-gaming-cooling.service ]] && unit_enabled msi-gaming-cooling.service; }
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
  [[ "$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)" == "performance" && -f /etc/systemd/system/strata-acpi-profile.service ]]
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
note_cpu_performance() { echo -e "${C_YELLOW}[!] Higher idle power, minimal gain${C_RESET}"; }
status_cpu_performance() {
  local gov ppd
  gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)"
  ppd="$(powerprofilesctl get 2>/dev/null || true)"
  [[ "$gov" == "performance" ]] || [[ -f /etc/systemd/system/strata-cpu-perf.service && "$ppd" == "performance" ]]
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
      debian) prompt_install_deps repo linux-cpupower || true ;;
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
note_pcie_aspm() { echo -e "${C_YELLOW}[!] Higher idle power, minimal gain${C_RESET}"; }
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
applicable_nvidia_powerd() { [[ "$HAS_NVIDIA" == true && "$HAS_NVIDIA_POWERD" == true ]]; }
title_nvidia_powerd() { echo "NVIDIA Dynamic Boost Daemon (nvidia-powerd)"; }
status_nvidia_powerd() { unit_enabled nvidia-powerd.service && unit_active nvidia-powerd.service; }
explain_nvidia_powerd() { echo -e "Impact:\n  Enables Dynamic Boost to shift power budget to mobile RTX GPUs under load."; }
apply_nvidia_powerd() { run_root systemctl enable --now nvidia-powerd.service; }
revert_nvidia_powerd() { run_root systemctl disable --now nvidia-powerd.service; }

# 9. NVIDIA Power Limit
applicable_nvidia_power_limit() {
  [[ "$HAS_NVIDIA" == true && -n "$NVIDIA_CURRENT_PL" && -n "$NVIDIA_MAX_PL" && -n "$NVIDIA_DEFAULT_PL" && "$NVIDIA_MAX_PL" -gt "$NVIDIA_DEFAULT_PL" ]]
}
title_nvidia_power_limit() { echo "NVIDIA Persistent Max GPU Power Limit (${NVIDIA_DEFAULT_PL}W -> ${NVIDIA_MAX_PL}W)"; }
status_nvidia_power_limit() {
  [[ -f /etc/systemd/system/nvidia-power-limit.service ]] && unit_enabled nvidia-power-limit.service && [[ -n "$NVIDIA_CURRENT_PL" && "$NVIDIA_CURRENT_PL" -ge "$NVIDIA_MAX_PL" ]]
}
explain_nvidia_power_limit() { echo -e "Impact:\n  Raises GPU power ceiling from ${NVIDIA_DEFAULT_PL}W to ${NVIDIA_MAX_PL}W via persistent systemd service."; }
apply_nvidia_power_limit() {
  local smi_bin out
  smi_bin="$(command -v nvidia-smi)"
  out="$(run_root "$smi_bin" -pl "$NVIDIA_MAX_PL" 2>&1 || true)"
  if grep -qi "not supported" <<< "$out"; then
    echo -e "${C_YELLOW}nvidia-smi -pl is not supported on this GPU scope.${C_RESET}"
    return 1
  fi
  install_service nvidia-power-limit.service <<EOF
[Unit]
Description=Set NVIDIA GPU Power Limit to ${NVIDIA_MAX_PL}W
After=nvidia-persistenced.service nvidia-powerd.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${smi_bin} -pl ${NVIDIA_MAX_PL}
ExecStop=${smi_bin} -pl ${NVIDIA_DEFAULT_PL}

[Install]
WantedBy=multi-user.target
EOF
  NVIDIA_CURRENT_PL="$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -n1 | awk '{printf "%.0f", $1}')"
}
revert_nvidia_power_limit() {
  remove_service nvidia-power-limit.service
  run_root nvidia-smi -pl "$NVIDIA_DEFAULT_PL" >/dev/null 2>&1 || true
  NVIDIA_CURRENT_PL="$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -n1 | awk '{printf "%.0f", $1}')"
}

# 10. LACT GPU Overclocking
applicable_lact_overclock() {
  [[ "$HAS_NVIDIA" == true || "$HAS_AMD" == true ]] || return 1
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

  if [[ -f /etc/lact/config.yaml ]]; then
    run_root cp -n /etc/lact/config.yaml /etc/lact/config.yaml.bak.strata-setup 2>/dev/null || true
    if run_root python3 -c '
import sys, yaml
p = "/etc/lact/config.yaml"
with open(p) as f: d = yaml.safe_load(f) or {}
gpus = d.get("gpus") or {}
if not gpus: sys.exit(1)
gpu_id = next(iter(gpus))
g = gpus[gpu_id] if isinstance(gpus[gpu_id], dict) else {}
g["gpu_clock_offsets"] = {0: int(sys.argv[1])}
g["mem_clock_offsets"] = {0: int(sys.argv[2])}
g.setdefault("power_mizer_mode", "Adaptive")
gpus[gpu_id] = g
d["gpus"] = gpus
with open(p, "w") as f: yaml.safe_dump(d, f, sort_keys=False)
' "$core_off" "$mem_off" 2>/dev/null; then
      run_root systemctl restart lactd.service
    else
      echo -e "${C_YELLOW}Could not auto-edit /etc/lact/config.yaml; configure in LACT GUI.${C_RESET}"
    fi
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
  grep -qiE "TU10|TU11|GA10|AD10|RTX 20|RTX 30|RTX 40|GTX 16|A100|A10|A40|L40|RTX A" <<< "${GPU_RAW:-$GPU_SUMMARY}" || return 1
  pkg_installed gpu-unlock-dkms || pkg_available repo gpu-unlock-dkms || pkg_available aur gpu-unlock-dkms
}
title_gpu_unlock() { echo "NVIDIA GPU Unlock Module & Kernel Param (gpu-unlock-dkms)"; }
note_gpu_unlock() { echo -e "${C_BGREEN}[*] Big performance gains possible!${C_RESET}"; }
status_gpu_unlock() { has_kernel_param "gpu_unlock.targets=all" && (lsmod | grep -q gpu_unlock || pkg_installed gpu-unlock-dkms); }
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
status_intel_gpu_perf() { [[ -f /etc/systemd/system/strata-intel-gpu-perf.service ]] && unit_enabled strata-intel-gpu-perf.service; }
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
    run_root mkdir -p /etc/tmpfiles.d
    run_root tee /etc/tmpfiles.d/99-strata-thp.conf >/dev/null <<EOF2
# prev_enabled=${prev_en:-madvise} prev_defrag=${prev_df:-madvise}
w /sys/kernel/mm/transparent_hugepage/enabled - - - - always
w /sys/kernel/mm/transparent_hugepage/defrag - - - - defer+madvise
EOF2
    echo always | run_root tee "$en" >/dev/null 2>&1 || true
    echo defer+madvise | run_root tee "$df" >/dev/null 2>&1 || true
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
    debian) pkg_available repo zram-tools ;;
    suse)   pkg_available repo zram-generator ;;
    *)      return 1 ;;
  esac
}
title_zram_swap() { echo "Compressed zram Swap (zstd) for Large Model Safety"; }
status_zram_swap() { swapon --show=NAME --noheadings 2>/dev/null | grep -q "zram"; }
explain_zram_swap() { echo -e "Impact:\n  Enables zstd-compressed RAM swap (/dev/zram0) to prevent OOM crashes on\n  large models without slow NVMe swap thrashing, and raises vm.swappiness to 100\n  (zram swap is faster than evicting page cache)."; }
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
      prompt_install_deps repo zram-tools || return 0
      run_root cp -n /etc/default/zramswap /etc/default/zramswap.bak.strata-setup 2>/dev/null || true
      run_root tee /etc/default/zramswap >/dev/null <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
      run_root systemctl enable --now zramswap.service
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
      run_root systemctl disable --now zramswap.service 2>/dev/null || true
      [[ -f /etc/default/zramswap.bak.strata-setup ]] && run_root mv -f /etc/default/zramswap.bak.strata-setup /etc/default/zramswap
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
  echo -e "${C_GREEN}Default target restored to ${prev} (applies on next boot).${C_RESET}"
}

# 12f. CPU C-State Limit
cstate_limit_service_installed() { [[ -f /etc/systemd/system/strata-cstate-limit.service ]]; }
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
note_cstate_limit() { echo -e "${C_YELLOW}[!] Higher idle power, minimal gain${C_RESET}"; }
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
  compgen -G "/dev/dri/renderD*" >/dev/null 2>&1 || [[ -e /dev/kfd ]] || return 1
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
title_nvidia_clock_lock() { echo "NVIDIA Lock GPU Clocks at Maximum (${NVIDIA_MAX_GFX_CLK} MHz core)"; }
note_nvidia_clock_lock() { echo -e "${C_YELLOW}[!] Higher idle power, minimal gain${C_RESET}"; }
status_nvidia_clock_lock() { [[ -f /etc/systemd/system/nvidia-clock-lock.service ]] && unit_enabled nvidia-clock-lock.service; }
explain_nvidia_clock_lock() {
  cat <<EOF
Impact:
  Locks GPU core clocks at ${NVIDIA_MAX_GFX_CLK} MHz (and VRAM clocks at ${NVIDIA_MAX_MEM_CLK:-max} MHz when
  supported) via 'nvidia-smi -lgc/-lmc' and a persistent systemd service. Removes clock
  ramp-up delay for stable, lowest-latency token decode.
EOF
  echo -e "\n${C_YELLOW}[WARNING] Locked clocks keep the GPU at high power even when idle${C_RESET}"
  echo -e "${C_YELLOW}          and hardly provide gains for sustained, GPU-bound generation.${C_RESET}"
}
apply_nvidia_clock_lock() {
  local smi_bin out
  smi_bin="$(command -v nvidia-smi)"
  if ! out="$(run_root "$smi_bin" -lgc "${NVIDIA_MAX_GFX_CLK},${NVIDIA_MAX_GFX_CLK}" 2>&1)"; then
    echo -e "${C_YELLOW}nvidia-smi -lgc is not supported on this GPU: ${out}${C_RESET}"
    return 1
  fi
  local mem_start="" mem_stop=""
  if [[ -n "$NVIDIA_MAX_MEM_CLK" ]]; then
    mem_start="ExecStart=-${smi_bin} -lmc ${NVIDIA_MAX_MEM_CLK},${NVIDIA_MAX_MEM_CLK}"
    mem_stop="ExecStop=-${smi_bin} -rmc"
  fi
  install_service nvidia-clock-lock.service <<EOF
[Unit]
Description=Lock NVIDIA GPU Clocks at Maximum for Strata
After=nvidia-persistenced.service nvidia-powerd.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${smi_bin} -lgc ${NVIDIA_MAX_GFX_CLK},${NVIDIA_MAX_GFX_CLK}
${mem_start}
ExecStop=-${smi_bin} -rgc
${mem_stop}

[Install]
WantedBy=multi-user.target
EOF
}
revert_nvidia_clock_lock() {
  remove_service nvidia-clock-lock.service
  run_root nvidia-smi -rgc >/dev/null 2>&1 || true
  run_root nvidia-smi -rmc >/dev/null 2>&1 || true
}

# 12i. NVIDIA ECC
applicable_nvidia_ecc() { [[ "$HAS_NVIDIA" == true && -n "$NVIDIA_ECC_CUR" ]]; }
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
  if run_root nvidia-smi -e 0; then
    refresh_nvidia_ecc
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
  else
    echo -e "${C_YELLOW}Could not change ECC mode on this GPU.${C_RESET}"
    return 1
  fi
}
revert_nvidia_ecc() {
  run_root nvidia-smi -e 1 && { refresh_nvidia_ecc; REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true; }
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
status_amd_apu_memory() { [[ -n "$(kernel_param_value ttm.pages_limit)" ]]; }
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
  REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
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
  [[ -f /etc/systemd/system/strata-ryzenadj.service ]] && return 0
  is_amd_mobile_apu_cpu || return 1
  command -v ryzenadj >/dev/null 2>&1 || pkg_available repo ryzenadj || pkg_available aur ryzenadj
}
title_ryzenadj_tdp() { echo "Ryzen APU Sustained Power Limits (STAPM/PPT via ryzenadj)"; }
status_ryzenadj_tdp() { [[ -f /etc/systemd/system/strata-ryzenadj.service ]] && unit_enabled strata-ryzenadj.service; }
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
  [[ -f /etc/systemd/system/strata-rapl.service ]] && return 0
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
status_intel_rapl() { [[ -f /etc/systemd/system/strata-rapl.service ]] && unit_enabled strata-rapl.service; }
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
  if command -v tuned-adm >/dev/null 2>&1 && tuned-adm list 2>/dev/null | grep -q "accelerator-performance"; then
    echo accelerator-performance
  else
    echo throughput-performance
  fi
}
title_tuned_profile() { echo "tuned Profile (throughput-performance / accelerator-performance)"; }
note_tuned_profile() { echo -e "${C_YELLOW}[!] Higher idle power, minimal gain${C_RESET}"; }
status_tuned_profile() {
  unit_active tuned.service || return 1
  tuned-adm active 2>/dev/null | grep -qE "throughput-performance|accelerator-performance"
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
revert_iommu_pt() { remove_kernel_param "iommu=pt"; REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true; }

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
status_jetson_perf() { [[ -f /etc/systemd/system/strata-jetson-perf.service ]] && unit_enabled strata-jetson-perf.service; }
explain_jetson_perf() { echo -e "Impact:\n  Switches the Jetson to its MAXN power model (nvpmodel) and pins CPU/GPU/EMC clocks\n  to maximum (jetson_clocks) at every boot. Clocks are restored on revert."; }
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
  (( RAM_GB >= 64 )) && (( $(numa_node_count) > 1 ))
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
  REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
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
  run_root systemctl enable --now "$u"
}
revert_scx_scheduler() {
  local u
  u="$(scx_unit)" && run_root systemctl disable --now "$u" 2>/dev/null || true
}

# 12w. AMD X3D V-Cache Mode
applicable_amd_x3d_mode() {
  [[ -f /etc/systemd/system/strata-amd-x3d.service ]] && return 0
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
  [[ -n "$STRATA_POLLER_PID" ]] && { kill "$STRATA_POLLER_PID" 2>/dev/null || true; wait "$STRATA_POLLER_PID" 2>/dev/null || true; STRATA_POLLER_PID=""; }
  [[ -n "$STRATA_UPDATE_CACHE_FILE" ]] && rm -f "$STRATA_UPDATE_CACHE_FILE" "${STRATA_UPDATE_CACHE_FILE}.tmp" 2>/dev/null || true
}

start_strata_update_poller() {
  [[ -n "$STRATA_BIN" ]] || return 0
  [[ -n "$STRATA_UPDATE_CACHE_FILE" ]] || STRATA_UPDATE_CACHE_FILE="$(mktemp /tmp/strata-update-check.XXXXXX 2>/dev/null || echo "")"
  [[ -n "$STRATA_UPDATE_CACHE_FILE" ]] || return 0
  (
    while true; do
      check_strata_update_sync >/dev/null 2>&1 || true
      sleep 60
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
  if [[ "$HAS_NVIDIA" == false && "$HAS_AMD" == false && "$HAS_INTEL_ARC" == false ]]; then
    echo -e "${C_YELLOW}[WARNING] No dedicated NVIDIA, AMD Radeon, or Intel Arc GPU detected (${GPU_SUMMARY}). Strata models may not run.${C_RESET}"
  elif [[ "$HAS_NVIDIA" == true && "$NVIDIA_VRAM_MB" -gt 0 && "$NVIDIA_VRAM_MB" -lt 6144 ]]; then
    echo -e "${C_YELLOW}[WARNING] NVIDIA GPU VRAM is $((NVIDIA_VRAM_MB / 1024)) GiB (< 6 GiB). Larger Strata models may not fit in VRAM.${C_RESET}"
  fi
}

status_strata_manager() { [[ -n "$STRATA_BIN" ]] && strata_service_installed; }
explain_strata_manager() {
  cat <<'EOF'
Impact:
  Installs Strata (Niko1221/Strata), checks for updates ('strata update'),
  runs 'strata launch', and installs/uninstalls strata.service using a saved preset.
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
apply_strata_manager() {
  refresh_strata_bin
  if [[ -z "$STRATA_BIN" ]]; then
    if confirm_yn "Strata is not installed. Install Strata now? [Y/n]: " "Y"; then
      run_as_user "curl -fsSL https://github.com/Niko1221/Strata/releases/latest/download/install.sh | sh"
      refresh_strata_bin
      [[ -n "$STRATA_BIN" && -z "$STRATA_POLLER_PID" ]] && start_strata_update_poller
    fi
  else
    echo -e "${C_GREEN}Strata is installed at: ${STRATA_BIN}${C_RESET}"
    echo -e "${C_DIM}Checking for Strata updates...${C_RESET}"
    if check_strata_update_sync; then
      echo -e "${C_CYAN}An update is available for Strata (${STRATA_UPDATE_SUMMARY})!${C_RESET}"
      perform_strata_update
    else
      echo -e "${C_GREEN}Strata is up to date.${C_RESET}"
    fi
  fi

  refresh_strata_bin
  [[ -n "$STRATA_BIN" ]] || return 0

  echo ""
  confirm_yn "Launch Strata interactively now ('strata launch')? [y/N]: " "N" && run_as_user_exec "$STRATA_BIN" launch

  echo ""
  if strata_service_installed; then
    echo -e "${C_GREEN}strata.service is currently installed.${C_RESET}"
    echo "  1) Change preset / reinstall strata.service"
    echo "  2) Uninstall strata.service"
    echo "  3) Skip"
    read -r -p "Choose [1-3]: " svc_choice
    case "$svc_choice" in
      1) install_strata_service_fn ;;
      2) remove_service strata.service && echo -e "${C_GREEN}strata.service uninstalled.${C_RESET}" ;;
      3|"") ;;
      *) echo -e "${C_RED}Invalid selection '${svc_choice}'. Cancelled.${C_RESET}" ;;
    esac
  else
    local preset_count
    preset_count="$(list_strata_presets | wc -l)"
    if (( preset_count > 0 )); then
      confirm_yn "Saved presets detected ($preset_count). Install Strata as a systemd service? [y/N]: " "N" && install_strata_service_fn
    else
      echo -e "${C_DIM}No saved presets found yet; run 'strata launch' to create one first.${C_RESET}"
    fi
  fi
}
revert_strata_manager() {
  strata_service_installed && remove_service strata.service && echo -e "${C_GREEN}strata.service uninstalled.${C_RESET}" || echo -e "${C_YELLOW}strata.service is not installed.${C_RESET}"
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
  local pct="$1" width="${2:-20}"
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
      if [[ "$tz_type" == "x86_pkg_temp" || "$tz_type" == "cpu"* ]]; then
        local mc
        mc="$(cat "$tz_dir/temp" 2>/dev/null || echo 0)"
        [[ "$mc" =~ ^[0-9]+$ ]] && (( mc > 0 )) && { cpu_temp=$((mc / 1000)); break; }
      fi
    done
  fi
  if [[ -z "$sys_pwr_w" ]]; then
    local bat_p
    for bat_p in /sys/class/power_supply/BAT*/power_now; do
      if [[ -r "$bat_p" ]]; then
        local uw
        uw="$(cat "$bat_p" 2>/dev/null || echo 0)"
        (( uw > 0 )) && { sys_pwr_w=$((uw / 1000000)); break; }
      fi
    done
  fi

  # CPU package power (intel-rapl, when readable)
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
  [[ -n "$cpu_pwr_w" ]] && pwr_parts+=("CPU ${cpu_pwr_w}W")
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
}

build_sys_info_lines() {
  SYS_INFO_LINES=()
  SYS_INFO_LINES+=("$(printf "%bSystem Information:%b" "${C_BOLD}" "${C_RESET}")")
  SYS_INFO_LINES+=("$(printf "%bOS:     %s (%s) | Kernel: %s | Laptop: %s%b" "${C_DIM}" "${OS_PRETTY:-$DISTRO_ID}" "$DISTRO_FAMILY" "$KERNEL_VER" "$IS_LAPTOP" "${C_RESET}")")
  SYS_INFO_LINES+=("$(printf "%bCPU:    %s%b" "${C_DIM}" "$CPU_SUMMARY" "${C_RESET}")")
  SYS_INFO_LINES+=("$(printf "%bRAM:    %s GiB%s%b" "${C_DIM}" "$RAM_GB" "$RAM_DETAILS" "${C_RESET}")")
  SYS_INFO_LINES+=("$(printf "%bGPU(s): %s%b" "${C_DIM}" "$GPU_SUMMARY" "${C_RESET}")")
  if (( TOTAL_VRAM_MB > 0 )); then
    local total_vram_gb
    total_vram_gb="$(awk "BEGIN {g=$TOTAL_VRAM_MB/1024; if (g == int(g)) printf \"%d\", g; else printf \"%.1f\", g}")"
    SYS_INFO_LINES+=("$(printf "%bVRAM:   %s GiB%b" "${C_DIM}" "$total_vram_gb" "${C_RESET}")")
  fi
  if [[ "$HAS_NVIDIA" == true && -n "$NVIDIA_CURRENT_PL" ]]; then
    SYS_INFO_LINES+=("$(printf "%bNVIDIA Power Limit: %sW (Default: %sW, Max: %sW)%b" "${C_DIM}" "$NVIDIA_CURRENT_PL" "$NVIDIA_DEFAULT_PL" "$NVIDIA_MAX_PL" "${C_RESET}")")
  fi
  append_gpu_pcie_lines
  [[ -n "$IS_VIRT" ]] && SYS_INFO_LINES+=("$(printf "%bVirt:   %s (hardware-specific steps hidden)%b" "${C_DIM}" "$IS_VIRT" "${C_RESET}")")
  local rl pdl
  for rl in "${RAM_HEALTH_LINES[@]}" "${GPU_TOPO_LINES[@]}"; do [[ -n "$rl" ]] && SYS_INFO_LINES+=("$rl"); done
  pdl="$(power_daemon_conflict_line)"
  [[ -n "$pdl" ]] && SYS_INFO_LINES+=("$pdl")
  if grep -qiE "PowerEdge|ProLiant|ThinkSystem|Supermicro|PRIMERGY|SYS-[0-9]" <<<"${SYS_VENDOR} ${PRODUCT_NAME}"; then
    SYS_INFO_LINES+=("$(printf "%bServer: set the BIOS/BMC system power profile to 'Performance' (not automated)%b" "${C_DIM}" "${C_RESET}")")
  fi
}

pad_ansi_col() {
  local str="$1" width="$2"
  local vis
  vis="$(sed $'s/\033\\[[0-9;]*m//g' <<< "$str")"
  local pad=$(( width - ${#vis} ))
  if (( pad > 0 )); then
    printf "%s%*s" "$str" "$pad" ""
  else
    printf "%s" "$str"
  fi
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
}

print_stats_and_info_grid() {
  local inplace="${1:-false}" eol=""
  [[ "$inplace" == true ]] && eol=$'\033[K'

  print_live_stats "$inplace" || true
  local term_cols=120
  [[ -t 1 ]] && term_cols="$(tput cols 2>/dev/null || echo 120)"

  local out="" total_lines=0
  if (( term_cols >= 110 )); then
    local n_left="${#LIVE_STAT_LINES[@]}" n_right="${#SYS_INFO_LINES[@]}"
    local max_rows=$(( n_left > n_right ? n_left : n_right ))
    local r left_s right_s
    local sep
    sep="$(printf "  %b│%b  " "${C_DIM}" "${C_RESET}")"
    for ((r=0; r<max_rows; r++)); do
      left_s=""
      right_s=""
      (( r < n_left )) && left_s="${LIVE_STAT_LINES[$r]}"
      (( r < n_right )) && right_s="${SYS_INFO_LINES[$r]}"
      if (( r > 0 )); then out+=$'\n'; fi
      out+="$(pad_ansi_col "$left_s" 56)${sep}${right_s}${eol}"
    done
    total_lines="$max_rows"
  else
    local l
    for l in "${LIVE_STAT_LINES[@]}"; do
      [[ -n "$out" ]] && out+=$'\n'
      out+="${l}${eol}"
      ((total_lines++))
    done
    out+=$'\n'"${eol}"
    ((total_lines++))
    for l in "${SYS_INFO_LINES[@]}"; do
      out+=$'\n'"${l}${eol}"
      ((total_lines++))
    done
  fi
  collect_strata_stats_lines
  if (( ${#STRATA_STAT_LINES[@]} > 0 )); then
    out+=$'\n'"${eol}"
    ((total_lines++))
    local sl
    for sl in "${STRATA_STAT_LINES[@]}"; do
      out+=$'\n'"${sl}${eol}"
      ((total_lines++))
    done
  fi
  LIVE_STATS_COUNT="$total_lines"
  printf "%s\n" "$out"
}

print_header() {
  clear 2>/dev/null || true
  local _rule_w=120 _hdr_eq="" _hdr_rule=""
  [[ -t 1 ]] && _rule_w="$(tput cols 2>/dev/null || echo 120)"
  (( _rule_w > 135 )) && _rule_w=135
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
  build_sys_info_lines
  print_stats_and_info_grid false
  printf -v _hdr_rule "%*s" "$_rule_w" ""
  echo -e "${C_DIM}${_hdr_rule// /─}${C_RESET}"
  POST_HEADER_LINES=2
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

read_step_action() {
  local -n _act_out="$1"
  if [[ ! -t 0 || ! -t 1 ]]; then
    read -r -p "Select action: " _act_out || exit 0
    return 0
  fi

  local buf="" ch="" esc_seq="" rc=0
  printf "Select action: "
  while true; do
    rc=0
    IFS= read -rsn1 ch || rc=$?
    if (( rc != 0 )); then
      printf "\n"
      exit 0
    fi
    if [[ -z "$ch" ]]; then
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
    else
      buf+="$ch"
      printf "%s" "$ch"
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

    echo -e "${C_BOLD}Step $((idx + 1)) of ${total}: $("title_${step}")${C_RESET}"
    [[ "$applied" == true ]] && echo -e "Status: ${C_GREEN}[APPLIED]${C_RESET}" || echo -e "Status: ${C_YELLOW}[NOT APPLIED]${C_RESET}"
    echo -e "${C_DIM}----------------------------------------------------------------------${C_RESET}"
    "explain_${step}"
    echo -e "${C_DIM}----------------------------------------------------------------------${C_RESET}\n"

    if [[ "$step" == "strata_manager" ]]; then
      echo -e "  ${C_GREEN}[a]${C_RESET} Open Strata Install / Update / Launch / Service menu"
      strata_service_installed && echo -e "  ${C_RED}[r]${C_RESET} Uninstall strata.service"
    else
      if [[ "$applied" == true ]]; then
        echo -e "  ${C_RED}[r]${C_RESET} Revert this optimization"
      else
        echo -e "  ${C_GREEN}[a]${C_RESET} Apply this optimization"
      fi
    fi

    [[ "$STRATA_UPDATE_AVAILABLE" == true ]] && echo -e "  ${C_BGREEN}[u]${C_RESET} Install Strata update (${STRATA_UPDATE_SUMMARY})"
    echo -e "  ${C_DIM}[n]${C_RESET} Next step (Skip)   ${C_DIM}[b]${C_RESET} Previous step   ${C_DIM}[i/Esc]${C_RESET} Back to Index   ${C_DIM}[q]${C_RESET} Quit\n"
    read_step_action action
    case "$action" in
      __esc__|i|I) return 0 ;;
      u|U)
        if [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
          echo ""; perform_strata_update; pause_prompt
        else
          echo -e "${C_YELLOW}No Strata update available.${C_RESET}"; sleep 1
        fi
        ;;
      a|A)
        if [[ "$step" != "strata_manager" && "$applied" == true ]]; then
          echo -e "${C_YELLOW}This optimization is already applied.${C_RESET}"; sleep 1
        else
          echo ""; "apply_${step}"; prompt_reboot_if_needed; pause_prompt
          [[ "$mode" == "single" ]] && return 0
        fi
        ;;
      r|R)
        if [[ "$applied" == true ]] || { [[ "$step" == "strata_manager" ]] && strata_service_installed; }; then
          echo ""; "revert_${step}"; pause_prompt
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
  local term_lines=40 can_live=false
  if [[ ! -t 1 || ! -t 0 ]]; then
    read -r -p "Choice: " _out_var || exit 0
    return 0
  fi

  term_lines="$(tput lines 2>/dev/null || echo 40)"
  (( lines_up > 0 && lines_up + 1 <= term_lines )) && can_live=true

  local tmp_file="" sampler_pid=""
  if [[ "$can_live" == true ]]; then
    tmp_file="$(mktemp /tmp/strata-stats.XXXXXX 2>/dev/null || echo "")"
    if [[ -n "$tmp_file" ]]; then
      (
        while true; do
          sleep 1
          print_stats_and_info_grid true > "${tmp_file}.tmp" 2>/dev/null && mv -f "${tmp_file}.tmp" "$tmp_file" 2>/dev/null || true
        done
      ) &
      sampler_pid=$!
    fi
  fi

  _cleanup_live_sampler() {
    [[ -n "$sampler_pid" ]] && { kill "$sampler_pid" 2>/dev/null || true; wait "$sampler_pid" 2>/dev/null || true; }
    [[ -n "$tmp_file" ]] && rm -f "$tmp_file" "${tmp_file}.tmp" 2>/dev/null || true
  }
  trap '_cleanup_live_sampler; exit 0' INT TERM

  local buf="" ch="" rc=0 stats_block=""
  printf "Choice: "
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
        if [[ "$esc_seq" == \[* || "$esc_seq" == O* ]] && [[ ! "$esc_seq" =~ [A-Za-z~]$ ]]; then
          local _esc_ch="" _esc_n=0
          while (( _esc_n++ < 8 )) && IFS= read -rsn1 -t 0.01 _esc_ch; do
            [[ "$_esc_ch" =~ [A-Za-z~] ]] && break
          done
        fi
        if (( footer_lines > 0 && ${#ACTIVE_STEPS[@]} > 0 )); then
          local old_idx="$INDEX_SELECTED" new_idx="$INDEX_SELECTED" total_steps="${#ACTIVE_STEPS[@]}"
          if [[ "$esc_seq" == "[A" || "$esc_seq" == "OA" ]]; then
            new_idx=$(( (old_idx - 1 + total_steps) % total_steps ))
          elif [[ "$esc_seq" == "[B" || "$esc_seq" == "OB" ]]; then
            new_idx=$(( (old_idx + 1) % total_steps ))
          fi
          if (( new_idx != old_idx )); then
            INDEX_SELECTED="$new_idx"
            local old_up=$(( (total_steps - old_idx) + footer_lines ))
            local new_up=$(( (total_steps - new_idx) + footer_lines ))
            if (( old_up < term_lines && new_up < term_lines )); then
              local old_row new_row
              old_row="$(format_index_row "$old_idx" false)"
              new_row="$(format_index_row "$new_idx" true)"
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
        buf+="$ch"
        printf "%s" "$ch"
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
      if [[ -n "$tmp_file" && -s "$tmp_file" ]]; then
        stats_block="$(<"$tmp_file")"
        printf "\033[?2026h\033[?25l\033[s\033[%dA\r%s\033[u\033[?25h\033[?2026l" "$lines_up" "$stats_block"
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

format_index_row() {
  local idx="$1" selected="${2:-false}"
  local step="${ACTIVE_STEPS[$idx]}"
  local num=$(( idx + 1 ))
  local badge note_txt title_txt ptr row_num
  "status_${step}" && badge="${C_GREEN}[APPLIED]    ${C_RESET}" || badge="${C_YELLOW}[NOT APPLIED]${C_RESET}"
  if declare -F "note_${step}" >/dev/null 2>&1; then
    note_txt="$("note_${step}")"
  else
    note_txt="${C_DIM}-${C_RESET}"
  fi
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
  printf "%b %b  | %b | %b | %b" "$ptr" "$row_num" "$badge" "$title_txt" "$note_txt"
}

show_index() {
  while true; do
    build_active_steps
    if (( ${#ACTIVE_STEPS[@]} == 0 )); then
      INDEX_SELECTED=0
    elif (( INDEX_SELECTED >= ${#ACTIVE_STEPS[@]} )); then
      INDEX_SELECTED=$(( ${#ACTIVE_STEPS[@]} - 1 ))
    elif (( INDEX_SELECTED < 0 )); then
      INDEX_SELECTED=0
    fi
    print_header

    local body="" hw_warns=""
    hw_warns="$(format_strata_hw_warnings)"
    if [[ -n "$hw_warns" ]]; then
      body+="${hw_warns}"$'\n'
      body+="$(echo -e "${C_DIM}          You can still apply any host optimizations applicable to this machine below.${C_RESET}")"$'\n\n'
    fi

    body+="$(echo -e "${C_BOLD}Optimization Index (Applicable to this machine):${C_RESET}")"$'\n\n'
    body+="$(printf "  ${C_BOLD}%-3s | %-13s | %-74s | %s${C_RESET}" "#" "Status" "Optimization" "Notes")"$'\n'
    body+="$(printf "  %s" "----+---------------+----------------------------------------------------------------------------+------------------------------------")"$'\n'
    local idx
    for (( idx = 0; idx < ${#ACTIVE_STEPS[@]}; idx++ )); do
      if (( idx == INDEX_SELECTED )); then
        body+="$(format_index_row "$idx" true)"$'\n'
      else
        body+="$(format_index_row "$idx" false)"$'\n'
      fi
    done

    local footer_lines=8
    body+=$'\n'"$(echo -e "  ${C_BOLD}[w]${C_RESET} Start guided wizard from Step 1")"$'\n'
    if [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
      body+="$(echo -e "  ${C_BGREEN}[u]${C_RESET} Install Strata update (${STRATA_UPDATE_SUMMARY})")"$'\n'
      ((footer_lines++))
    fi
    body+="$(echo -e "  ${C_GREEN}[a]${C_RESET} Apply all recommended optimizations (excludes Strata & high-idle-power options)")"$'\n'
    body+="$(echo -e "  ${C_RED}[x]${C_RESET} Revert all recommended optimizations")"$'\n'
    body+="$(echo -e "  ${C_BOLD}[1-${#ACTIVE_STEPS[@]} / ↑↓+Enter]${C_RESET} Jump to or select a step")"$'\n'
    body+="$(echo -e "  ${C_BOLD}[r]${C_RESET} Reboot system")"$'\n'
    body+="$(echo -e "  ${C_BOLD}[q]${C_RESET} Quit")"$'\n\n'

    printf "%s" "$body"
    local body_lines lines_up
    body_lines="$(printf "%s" "$body" | wc -l)"
    lines_up=$(( LIVE_STATS_COUNT + POST_HEADER_LINES + body_lines ))
    read_choice_with_live_stats choice "$lines_up" "$footer_lines"

    case "$choice" in
      __refresh__) ;;
      "")
        if (( ${#ACTIVE_STEPS[@]} > 0 )); then
          run_step_view "$INDEX_SELECTED" "single"
        fi
        ;;
      u|U)
        if [[ "$STRATA_UPDATE_AVAILABLE" == true ]]; then
          echo ""; perform_strata_update; pause_prompt
        else
          echo -e "${C_YELLOW}No Strata update available.${C_RESET}"; sleep 1
        fi
        ;;
      w|W) run_step_view 0 "wizard" ;;
      a|A) run_recommended_batch "apply" ;;
      x|X) run_recommended_batch "revert" ;;
      r|R)
        confirm_yn "Reboot this system now? [y/N]: " "N" && { run_root systemctl reboot; exit 0; }
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

trap 'stop_strata_update_poller' EXIT
detect_environment
start_strata_update_poller
show_index
