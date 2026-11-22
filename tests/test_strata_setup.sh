#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/strata-performance-setup.sh"

TMP_DIR="$(mktemp -d)"
RESULTS_FILE="${TMP_DIR}/results.log"
: > "$RESULTS_FILE"
trap 'rm -rf "$TMP_DIR"' EXIT

pass() { echo "P" >> "$RESULTS_FILE"; printf 'PASS: %s\n' "$1"; }
fail() { echo "F" >> "$RESULTS_FILE"; printf 'FAIL: %s\n' "$1" >&2; }

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$msg"
  else
    fail "$msg (got=${got@Q}, want=${want@Q})"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    pass "$msg"
  else
    fail "$msg (missing ${needle@Q})"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if ! grep -qF -- "$needle" <<<"$haystack"; then
    pass "$msg"
  else
    fail "$msg (unexpected ${needle@Q})"
  fi
}

TMP_DIR_UNUSED=""

# 1. Syntax & CLI flags
bash -n "$SCRIPT" && pass "bash -n syntax check (core)" || fail "bash -n syntax check (core)"
for pf in "${REPO_ROOT}/plugins/hosts/"*.sh "${REPO_ROOT}/plugins/tweaks/"*.sh; do
  [[ -f "$pf" ]] || continue
  bash -n "$pf" && pass "bash -n syntax check ($(basename "$(dirname "$pf")")/$(basename "$pf"))" || fail "bash -n syntax check ($(basename "$pf"))"
done

"$SCRIPT" --help >/dev/null && pass "--help exits 0" || fail "--help exits 0"
"$SCRIPT" --check >/dev/null && pass "--check exits 0" || fail "--check exits 0"
"$SCRIPT" --no-plugins --check >/dev/null && pass "--no-plugins --check exits 0" || fail "--no-plugins --check exits 0"
"$SCRIPT" --plugin strata --check >/dev/null && pass "--plugin strata --check exits 0" || fail "--plugin strata --check exits 0"
list_out="$("$SCRIPT" --list-plugins)"
assert_contains "$list_out" "strata" "--list-plugins lists strata host plugin"
assert_contains "$list_out" "linux-core" "--list-plugins lists linux-core tweak pack"

rc=0; "$SCRIPT" --unknown-flag >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "unknown CLI option exits 2"

rc=0; "$SCRIPT" --strata-api-key "" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "empty --strata-api-key exits 2"

# Standalone cache & checksum-verified plugin load via file:// base URL
if command -v curl >/dev/null 2>&1; then
  standalone_dir="${TMP_DIR}/standalone"
  mkdir -p "$standalone_dir" "${TMP_DIR}/pcache"
  cp "$SCRIPT" "${standalone_dir}/strata-performance-setup.sh"
  chmod +x "${standalone_dir}/strata-performance-setup.sh"
  chk_out="$(STRATA_PLUGIN_BASE_URL="file://${REPO_ROOT}" STRATA_PLUGIN_CACHE_DIR="${TMP_DIR}/pcache" "${standalone_dir}/strata-performance-setup.sh" --plugin strata --check)"
  assert_contains "$chk_out" "Strata:" "standalone script fetches & loads strata plugin via registry"
  [[ -f "${TMP_DIR}/pcache/hosts/strata.sh" ]] && pass "standalone script caches fetched host plugin" || fail "standalone script caches fetched host plugin"
fi

# Source the script for unit tests (never runs main because BASH_SOURCE != $0)
# shellcheck source=/dev/null
source "$SCRIPT"

# Core-only checks before plugins are loaded
(
  NO_PLUGINS=false
  AVAILABLE_HOST_PLUGINS=("strata")
  row0="$(render_any_index_row 0 true)"
  row1="$(render_any_index_row 1 true)"
  assert_contains "$row0" "[STATS]" "core render_any_index_row renders STATS without strata plugin"
  assert_contains "$row1" "[STRATA]" "core render_any_index_row renders unloaded host plugin row"
  assert_eq "$(index_row_up_offset 1 5 0 9 30)" "28" "core index_row_up_offset computes host row offset"

  NO_PLUGINS=true
  assert_eq "$(index_row_up_offset 1 5 0 9 30)" "16" "core index_row_up_offset skips host rows when NO_PLUGINS=true"

  HAS_AMD=true AMD_GFX_ARCHS=(gfx1150) HAS_AMD_APU=false AMD_GTT_TOTAL_MB=0
  HAS_NVIDIA=false HAS_INTEL_GPU=false IS_MACOS=false IS_DGX_SPARK=false
  RAM_HEALTH_LINES=() GPU_TOPO_LINES=()
  amd_chk="$(print_check_summary)"
  assert_contains "$amd_chk" "AMD[gfx1150]" "print_check_summary handles missing-target AMD gfx without strata plugin"
)

