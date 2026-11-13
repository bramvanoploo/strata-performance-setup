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
STRATA_BIN=""
DISTRO_FAMILY="unknown" DISTRO_ID="unknown" OS_PRETTY="" KERNEL_VER="" AUR_HELPER=""
HAS_NVIDIA=false HAS_NVIDIA_POWERD=false HAS_AMD=false HAS_INTEL_GPU=false HAS_INTEL_ARC=false
GPU_SUMMARY="" CPU_SUMMARY="" RAM_GB=0 RAM_DETAILS="" NVIDIA_VRAM_MB=0
HAS_MSI_EC=false SYS_VENDOR="" PRODUCT_NAME="" IS_LAPTOP=false HAS_ASPM=false
NVIDIA_DEFAULT_PL="" NVIDIA_MAX_PL="" NVIDIA_CURRENT_PL=""
REBOOT_REQUIRED=false REBOOT_PROMPT_PENDING=false
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
  elif lspci 2>/dev/null | grep -iE "vga|3d|display" | grep -qi "nvidia"; then
    HAS_NVIDIA=true
  fi

  local gpu_lines
  gpu_lines="$(lspci 2>/dev/null | grep -iE "vga|3d|display" || true)"
  GPU_SUMMARY="$(echo "$gpu_lines" | sed 's/^[^ ]* [^:]*: //' | paste -sd '; ' -)"
  [[ -z "$GPU_SUMMARY" ]] && GPU_SUMMARY="Unknown"
  echo "$gpu_lines" | grep -qiE "amd|ati|radeon" && HAS_AMD=true
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
  grep -qiE "TU10|TU11|GA10|AD10|RTX 20|RTX 30|RTX 40|GTX 16|A100|A10|A40|L40|RTX A" <<< "$GPU_SUMMARY" || return 1
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
strata_update_available() {
  [[ -n "$STRATA_BIN" ]] || return 1
  grep -qiE "update available|newer|out of date" <<< "$(run_as_user "$STRATA_BIN update --check 2>/dev/null" || true)"
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
    fi
  else
    echo -e "${C_GREEN}Strata is installed at: ${STRATA_BIN}${C_RESET}"
    echo -e "${C_DIM}Checking for Strata updates...${C_RESET}"
    if strata_update_available; then
      echo -e "${C_CYAN}An update is available for Strata!${C_RESET}"
      confirm_yn "Run 'strata update' now? [Y/n]: " "Y" && run_as_user "$STRATA_BIN update"
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

print_header() {
  clear 2>/dev/null || true
  print_logo
  echo -e "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
  echo -e "${C_BOLD}${C_CYAN}   Strata Host Performance Optimizer & Setup Wizard${C_RESET}"
  echo -e "${C_BOLD}${C_CYAN}======================================================================${C_RESET}"
  echo -e "${C_DIM}OS:     ${OS_PRETTY:-$DISTRO_ID} (${DISTRO_FAMILY}) | Kernel: ${KERNEL_VER} | Laptop: ${IS_LAPTOP}${C_RESET}"
  echo -e "${C_DIM}CPU:    ${CPU_SUMMARY}${C_RESET}"
  echo -e "${C_DIM}RAM:    ${RAM_GB} GiB${RAM_DETAILS}${C_RESET}"
  echo -e "${C_DIM}GPU(s): ${GPU_SUMMARY}${C_RESET}"
  if [[ "$HAS_NVIDIA" == true && -n "$NVIDIA_CURRENT_PL" ]]; then
    echo -e "${C_DIM}NVIDIA Power Limit: ${NVIDIA_CURRENT_PL}W (Default: ${NVIDIA_DEFAULT_PL}W, Max: ${NVIDIA_MAX_PL}W)${C_RESET}"
  fi
  if [[ "$REBOOT_REQUIRED" == true ]]; then
    echo -e "${C_YELLOW}[!] Reboot pending: newly added kernel parameters require a reboot to take effect.${C_RESET}"
  fi
  echo ""
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

    echo -e "  ${C_DIM}[n]${C_RESET} Next step (Skip)   ${C_DIM}[b]${C_RESET} Previous step   ${C_DIM}[i]${C_RESET} Back to Index   ${C_DIM}[q]${C_RESET} Quit\n"
    read -r -p "Select action: " action || exit 0
    case "$action" in
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
      i|I) return 0 ;;
      q|Q) exit 0 ;;
      *) echo -e "${C_RED}Invalid action '${action}'.${C_RESET}"; sleep 1 ;;
    esac
  done
}

show_index() {
  while true; do
    build_active_steps
    print_header

    local warn=false
    if (( RAM_GB > 0 && RAM_GB < 32 )); then
      echo -e "${C_YELLOW}[WARNING] System RAM is ${RAM_GB} GiB (< 32 GiB). Larger Strata models may not fit or may swap.${C_RESET}"
      warn=true
    fi
    if [[ "$HAS_NVIDIA" == false && "$HAS_AMD" == false && "$HAS_INTEL_ARC" == false ]]; then
      echo -e "${C_YELLOW}[WARNING] No dedicated NVIDIA, AMD Radeon, or Intel Arc GPU detected (${GPU_SUMMARY}). Strata models may not run.${C_RESET}"
      warn=true
    elif [[ "$HAS_NVIDIA" == true && "$NVIDIA_VRAM_MB" -gt 0 && "$NVIDIA_VRAM_MB" -lt 6144 ]]; then
      echo -e "${C_YELLOW}[WARNING] NVIDIA GPU VRAM is $((NVIDIA_VRAM_MB / 1024)) GiB (< 6 GiB). Larger Strata models may not fit in VRAM.${C_RESET}"
      warn=true
    fi
    [[ "$warn" == true ]] && echo -e "${C_DIM}          You can still apply any host optimizations applicable to this machine below.${C_RESET}\n"

    echo -e "${C_BOLD}Optimization Index (Applicable to this machine):${C_RESET}\n"
    printf "  ${C_BOLD}%-3s | %-13s | %-74s | %s${C_RESET}\n" "#" "Status" "Optimization" "Notes"
    printf "  %s\n" "----+---------------+----------------------------------------------------------------------------+------------------------------------"
    local i=1 step badge note_txt
    for step in "${ACTIVE_STEPS[@]}"; do
      "status_${step}" && badge="${C_GREEN}[APPLIED]    ${C_RESET}" || badge="${C_YELLOW}[NOT APPLIED]${C_RESET}"
      if declare -F "note_${step}" >/dev/null 2>&1; then
        note_txt="$("note_${step}")"
      else
        note_txt="${C_DIM}-${C_RESET}"
      fi
      printf "  %2d  | %b | %-74s | %b\n" "$i" "$badge" "$("title_${step}")" "$note_txt"
      ((i++))
    done

    echo -e "\n  ${C_BOLD}[w]${C_RESET} Start guided wizard from Step 1"
    echo -e "  ${C_GREEN}[a]${C_RESET} Apply all recommended optimizations (excludes Strata & high-idle-power options)"
    echo -e "  ${C_RED}[x]${C_RESET} Revert all recommended optimizations"
    echo -e "  ${C_BOLD}[1-${#ACTIVE_STEPS[@]}]${C_RESET} Jump directly to a step"
    echo -e "  ${C_BOLD}[r]${C_RESET} Reboot system"
    echo -e "  ${C_BOLD}[q]${C_RESET} Quit\n"
    read -r -p "Choice: " choice || exit 0

    case "$choice" in
      w|W|"") run_step_view 0 "wizard" ;;
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

detect_environment
show_index
