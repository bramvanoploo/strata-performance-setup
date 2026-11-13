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
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || eval echo "~$TARGET_USER")"
STRATA_BIN="" STRATA_VERSION="" STRATA_RUNNING_PRESET="" STRATA_RUNNING_URL=""
DISTRO_FAMILY="unknown" DISTRO_ID="unknown" OS_PRETTY="" KERNEL_VER="" AUR_HELPER=""
HAS_NVIDIA=false HAS_NVIDIA_POWERD=false HAS_AMD=false HAS_INTEL_GPU=false HAS_INTEL_ARC=false
GPU_SUMMARY="" GPU_RAW="" CPU_SUMMARY="" RAM_GB=0 RAM_DETAILS="" NVIDIA_VRAM_MB=0 TOTAL_VRAM_MB=0
HAS_MSI_EC=false SYS_VENDOR="" PRODUCT_NAME="" IS_LAPTOP=false HAS_ASPM=false
NVIDIA_DEFAULT_PL="" NVIDIA_MAX_PL="" NVIDIA_CURRENT_PL=""
REBOOT_REQUIRED=false REBOOT_PROMPT_PENDING=false
PREV_CPU_TOTAL="" PREV_CPU_IDLE="" PREV_RAPL_UJ="" PREV_RAPL_US="" LIVE_STATS_COUNT=0 POST_HEADER_LINES=0
declare -a LIVE_STAT_LINES=() SYS_INFO_LINES=() STRATA_STAT_LINES=()
STRATA_UPDATE_AVAILABLE=false STRATA_UPDATE_SUMMARY="" STRATA_UPDATE_CACHE_FILE="" STRATA_POLLER_PID=""
UNIT_FILES_CACHE=""
declare -A PKG_AVAIL_CACHE

# ------------------------------------------------------------------------------
# Core Helpers (Privileges, Packages, Services, Bootloader)
# ------------------------------------------------------------------------------
run_root() {
  if [[ $EUID -eq 0 ]]; then "$@"
  else sudo "$@"; fi
}

run_as_user() {
  if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
    su - "$TARGET_USER" -c "$*"
  else
    bash -c "$*"
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
  case "$DISTRO_FAMILY" in
    arch)   pacman -Qi "$1" >/dev/null 2>&1 ;;
    fedora) rpm -q "$1" >/dev/null 2>&1 ;;
    debian) dpkg -s "$1" >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
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
          [[ -n "$AUR_HELPER" ]] && run_as_user "$AUR_HELPER -Si '$pkg'" >/dev/null 2>&1 && rc=0
        else
          pacman -Si "$pkg" >/dev/null 2>&1 && rc=0
        fi
        ;;
      fedora) [[ "$mode" == "repo" ]] && dnf info --available "$pkg" >/dev/null 2>&1 && rc=0 ;;
      debian) [[ "$mode" == "repo" ]] && apt-cache show "$pkg" >/dev/null 2>&1 && rc=0 ;;
    esac
  fi
  PKG_AVAIL_CACHE[$key]=$rc
  return "$rc"
}

pkg_install() {
  case "$DISTRO_FAMILY" in
    arch)   run_root pacman -S --needed --noconfirm "$@" ;;
    fedora) run_root dnf install -y "$@" ;;
    debian) run_root apt-get update -qq && run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    *)      echo -e "${C_RED}Unsupported package manager.${C_RESET}"; return 1 ;;
  esac
}