load_all_local_plugins

# Override run_root so tests run unprivileged without sudo
run_root() { "$@"; }

# 2. Step & host plugin registry integrity
reg_ok=true
for s in "${ALL_STEPS[@]}"; do
  for fn in applicable title status explain apply revert; do
    declare -F "${fn}_${s}" >/dev/null || { fail "missing ${fn}_${s}"; reg_ok=false; }
  done
  [[ -n "${STEP_GAIN_PTS[$s]:-}" ]] || { fail "missing STEP_GAIN_PTS[$s]"; reg_ok=false; }
done
[[ "$reg_ok" == true ]] && pass "all ${#ALL_STEPS[@]} steps have handlers and STEP_GAIN_PTS"

host_ok=true
for hp in "${LOADED_HOST_PLUGINS[@]}"; do
  for fn in init menu_row open; do
    declare -F "${hp}_${fn}" >/dev/null || { fail "missing ${hp}_${fn}"; host_ok=false; }
  done
done
[[ "$host_ok" == true ]] && pass "all ${#LOADED_HOST_PLUGINS[@]} host plugins have required hooks"

# 3. Non-systemd install_service preserves User, WorkingDirectory, LimitMEMLOCK
(
  HAS_SYSTEMD=false HAS_LAUNCHD=false IS_UNRAID=false IS_SYNOLOGY=false
  STRATA_RC_DIR="${TMP_DIR}/rc.d"
  mkdir -p "$STRATA_RC_DIR"
  cur_user="$(id -un)"
  TARGET_USER="$cur_user"
  TARGET_HOME="${TMP_DIR}/home"
  mkdir -p "$TARGET_HOME"
  install_service strata.service <<EOF
[Unit]
Description=Test Strata

[Service]
User=${cur_user}
WorkingDirectory=${TARGET_HOME}
Environment=STRATA_SM70_TABLE=1
ExecStart=/bin/pwd
ExecStop=/bin/echo stopped
LimitMEMLOCK=infinity
EOF
  rc_file="${STRATA_RC_DIR}/rc.strata.strata"
  txt="$(cat "$rc_file")"
  assert_contains "$txt" "ulimit -l unlimited" "rc script sets ulimit -l unlimited"
  assert_contains "$txt" "cd '\''${TARGET_HOME}'\''" "rc script sets WorkingDirectory"
  assert_contains "$txt" "$cur_user" "rc script wraps execution for User="
  assert_contains "$txt" "export STRATA_SM70_TABLE=1" "rc script exports Environment="
  assert_eq "$("$rc_file" start | tail -n1)" "$TARGET_HOME" "rc script runs ExecStart inside WorkingDirectory"
  assert_contains "$(cat "${STRATA_RC_DIR}/rc.local")" "rc.strata.strata" "rc.local boot hook added"
  remove_service strata.service
  [[ ! -f "$rc_file" ]] && pass "remove_service deletes rc.d script" || fail "remove_service deletes rc.d script"
)

