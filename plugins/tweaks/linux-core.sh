#!/usr/bin/env bash
# PLUGIN_ID: linux-core
# PLUGIN_NAME: linux-core
# PLUGIN_DESC: Core Linux kernel, memory, CPU, PCIe, and storage tweaks

register_tweak --id "cpu_performance" --stars 1 --tier "high_idle" --os "linux" --laptop-recommended true --vm-supported false --experimental-non-arch false
register_tweak --id "memlock_realtime" --stars 3 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "pcie_aspm" --stars 1 --tier "high_idle" --os "linux" --laptop-recommended true --vm-supported false --experimental-non-arch false
register_tweak --id "lact_overclock" --stars 4 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "sysctl_tuning" --stars 3 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "zram_swap" --stars 3 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "irq_balance" --stars 2 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "numa_balancing" --stars 2 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "headless_target" --stars 4 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "cstate_limit" --stars 1 --tier "high_idle" --os "linux" --laptop-recommended true --vm-supported false --experimental-non-arch false
register_tweak --id "gpu_groups" --stars 4 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "nvme_tuning" --stars 3 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "net_tuning" --stars 2 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "tuned_profile" --stars 1 --tier "high_idle" --os "linux" --laptop-recommended true --vm-supported false --experimental-non-arch false
register_tweak --id "iommu_pt" --stars 2 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "pcie_acs_disable" --stars 3 --tier "experimental" --os "linux" --laptop-recommended true --vm-supported false --experimental-non-arch false
register_tweak --id "numactl_interleave" --stars 3 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "hugepages_1g" --stars 1 --tier "opt_in" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false
register_tweak --id "scx_scheduler" --stars 2 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --experimental-non-arch false

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
applicable_memlock_realtime() { [[ "$IS_MACOS" == false ]]; }
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
status_lact_overclock() {
  local cfg
  cfg="$(lact_config_file)"
  unit_enabled lactd.service && [[ -f "$cfg" ]] && awk '
    /^[[:space:]]*(gpu_clock_offsets|mem_clock_offsets):/ {
      if ($0 ~ /\{[[:space:]]*\}/) { in_off=0; next }
      if ($0 ~ /:[[:space:]]*\{.*[0-9]/) { found=1; exit }
      match($0, /^[[:space:]]*/); base_ind=RLENGTH; in_off=1; next
    }
    in_off {
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= base_ind && $0 ~ /[^[:space:]]/) { in_off=0 }
      else if ($0 ~ /^[[:space:]]+[0-9]+:[[:space:]]*-?[0-9]+/) { found=1; exit }
    }
    END { exit !found }
  ' "$cfg" 2>/dev/null
}
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
  local cfg
  cfg="$(lact_config_file)"
  if [[ -f "${cfg}.bak.strata-setup" ]]; then
    run_root mv -f "${cfg}.bak.strata-setup" "$cfg"
    run_root systemctl restart lactd.service 2>/dev/null || true
  else
    run_root systemctl disable --now lactd.service 2>/dev/null || true
  fi
}


# 12. Sysctl & Scheduler
applicable_sysctl_tuning() { [[ "$IS_MACOS" == false ]]; }
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
applicable_irq_balance() { [[ "$IS_MACOS" == false ]] && [[ "$(nproc 2>/dev/null || echo 1)" -gt 1 ]] && { command -v irqbalance >/dev/null 2>&1 || pkg_available repo irqbalance; }; }
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
  [[ "$IS_MACOS" == false && "$TARGET_USER" != "root" ]] || return 1
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
  [[ "$IS_MACOS" == false ]] || return 1
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
revert_iommu_pt() { remove_kernel_param "iommu=pt" "iommu.passthrough=1"; }

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
  add_kernel_param "default_hugepagesz=1G" "hugepagesz=1G" "hugepages=$(( RAM_GB / 4 ))"
}
revert_hugepages_1g() {
  local n v
  local -a rem=()
  for n in default_hugepagesz hugepagesz hugepages; do
    v="$(kernel_param_value "$n" || true)"
    [[ -n "$v" ]] && rem+=("${n}=${v}")
  done
  (( ${#rem[@]} > 0 )) && remove_kernel_param "${rem[@]}"
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