aur_install() {
  [[ "$DISTRO_FAMILY" == "arch" && -n "$AUR_HELPER" ]] || {
    echo -e "${C_YELLOW}AUR helper (yay/paru) unavailable; please install: $*${C_RESET}"
    return 1
  }
  run_as_user "$AUR_HELPER -S --needed --noconfirm $*"
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

has_kernel_param() {
  local param="$1" f
  grep -Fqw "$param" /proc/cmdline 2>/dev/null && return 0
  for f in /etc/default/limine /etc/default/grub /etc/kernel/cmdline; do
    [[ -r "$f" ]] && grep -v '^[[:space:]]*#' "$f" | grep -Fqw "$param" && return 0
  done
  return 1
}

add_kernel_param() {
  local param="$1"
  grep -qw "$param" /proc/cmdline 2>/dev/null && return 0

  if [[ -f /etc/default/limine ]]; then
    if ! grep -qw "$param" /etc/default/limine; then
      if grep -qE '^KERNEL_CMDLINE\[default\]\+?="' /etc/default/limine; then
        run_root sed -i "s/\(KERNEL_CMDLINE\[default\]+\{0,1\}=\"[^\"]*\)\"/\1 ${param}\"/" /etc/default/limine
      else
        echo "KERNEL_CMDLINE[default]+=\" ${param}\"" | run_root tee -a /etc/default/limine >/dev/null
      fi
      command -v limine-mkinitcpio >/dev/null 2>&1 && run_root limine-mkinitcpio || true
    fi
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${param}' to /etc/default/limine (reboot required).${C_RESET}"
  elif [[ -f /etc/default/grub ]]; then
    if ! grep -Fqw "$param" /etc/default/grub; then
      run_root sed -i "s/\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 ${param}\"/" /etc/default/grub
      if command -v grub-mkconfig >/dev/null 2>&1; then
        run_root grub-mkconfig -o /boot/grub/grub.cfg || true
      elif command -v grub2-mkconfig >/dev/null 2>&1; then
        run_root grub2-mkconfig -o /boot/grub2/grub.cfg || true
      fi
    fi
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${param}' to /etc/default/grub (reboot required).${C_RESET}"
  elif [[ -f /etc/kernel/cmdline ]]; then
    if ! grep -qw "$param" /etc/kernel/cmdline; then
      run_root sed -i "s/$/ ${param}/" /etc/kernel/cmdline
      command -v bootctl >/dev/null 2>&1 && run_root bootctl update >/dev/null 2>&1 || true
    fi
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_GREEN}Added '${param}' to /etc/kernel/cmdline (reboot required).${C_RESET}"
  else
    REBOOT_REQUIRED=true REBOOT_PROMPT_PENDING=true
    echo -e "${C_YELLOW}Please add '${param}' to your bootloader kernel command line manually.${C_RESET}"
  fi
}