# 4. Bootloader parameter tests (STRATA_BOOT_ROOT)
# 4a. Empty /etc/kernel/cmdline + BLS entries
(
  BR="${TMP_DIR}/boot_sd"
  mkdir -p "${BR}/etc/kernel" "${BR}/boot/loader/entries" "${BR}/proc"
  : > "${BR}/etc/kernel/cmdline"
  printf 'title Linux\noptions root=UUID=123 rw\n' > "${BR}/boot/loader/entries/arch.conf"
  : > "${BR}/proc/cmdline"
  STRATA_BOOT_ROOT="$BR"
  DISTRO_FAMILY="arch"
  add_kernel_param "iommu=pt" "hugepages=16"
  assert_contains "$(cat "${BR}/etc/kernel/cmdline")" "iommu=pt hugepages=16" "empty /etc/kernel/cmdline populated"
  assert_contains "$(cat "${BR}/boot/loader/entries/arch.conf")" "options root=UUID=123 rw iommu=pt hugepages=16" "BLS entry also updated"
  remove_kernel_param "iommu=pt" "hugepages=16"
  assert_not_contains "$(cat "${BR}/etc/kernel/cmdline")" "iommu=pt" "removed from /etc/kernel/cmdline"
  assert_not_contains "$(cat "${BR}/boot/loader/entries/arch.conf")" "hugepages=16" "removed from BLS entry"
)

# 4b. rEFInd skips comments and recovery lines
(
  BR="${TMP_DIR}/boot_refind"
  mkdir -p "${BR}/boot" "${BR}/proc"
  : > "${BR}/proc/cmdline"
  cat > "${BR}/boot/refind_linux.conf" <<'EOF'
# "Example comment" "quiet"
"Boot with standard options"  "root=UUID=123 rw"
"Boot to single-user mode"    "root=UUID=123 rw single"
EOF
  STRATA_BOOT_ROOT="$BR"
  add_kernel_param "amdgpu.cwsr_enable=0"
  out="$(cat "${BR}/boot/refind_linux.conf")"
  assert_contains "$out" '"root=UUID=123 rw amdgpu.cwsr_enable=0"' "rEFInd standard line updated"
  assert_not_contains "$out" 'single amdgpu.cwsr_enable=0' "rEFInd single-user line untouched"
  assert_not_contains "$out" '"quiet amdgpu.cwsr_enable=0"' "rEFInd comment untouched"
)

# 4c. ELILO/LILO detection via kernel_param_value & single GRUB rebuild for multi-params
(
  BR="${TMP_DIR}/boot_elilo"
  mkdir -p "${BR}/etc" "${BR}/proc"
  : > "${BR}/proc/cmdline"
  printf 'append="root=/dev/sda1"\n' > "${BR}/etc/elilo.conf"
  STRATA_BOOT_ROOT="$BR"
  add_kernel_param "ttm.pages_limit=1024" "ttm.page_pool_size=1024"
  assert_eq "$(kernel_param_value ttm.pages_limit)" "1024" "kernel_param_value reads elilo.conf"
  has_kernel_param "ttm.page_pool_size=1024" && pass "has_kernel_param finds elilo.conf param" || fail "has_kernel_param elilo.conf"
  remove_kernel_param "ttm.pages_limit=1024" "ttm.page_pool_size=1024"
  assert_not_contains "$(cat "${BR}/etc/elilo.conf")" "ttm.pages_limit" "remove_kernel_param cleans elilo.conf"

  BRG="${TMP_DIR}/boot_grub"
  mkdir -p "${BRG}/etc/default" "${BRG}/boot/grub" "${BRG}/proc" "${TMP_DIR}/bin"
  : > "${BRG}/proc/cmdline"
  printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' > "${BRG}/etc/default/grub"
  cat > "${TMP_DIR}/bin/grub-mkconfig" <<EOF
#!/usr/bin/env bash
echo call >> "${TMP_DIR}/grub_calls"
EOF
  chmod +x "${TMP_DIR}/bin/grub-mkconfig"
  PATH="${TMP_DIR}/bin:${PATH}" STRATA_BOOT_ROOT="$BRG" DISTRO_FAMILY="debian"
  add_kernel_param "default_hugepagesz=1G" "hugepagesz=1G" "hugepages=8"
  assert_eq "$(wc -l < "${TMP_DIR}/grub_calls" | tr -d ' ')" "1" "batch add_kernel_param runs grub-mkconfig once"
  remove_kernel_param "default_hugepagesz=1G" "hugepagesz=1G" "hugepages=8"
  assert_eq "$(wc -l < "${TMP_DIR}/grub_calls" | tr -d ' ')" "2" "batch remove_kernel_param runs grub-mkconfig once"
)

# 5. run_as_user quoting safety
(
  IS_MACOS=true
  TARGET_USER="$(id -un)"
  MACOS_METAL_ENV_FILE="${TMP_DIR}/metal.conf"
  pwn_marker="${TMP_DIR}/pwned"
  printf 'STRATA_METAL_TEST=$(touch_%s)\n' "$pwn_marker" > "$MACOS_METAL_ENV_FILE"
  printf 'STRATA_METAL_TEST=$(touch\t%s)\n' "$pwn_marker" > "$MACOS_METAL_ENV_FILE"
  printf 'STRATA_METAL_TEST=$(touch/%s)\n' "$pwn_marker" > "$MACOS_METAL_ENV_FILE"
  # Even with $(...) without spaces:
  printf 'STRATA_METAL_TEST=$(touch${IFS}%s)\n' "$pwn_marker" > "$MACOS_METAL_ENV_FILE"
  run_as_user "true"
  [[ ! -e "$pwn_marker" ]] && pass "run_as_user safely quotes MACOS_METAL_ENV_FILE values" || fail "run_as_user executed injected subshell"
)

# 6. prompt_install_deps does not fall back to pkg_install on AUR failure
(
  pkg_installed() { return 1; }
  aur_install() { return 1; }
  pkg_install() { touch "${TMP_DIR}/repo_fallback_called"; return 0; }
  confirm_yn() { return 0; }
  rc=0
  prompt_install_deps aur some-aur-pkg >/dev/null || rc=$?
  assert_eq "$rc" "1" "prompt_install_deps returns aur_install failure"
  [[ ! -e "${TMP_DIR}/repo_fallback_called" ]] && pass "AUR failure does not trigger repo pkg_install" || fail "AUR failure triggered repo pkg_install"
)

# 7. is_step_managed_by_wizard pcie_aspm check
(
  HAS_SYSTEMD=false HAS_LAUNCHD=false IS_UNRAID=false IS_SYNOLOGY=false
  STRATA_RC_DIR="${TMP_DIR}/rc_aspm"
  STRATA_BOOT_ROOT="${TMP_DIR}/boot_aspm"
  mkdir -p "$STRATA_RC_DIR" "${STRATA_BOOT_ROOT}/proc"
  : > "${STRATA_BOOT_ROOT}/proc/cmdline"
  if is_step_managed_by_wizard pcie_aspm; then
    fail "pcie_aspm should not be wizard-managed when absent"
  else
    pass "pcie_aspm unmanaged when absent"
  fi
  printf '#!/bin/sh\n' > "${STRATA_RC_DIR}/rc.strata.strata-pcie-aspm"
  chmod +x "${STRATA_RC_DIR}/rc.strata.strata-pcie-aspm"
  is_step_managed_by_wizard pcie_aspm && pass "pcie_aspm managed when service installed" || fail "pcie_aspm managed when service installed"
  rm -f "${STRATA_RC_DIR}/rc.strata.strata-pcie-aspm"
  printf 'quiet pcie_aspm.policy=performance\n' > "${STRATA_BOOT_ROOT}/proc/cmdline"
  is_step_managed_by_wizard pcie_aspm && pass "pcie_aspm managed when kernel param present" || fail "pcie_aspm managed when kernel param present"
)

# 8. LACT status & revert with LACT_DAEMON_CONFIG_DIR
(
  LACT_DAEMON_CONFIG_DIR="${TMP_DIR}/lact"
  mkdir -p "$LACT_DAEMON_CONFIG_DIR"
  unit_enabled() { return 0; }
  systemctl() { return 0; }
  cat > "${LACT_DAEMON_CONFIG_DIR}/config.yaml" <<'EOF'
gpus:
  "1002:744C-1002:0E3A-0000:03:00.0":
    gpu_clock_offsets: {}
EOF
  if status_lact_overclock; then
    fail "empty gpu_clock_offsets: {} should not report applied"
  else
    pass "status_lact_overclock rejects empty {}"
  fi
  cat > "${LACT_DAEMON_CONFIG_DIR}/config.yaml" <<'EOF'
gpus:
  "1002:744C-1002:0E3A-0000:03:00.0":
    gpu_clock_offsets:
      0: 135
EOF
  cp "${LACT_DAEMON_CONFIG_DIR}/config.yaml" "${LACT_DAEMON_CONFIG_DIR}/config.yaml.bak.strata-setup"
  sed -i 's/135/200/' "${LACT_DAEMON_CONFIG_DIR}/config.yaml"
  status_lact_overclock && pass "status_lact_overclock detects custom config dir offsets" || fail "status_lact_overclock detects offsets"
  HAS_AMD=false
  revert_lact_overclock
  assert_contains "$(cat "${LACT_DAEMON_CONFIG_DIR}/config.yaml")" "0: 135" "revert_lact_overclock restores custom config dir backup"
)