remove_kernel_param() {
  local param="$1" esc
  esc="$(printf '%s' "$param" | sed 's/[.[\*^$()+?{|]/\\&/g')"
  if [[ -f /etc/default/limine ]] && grep -qw "$param" /etc/default/limine; then
    run_root sed -i "s/ *${esc}//g" /etc/default/limine
    command -v limine-mkinitcpio >/dev/null 2>&1 && run_root limine-mkinitcpio || true
  fi
  if [[ -f /etc/default/grub ]] && grep -Fqw "$param" /etc/default/grub; then
    run_root sed -i "s/ *${esc}//g" /etc/default/grub
    if command -v grub-mkconfig >/dev/null 2>&1; then
      run_root grub-mkconfig -o /boot/grub/grub.cfg || true
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
      run_root grub2-mkconfig -o /boot/grub2/grub.cfg || true
    fi
  fi
  if [[ -f /etc/kernel/cmdline ]] && grep -qw "$param" /etc/kernel/cmdline; then
    run_root sed -i "s/ *${esc}//g" /etc/kernel/cmdline
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

  if [[ -z "$ddr_type" || -z "$ddr_speed" ]] && command -v dmidecode >/dev/null 2>&1; then
    local dmi_out=""
    if [[ $EUID -eq 0 ]]; then dmi_out="$(dmidecode -t 17 2>/dev/null || true)"
    elif sudo -n true >/dev/null 2>&1; then dmi_out="$(sudo -n dmidecode -t 17 2>/dev/null || true)"; fi
    if [[ -n "$dmi_out" ]]; then
      [[ -z "$ddr_type" ]] && ddr_type="$(echo "$dmi_out" | awk -F': ' '/^\tType: (DDR|LPDDR)/ {print $2; exit}')"
      [[ -z "$ddr_speed" ]] && ddr_speed="$(echo "$dmi_out" | awk -F': ' '/^\tConfigured Memory Speed: [0-9]+/ {print $2; exit}' | awk '{print $1}')"
    fi
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
    raw_ver="$(run_as_user "$STRATA_BIN --version 2>/dev/null" | head -n1 || true)"
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
  st_json="$(run_as_user "$STRATA_BIN launch --status --output json 2>/dev/null" || true)"
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
    fi
  fi

  if [[ "$DISTRO_FAMILY" == "arch" ]]; then
    if command -v yay >/dev/null 2>&1; then
      AUR_HELPER="yay"
    elif command -v paru >/dev/null 2>&1; then
      AUR_HELPER="paru"
    fi
  fi

  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    HAS_NVIDIA=true
    local raw_cur raw_def raw_max raw_vram
    raw_cur="$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)"
    raw_def="$(nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)"
    raw_max="$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)"
    raw_vram="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)"
    [[ "$raw_cur" =~ ^[0-9]+(\.[0-9]+)?$ ]] && NVIDIA_CURRENT_PL="$(awk "BEGIN {printf \"%.0f\", $raw_cur}")"
    [[ "$raw_def" =~ ^[0-9]+(\.[0-9]+)?$ ]] && NVIDIA_DEFAULT_PL="$(awk "BEGIN {printf \"%.0f\", $raw_def}")"
    [[ "$raw_max" =~ ^[0-9]+(\.[0-9]+)?$ ]] && NVIDIA_MAX_PL="$(awk "BEGIN {printf \"%.0f\", $raw_max}")"
    [[ "$raw_vram" =~ ^[0-9]+$ ]] && NVIDIA_VRAM_MB="$raw_vram"
    local nv_vram_sum
    nv_vram_sum="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '/^[0-9]+$/ {s+=$1} END {print s+0}' || true)"
    [[ "$nv_vram_sum" =~ ^[0-9]+$ ]] && TOTAL_VRAM_MB=$((TOTAL_VRAM_MB + nv_vram_sum))
  elif lspci 2>/dev/null | grep -iE "vga|3d|display" | grep -qi "nvidia"; then
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

  RAM_GB="$(awk '/MemTotal/ {printf "%.0f", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0)"
  detect_ram_details
  KERNEL_VER="$(uname -r 2>/dev/null || echo unknown)"
  local cpu_model cpu_threads
  cpu_model="$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/  */ /g')"
  cpu_threads="$(nproc 2>/dev/null || echo '?')"
  CPU_SUMMARY="${cpu_model:-Unknown CPU} (${cpu_threads} threads)"

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
# Step Registry
# ------------------------------------------------------------------------------
ALL_STEPS=(
  base_tools prevent_sleep msi_cooling acpi_platform_profile
  asus_perf dell_thermal lenovo_legion system76_perf tuxedo_perf
  cpu_performance memlock_realtime pcie_aspm
  nvidia_persistenced nvidia_powerd nvidia_power_limit lact_overclock gpu_unlock
  amd_gpu_perf intel_gpu_perf
  sysctl_tuning zram_swap irq_balance strata_manager
)
ACTIVE_STEPS=()

build_active_steps() {
  ACTIVE_STEPS=()
  local step
  for step in "${ALL_STEPS[@]}"; do
    "applicable_${step}" && ACTIVE_STEPS+=("$step")
  done
}

is_recommended_step() {
  case "$1" in
    cpu_performance|pcie_aspm|strata_manager) return 1 ;;
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
  echo -e "${C_DIM}Excluded: CPU Performance & PCIe ASPM (minimal gain / higher idle power), Strata setup.${C_RESET}\n"

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

# 3g. TUXEDO
applicable_tuxedo_perf() {
  grep -qi "TUXEDO" <<< "$SYS_VENDOR" || return 1
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
EOF
  echo -e "\n${C_YELLOW}[WARNING] Enabling this option increases idle power consumption (often +5-10W)${C_RESET}"
  echo -e "${C_YELLOW}          and hardly provides any sustained performance gains over 'powersave'${C_RESET}"
  echo -e "${C_YELLOW}          when EPP (energy_performance_preference) is already 'performance'.${C_RESET}"
}
apply_cpu_performance() {
  if ! command -v cpupower >/dev/null 2>&1; then
    case "$DISTRO_FAMILY" in
      arch)   prompt_install_deps repo cpupower || true ;;
      fedora) prompt_install_deps repo kernel-tools || true ;;
      debian) prompt_install_deps repo linux-cpupower || true ;;
    esac
  fi
  command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl set performance 2>/dev/null || true
  install_service strata-cpu-perf.service <<'EOF'