# 9. apply_nvidia_power_limit catches permission errors
(
  mkdir -p "${TMP_DIR}/nvbin"
  cat > "${TMP_DIR}/nvbin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
echo "Insufficient Permissions" >&2
exit 1
EOF
  chmod +x "${TMP_DIR}/nvbin/nvidia-smi"
  PATH="${TMP_DIR}/nvbin:${PATH}"
  HAS_SYSTEMD=false HAS_LAUNCHD=false
  STRATA_RC_DIR="${TMP_DIR}/nv_rc"
  mkdir -p "$STRATA_RC_DIR"
  NVIDIA_GPU_INDICES=(0)
  NVIDIA_GPU_NAMES=("RTX 4090")
  NVIDIA_GPU_DEF_PL=(450)
  NVIDIA_GPU_MAX_PL=(600)
  NVIDIA_GPU_PL_SUPPORTED=(true)
  rc=0
  apply_nvidia_power_limit >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "1" "apply_nvidia_power_limit fails on permission error"
  [[ ! -f "${STRATA_RC_DIR}/rc.strata.nvidia-power-limit" ]] && pass "failed nvidia-smi does not install service" || fail "failed nvidia-smi installed service"
)

# 10. Power parsers & non-numeric sysfs resilience
(
  pm_sample=$'GPU Power: 4250 mW\nCPU Power: 12.50 W\nANE Power: 500 mW\nGPU HW active residency: 47.3%\nCurrent pressure level: Nominal'
  parsed="$(_parse_macos_powermetrics "%.2f" "$pm_sample")"
  assert_eq "$parsed" "47|4.25|12.50|17.25|Nominal" "_parse_macos_powermetrics parses mW/W/residency/combined"

  fake_drm="${TMP_DIR}/drm"
  mkdir -p "${fake_drm}/card0/device/hwmon/hwmon0"
  printf '0x1002\n' > "${fake_drm}/card0/device/vendor"
  printf '50\n' > "${fake_drm}/card0/device/gpu_busy_percent"
  printf 'N/A\n' > "${fake_drm}/card0/device/hwmon/hwmon0/power1_average"
  IS_MACOS=false HAS_NVIDIA=false HAS_AMD=true HAS_INTEL_ARC=false IS_JETSON=false
  STRATA_DRM_DIR="$fake_drm"
  err_out="$(print_live_stats false 2>&1 >/dev/null || true)"
  assert_eq "$err_out" "" "non-numeric AMD power1_average produces no stderr arithmetic errors"
)

# 10b. start_bench_power_sampler does not double-count Intel Arc in AMD loop
(
  set +e
  fake_drm="${TMP_DIR}/drm_hybrid"
  mkdir -p "${fake_drm}/card0/device/hwmon/hwmon0" "${fake_drm}/card1/device/hwmon/hwmon1"
  printf '0x1002\n' > "${fake_drm}/card0/device/vendor"
  printf '10000000\n' > "${fake_drm}/card0/device/hwmon/hwmon0/power1_average" # 10W AMD
  printf '0x8086\n' > "${fake_drm}/card1/device/vendor"
  printf '0xe20b\n' > "${fake_drm}/card1/device/device"
  printf '25000000\n' > "${fake_drm}/card1/device/hwmon/hwmon1/power1_average" # 25W Intel Arc B580
  IS_MACOS=false HAS_NVIDIA=false HAS_AMD=true HAS_INTEL_ARC=true IS_JETSON=false
  STRATA_DRM_DIR="$fake_drm"
  pwr_out="${TMP_DIR}/hybrid_pwr.txt"
  start_bench_power_sampler "$pwr_out"
  sleep 0.4
  stop_bench_power_sampler
  IFS='|' read -r _s _g _c _n < "$pwr_out"
  assert_eq "$_g" "35.0" "hybrid AMD+Intel Arc GPU power sums 10W+25W without double-counting"
)

# 11. Unified benchmark JSON pipeline
(
  STRATA_BENCH_HISTORY_FILE="${TMP_DIR}/hist/bench-history.json"
  res_dir="${TMP_DIR}/bench/results/run1"
  mkdir -p "$res_dir"
  cat > "${res_dir}/results.json" <<'EOF'
{
  "run": {"id": "r1", "started_at": "2026-11-20T10:00:00Z", "required_duration_s": 12.5},
  "protocol": {"profile": "quick"},
  "model": {"name": "Qwen3-32B", "quantization": "Q4_K_M"},
  "summaries": [
    {"phase": "performance", "metric": "decode_tps", "median": 85.4},
    {"phase": "performance", "metric": "prompt_tps", "median": 420.0}
  ],
  "request_counts": {"perf": {"attempted": 5, "failed": 0}},
  "quality": {"sanity_checks_passed": 5, "sanity_checks_total": 5}
}
EOF
  STRATA_RUNNING_PRESET="qwen3" STRATA_RUNNING_URL="http://127.0.0.1:8080"
  save_bench_history_entry "${res_dir}/results.json" "quick" "120.5" "90.0" "25.0" "40" "sysctl_tuning,zram_swap" "sysctl_tuning,zram_swap"
  cnt="$(cd "$TMP_DIR" && count_bench_history)"
  assert_eq "$cnt" "1" "count_bench_history counts saved entry"

  STRATA_BENCH_CACHE_KEY=""
  cd "$TMP_DIR" && collect_strata_bench_lines
  joined_bench="${STRATA_BENCH_LINES[*]}"
  assert_contains "$joined_bench" "Qwen3-32B (Q4_K_M)" "collect_strata_bench_lines formats model"
  assert_contains "$joined_bench" "85.4 tok/s" "collect_strata_bench_lines formats decode"
  assert_contains "$joined_bench" "Sys 120.5W" "collect_strata_bench_lines includes coupled power"

  hist_rows="$(cd "$TMP_DIR" && _strata_bench_py history "${TMP_DIR}/bench/results")"
  assert_contains "$hist_rows" "sysctl_tuning,zram_swap" "history mode preserves coupled active_steps"
)

# 12. RAM (> 31 GiB) and VRAM (> 5 GiB) hardware warnings
(
  IS_MACOS=false IS_JETSON=false IS_ASAHI_LINUX=false HAS_NVIDIA=true HAS_NVIDIA_UNIFIED_MEM=false
  HAS_AMD=false HAS_INTEL_ARC=false HAS_NVIDIA_DATACENTER=false HAS_NVIDIA_PASCAL=false HAS_NVIDIA_VOLTA_SM70=false
  AMD_MISSING_GFX_ARCHS=() NVIDIA_GPU_INDICES=(0)

  # 31.4 GiB RAM (32153 MiB > 31744 MiB) + 5900 MiB VRAM (> 5120 MiB) -> no warnings
  RAM_GB=31 RAM_MB=32153 NVIDIA_VRAM_MB=5900
  w_ok="$(format_strata_hw_warnings)"
  assert_eq "$w_ok" "" "no RAM/VRAM warning for > 31 GiB RAM and > 5 GiB VRAM"

  # 31.0 GiB RAM (31744 MiB <= 31744 MiB) + 5120 MiB VRAM (<= 5120 MiB) -> both warn
  RAM_GB=31 RAM_MB=31744 NVIDIA_VRAM_MB=5120
  w_low="$(format_strata_hw_warnings)"
  assert_contains "$w_low" "System RAM is 31 GiB (<= 31 GiB)" "warns when RAM <= 31 GiB"
  assert_contains "$w_low" "NVIDIA GPU VRAM is 5 GiB (<= 5 GiB)" "warns when VRAM <= 5 GiB"
)

PASS="$(grep -c '^P$' "$RESULTS_FILE" || true)"
FAIL="$(grep -c '^F$' "$RESULTS_FILE" || true)"
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