[Unit]
Description=Set CPU Governor and Power Profile to Performance
After=multi-user.target power-profiles-daemon.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl set performance || true; [ -w /sys/devices/system/cpu/cpufreq/boost ] && echo 1 > /sys/devices/system/cpu/cpufreq/boost || true; for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "$g" ] && echo performance > "$g"; done; for e in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do [ -w "$e" ] && echo performance > "$e"; done'

[Install]
WantedBy=multi-user.target
EOF
}
revert_cpu_performance() {
  remove_service strata-cpu-perf.service
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
  up LLM token generation.
EOF
}
apply_lact_overclock() {
  if ! command -v lact >/dev/null 2>&1; then
    case "$DISTRO_FAMILY" in
      arch)   prompt_install_repo_or_aur lact || return 0 ;;
      fedora) prompt_install_deps repo lact || return 0 ;;
      debian) prompt_install_deps repo lact || return 0 ;;
    esac
  fi
  if ! python3 -c "import yaml" >/dev/null 2>&1; then
    case "$DISTRO_FAMILY" in
      arch)   prompt_install_deps repo python-yaml || true ;;
      fedora) prompt_install_deps repo python3-pyyaml || true ;;
      debian) prompt_install_deps repo python3-yaml || true ;;
    esac
  fi

  run_root systemctl enable --now lactd.service 2>/dev/null || true
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
    if run_root python3 -c "
import sys, yaml
p = '/etc/lact/config.yaml'
with open(p) as f: d = yaml.safe_load(f) or {}
gpus = d.get('gpus') or {}
if not gpus: sys.exit(1)
gpu_id = next(iter(gpus))
g = gpus[gpu_id] if isinstance(gpus[gpu_id], dict) else {}
g['gpu_clock_offsets'] = {0: int('$core_off')}
g['mem_clock_offsets'] = {0: int('$mem_off')}
g.setdefault('power_mizer_mode', 'Adaptive')
gpus[gpu_id] = g
d['gpus'] = gpus
with open(p, 'w') as f: yaml.safe_dump(d, f, sort_keys=False)
" 2>/dev/null; then
      run_root systemctl restart lactd.service
    else
      echo -e "${C_YELLOW}Could not auto-edit /etc/lact/config.yaml; configure in LACT GUI.${C_RESET}"
    fi
  fi
}
revert_lact_overclock() {
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
ExecStart=/bin/sh -c 'for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do [ -w "$f" ] && echo high > "$f"; done'
ExecStop=/bin/sh -c 'for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do [ -w "$f" ] && echo auto > "$f"; done'

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
ExecStart=/bin/sh -c 'for d in /sys/class/drm/card*; do [ -w "$d/gt_min_freq_mhz" ] && [ -r "$d/gt_max_freq_mhz" ] && cat "$d/gt_max_freq_mhz" > "$d/gt_min_freq_mhz"; done; for f in /sys/class/drm/card*/device/tile*/gt*/freq*; do [ -w "$f/min_freq" ] && [ -r "$f/rp0_freq" ] && cat "$f/rp0_freq" > "$f/min_freq"; done'
ExecStop=/bin/sh -c 'for d in /sys/class/drm/card*; do [ -w "$d/gt_min_freq_mhz" ] && [ -r "$d/gt_RPn_freq_mhz" ] && cat "$d/gt_RPn_freq_mhz" > "$d/gt_min_freq_mhz"; done; for f in /sys/class/drm/card*/device/tile*/gt*/freq*; do [ -w "$f/min_freq" ] && [ -r "$f/rpn_freq" ] && cat "$f/rpn_freq" > "$f/min_freq"; done'

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
title_sysctl_tuning() { echo "Kernel VM, Sysctl & Auto-Nice Tuning (ananicy-cpp / bpftune / sysctl)"; }
status_sysctl_tuning() { [[ -f /etc/sysctl.d/99-strata-perf.conf ]]; }
explain_sysctl_tuning() { echo -e "Impact:\n  Applies vm.vfs_cache_pressure=50, vm.dirty_ratio=10, vm.zone_reclaim_mode=0,\n  and enables ananicy-cpp / bpftune on Arch/CachyOS if available."; }
apply_sysctl_tuning() {
  run_root tee /etc/sysctl.d/99-strata-perf.conf >/dev/null <<'EOF'
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.zone_reclaim_mode = 0
EOF
  run_root sysctl --system >/dev/null 2>&1 || true
  if [[ "$DISTRO_FAMILY" == "arch" ]]; then
    local svc
    for svc in ananicy-cpp.service bpftune.service; do
      unit_exists "$svc" && run_root systemctl enable --now "$svc" 2>/dev/null || true
    done
  fi
}
revert_sysctl_tuning() {
  run_root rm -f /etc/sysctl.d/99-strata-perf.conf
  run_root sysctl --system >/dev/null 2>&1 || true
}

# 12b. zram Swap
applicable_zram_swap() {
  status_zram_swap && return 0
  case "$DISTRO_FAMILY" in
    arch)   pkg_available repo zram-generator ;;
    fedora) pkg_available repo zram-generator-defaults || pkg_available repo zram-generator ;;
    debian) pkg_available repo zram-tools ;;
    *)      return 1 ;;
  esac
}
title_zram_swap() { echo "Compressed zram Swap (zstd) for Large Model Safety"; }
status_zram_swap() { swapon --show=NAME --noheadings 2>/dev/null | grep -q "zram"; }
explain_zram_swap() { echo -e "Impact:\n  Enables zstd-compressed RAM swap (/dev/zram0) to prevent OOM crashes on\n  large models without slow NVMe swap thrashing."; }
apply_zram_swap() {
  status_zram_swap && { echo -e "${C_GREEN}zram swap is already active.${C_RESET}"; return 0; }
  case "$DISTRO_FAMILY" in
    arch)
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
}
revert_zram_swap() {
  case "$DISTRO_FAMILY" in
    arch|fedora)
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

# 13. Strata Manager
applicable_strata_manager() { return 0; }
title_strata_manager() { echo "Strata: Install, Update, Launch & Systemd Service"; }
strata_service_installed() { [[ -f /etc/systemd/system/strata.service ]]; }

check_strata_update_sync() {
  [[ -n "$STRATA_BIN" ]] || return 1
  local json_out parsed=""
  json_out="$(run_as_user "$STRATA_BIN update --check --json 2>/dev/null" || true)"
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
    txt_out="$(run_as_user "$STRATA_BIN update --check 2>/dev/null" || true)"
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
    json_out="$(run_as_user "$STRATA_BIN update --check --json 2>/dev/null" || true)"
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
  run_as_user "$STRATA_BIN update --yes" || rc=$?

  refresh_strata_bin
  if (( rc == 0 )); then
    echo -e "\n${C_GREEN}Strata update completed successfully!${C_RESET}"
    echo -e "${C_DIM}Installed version: $(run_as_user "$STRATA_BIN --version 2>/dev/null" || echo unknown)${C_RESET}"
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
status_strata_manager() { [[ -n "$STRATA_BIN" ]] && strata_service_installed; }
explain_strata_manager() {
  cat <<'EOF'
Impact:
  Installs Strata (Niko1221/Strata), checks for updates ('strata update'),
  runs 'strata launch', and installs/uninstalls strata.service using a saved preset.
EOF
}
list_strata_presets() {
  local preset_dir="$TARGET_HOME/.config/strata/launch-presets" cli_out f
  if [[ -n "$STRATA_BIN" ]]; then
    cli_out="$(run_as_user "$STRATA_BIN launch --list-presets 2>/dev/null" || true)"
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
ExecStart=${STRATA_BIN} launch --preset "${selected_preset}" --no-tui --yes
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
  confirm_yn "Launch Strata interactively now ('strata launch')? [y/N]: " "N" && run_as_user "$STRATA_BIN launch"

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
  if [[ -t 1 ]]; then
    echo -e "\033[1;96m  ███████╗████████╗██████╗  █████╗ ████████╗ █████╗ \033[0m"
    echo -e "\033[0;96m  ██╔════╝╚══██╔══╝██╔══██╗██╔══██╗╚══██╔══╝██╔══██╗\033[0m"
    echo -e "\033[0;36m  ███████╗   ██║   ██████╔╝███████║   ██║   ███████║\033[0m"
    echo -e "\033[1;34m  ╚════██║   ██║   ██╔══██╗██╔══██║   ██║   ██╔══██║\033[0m"
    echo -e "\033[0;35m  ███████║   ██║   ██║  ██║██║  ██║   ██║   ██║  ██║\033[0m"
    echo -e "\033[2;35m  ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝\033[0m"
    echo -e "  \033[0;36m═══════ \033[1;96mP E R F O R M A N C E   \033[1;35mS E T U P \033[0;35m════════\033[0m\n"
  else
    echo "  STRATA - PERFORMANCE SETUP"
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
    local nv_lines nv_line
    nv_lines="$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,power.draw,power.limit,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || true)"
    while IFS= read -r nv_line; do
      [[ -n "$nv_line" ]] || continue
      local g_u m_u m_t p_d p_l g_t
      local g_pct="" v_pct="" v_used="" v_tot="" pw="" plw="" ppct="" gtmp=""
      IFS=',' read -r g_u m_u m_t p_d p_l g_t <<< "$nv_line"
      g_u="${g_u// /}"; m_u="${m_u// /}"; m_t="${m_t// /}"; p_d="${p_d// /}"; p_l="${p_l// /}"; g_t="${g_t// /}"
      [[ "$g_u" =~ ^[0-9]+(\.[0-9]+)?$ ]] && g_pct="$(awk "BEGIN {printf \"%.0f\", $g_u}")"
      [[ "$g_t" =~ ^[0-9]+(\.[0-9]+)?$ ]] && gtmp="$(awk "BEGIN {printf \"%.0f\", $g_t}")"
      if [[ "$m_u" =~ ^[0-9]+(\.[0-9]+)?$ && "$m_t" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk "BEGIN {exit !($m_t > 0)}"; then
        read -r v_pct v_used v_tot <<< "$(awk "BEGIN {printf \"%.0f %.1f %.1f\", ($m_u/$m_t)*100, $m_u/1024, $m_t/1024}")"
      fi
      if [[ "$p_d" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        pw="$(awk "BEGIN {printf \"%.0f\", $p_d}")"
        total_gpu_pwr_w=$(( ${total_gpu_pwr_w:-0} + pw ))
        if [[ "$p_l" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk "BEGIN {exit !($p_l > 0)}"; then
          plw="$(awk "BEGIN {printf \"%.0f\", $p_l}")"
          ppct="$(awk "BEGIN {printf \"%.0f\", ($p_d/$p_l)*100}")"
        fi
      fi
      gpu_pcts+=("$g_pct")
      vram_pcts+=("$v_pct")
      vram_useds+=("$v_used")
      vram_tots+=("$v_tot")
      pwr_ws+=("$pw")
      pwr_lim_ws+=("$plw")
      pwr_pcts+=("$ppct")
      gpu_temps+=("$gtmp")
    done <<< "$nv_lines"
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
      coretemp|k10temp|zenpower)
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
  if [[ -z "$STRATA_RUNNING_PRESET" ]]; then
    [[ -n "$STRATA_BIN" ]] && STRATA_STAT_LINES+=("$(printf "  %-8s %bNot serving%b" "Status:" "${C_DIM}" "${C_RESET}")")
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
  print_logo
  echo -e "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
  echo -e "${C_BOLD}${C_CYAN}   Strata Host Performance Optimizer & Setup Wizard${C_RESET}"
  echo -e "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
  load_strata_update_state
  refresh_strata_running
  build_sys_info_lines
  print_stats_and_info_grid false
  local _rule_w=120 _hdr_rule=""
  [[ -t 1 ]] && _rule_w="$(tput cols 2>/dev/null || echo 120)"
  (( _rule_w > 135 )) && _rule_w=135
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
  local term_lines can_live=false
  if [[ -t 1 && -t 0 ]]; then
    term_lines="$(tput lines 2>/dev/null || echo 40)"
    (( lines_up > 0 && lines_up + 1 <= term_lines )) && can_live=true
  fi

  if [[ "$can_live" == false ]]; then
    read -r -p "Choice: " _out_var || exit 0
    return 0
  fi

  local tmp_file sampler_pid=""
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
            local old_row new_row
            old_row="$(format_index_row "$old_idx" false)"
            new_row="$(format_index_row "$new_idx" true)"
            printf "\033[?2026h\033[?25l\033[s\033[%dA\r\033[2K%s\033[u\033[s\033[%dA\r\033[2K%s\033[u\033[?25h\033[?2026l" \
              "$old_up" "$old_row" "$new_up" "$new_row"
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
  title_txt="$(printf "%-74s" "$("title_${step}")")"
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

    local body="" warn=false
    if (( RAM_GB > 0 && RAM_GB < 32 )); then
      body+="$(echo -e "${C_YELLOW}[WARNING] System RAM is ${RAM_GB} GiB (< 32 GiB). Larger Strata models may not fit or may swap.${C_RESET}")"$'\n'
      warn=true
    fi
    if [[ "$HAS_NVIDIA" == false && "$HAS_AMD" == false && "$HAS_INTEL_ARC" == false ]]; then
      body+="$(echo -e "${C_YELLOW}[WARNING] No dedicated NVIDIA, AMD Radeon, or Intel Arc GPU detected (${GPU_SUMMARY}). Strata models may not run.${C_RESET}")"$'\n'
      warn=true
    elif [[ "$HAS_NVIDIA" == true && "$NVIDIA_VRAM_MB" -gt 0 && "$NVIDIA_VRAM_MB" -lt 6144 ]]; then
      body+="$(echo -e "${C_YELLOW}[WARNING] NVIDIA GPU VRAM is $((NVIDIA_VRAM_MB / 1024)) GiB (< 6 GiB). Larger Strata models may not fit in VRAM.${C_RESET}")"$'\n'
      warn=true
    fi
    [[ "$warn" == true ]] && body+="$(echo -e "${C_DIM}          You can still apply any host optimizations applicable to this machine below.${C_RESET}")"$'\n\n'

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
