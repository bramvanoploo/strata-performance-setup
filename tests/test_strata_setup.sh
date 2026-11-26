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
    fail "$msg (got='${got}', want='${want}')"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    pass "$msg"
  else
    fail "$msg (missing '${needle}')"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if ! grep -qF -- "$needle" <<<"$haystack"; then
    pass "$msg"
  else
    fail "$msg (unexpected '${needle}')"
  fi
}

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
  chk_ollama="$(STRATA_PLUGIN_BASE_URL="file://${REPO_ROOT}" STRATA_PLUGIN_CACHE_DIR="${TMP_DIR}/pcache" "${standalone_dir}/strata-performance-setup.sh" --plugin ollama --check)"
  assert_contains "$chk_ollama" "Ollama:" "standalone script fetches & loads ollama plugin with _common.sh"
  [[ -f "${TMP_DIR}/pcache/hosts/_common.sh" ]] && pass "standalone script caches hosts/_common.sh" || fail "standalone script caches hosts/_common.sh"
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
  assert_contains "$row1" "[SERVERS]" "core render_any_index_row renders SERVERS link below STATS"
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
  printf 'STRATA_METAL_TEST=$(touch\t%s)\n' "$pwn_marker" >> "$MACOS_METAL_ENV_FILE"
  printf 'STRATA_METAL_TEST=$(touch/%s)\n' "$pwn_marker" >> "$MACOS_METAL_ENV_FILE"
  # Even with $(...) without spaces:
  printf 'STRATA_METAL_TEST=$(touch${IFS}%s)\n' "$pwn_marker" >> "$MACOS_METAL_ENV_FILE"
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

# 13. Host plugin platform filtering (Linux vs Intel macOS vs Apple Silicon macOS)
(
  # Linux: ollama, llamacpp, localai, vllm, sglang shown; mlx-lm hidden
  IS_MACOS=false IS_APPLE_SILICON=false HAS_NVIDIA=false HAS_AMD=false HAS_INTEL_GPU=false
  AVAILABLE_HOST_PLUGINS=("strata")
  discover_host_plugins
  linux_hosts="${AVAILABLE_HOST_PLUGINS[*]}"
  assert_contains "$linux_hosts" "ollama" "Linux shows ollama host plugin"
  assert_contains "$linux_hosts" "llamacpp" "Linux shows llamacpp host plugin"
  assert_contains "$linux_hosts" "ik-llamacpp" "Linux shows ik-llamacpp host plugin"
  assert_contains "$linux_hosts" "localai" "Linux shows localai host plugin"
  assert_contains "$linux_hosts" "vllm" "Linux shows vllm host plugin"
  assert_contains "$linux_hosts" "sglang" "Linux shows sglang host plugin"
  assert_contains "$linux_hosts" "lemonade" "Linux shows lemonade host plugin"
  assert_contains "$linux_hosts" "openvino" "Linux shows openvino host plugin"
  assert_contains "$linux_hosts" "exo" "Linux shows exo host plugin"
  assert_not_contains "$linux_hosts" "mlx-lm" "Linux hides mlx-lm host plugin"
  assert_not_contains "$linux_hosts" "tensorrt-llm" "Linux without NVIDIA hides tensorrt-llm host plugin"

  HAS_NVIDIA=true
  AVAILABLE_HOST_PLUGINS=("strata")
  discover_host_plugins
  assert_contains "${AVAILABLE_HOST_PLUGINS[*]}" "tensorrt-llm" "Linux with NVIDIA shows tensorrt-llm host plugin"
  assert_contains "${AVAILABLE_HOST_PLUGINS[*]}" "tabbyapi" "Linux with NVIDIA shows tabbyapi host plugin"
  HAS_NVIDIA=false

  # Intel macOS: ollama, llamacpp, localai shown; vllm, sglang, mlx-lm hidden
  IS_MACOS=true IS_APPLE_SILICON=false
  AVAILABLE_HOST_PLUGINS=("strata")
  discover_host_plugins
  intel_mac_hosts="${AVAILABLE_HOST_PLUGINS[*]}"
  assert_contains "$intel_mac_hosts" "ollama" "Intel macOS shows ollama host plugin"
  assert_not_contains "$intel_mac_hosts" "vllm" "Intel macOS hides vllm host plugin"
  assert_not_contains "$intel_mac_hosts" "sglang" "Intel macOS hides sglang host plugin"
  assert_not_contains "$intel_mac_hosts" "mlx-lm" "Intel macOS hides mlx-lm host plugin"

  # Apple Silicon macOS: ollama, llamacpp, localai, mlx-lm shown; vllm, sglang hidden
  IS_MACOS=true IS_APPLE_SILICON=true
  AVAILABLE_HOST_PLUGINS=("strata")
  discover_host_plugins
  arm_mac_hosts="${AVAILABLE_HOST_PLUGINS[*]}"
  assert_contains "$arm_mac_hosts" "mlx-lm" "Apple Silicon macOS shows mlx-lm host plugin"
  assert_not_contains "$arm_mac_hosts" "vllm" "Apple Silicon macOS hides vllm host plugin"
  assert_not_contains "$arm_mac_hosts" "sglang" "Apple Silicon macOS hides sglang host plugin"
)

# 14. Shared host plugin helpers (_common.sh) and --download-plugins
(
  _host_http_get() { echo '{"data":[{"id":"qwen3-8b"},{"id":"llama-3"}]}'; }
  models_csv="$(_host_openai_models "http://127.0.0.1:8080")"
  assert_eq "$models_csv" "qwen3-8b,llama-3" "_host_openai_models parses OpenAI /v1/models JSON"

  quoted_arg="$(_host_shell_quote $'/tmp/my "model"\n$HOME')"
  assert_eq "$quoted_arg" "'/tmp/my \"model\"\$HOME'" "_host_shell_quote strips newlines and single-quotes safely"

  HAS_SYSTEMD=true CHECK_ONLY=false
  unit_capture="${TMP_DIR}/captured.service"
  run_root() {
    if [[ "$1" == "tee" ]]; then
      cat > "$unit_capture"
    fi
  }
  refresh_unit_files_cache() { :; }
  _host_install_systemd_unit "test-llm.service" "Test LLM" "/usr/bin/llm --model '/tmp/a b'"
  unit_body="$(cat "$unit_capture")"
  assert_contains "$unit_body" "ExecStart=/usr/bin/llm --model '/tmp/a b'" "_host_install_systemd_unit writes ExecStart"

  AVAILABLE_HOST_PLUGINS=("ollama")
  OLLAMA_BIN="" OLLAMA_DOCKER=""
  srv_uninst="$(format_server_row 0 false)"
  assert_contains "$srv_uninst" "[NOT INSTALLED]" "format_server_row shows NOT INSTALLED when absent"
  OLLAMA_BIN="/usr/bin/ollama"
  service_installed() { return 0; }
  unit_active() { return 0; }
  srv_inst="$(format_server_row 0 true)"
  assert_contains "$srv_inst" "[INSTALLED]" "format_server_row shows INSTALLED when present"
  assert_contains "$srv_inst" "active (service)" "format_server_row shows active service status"
  assert_contains "$srv_inst" "✓" "format_server_row shows checkmarks for supported capabilities"
  HOST_PLUGIN_CAPS[ollama]="install,stats"
  srv_partial="$(format_server_row 0 false)"
  assert_contains "$srv_partial" "-" "format_server_row shows - for unsupported capabilities"

  opts_uninst="$(_host_build_options_list false)"
  assert_eq "$opts_uninst" "install" "uninstalled server only shows install option"
  opts_inst_idle="$(_host_build_options_list true false "" false)"
  assert_eq "$opts_inst_idle" "update service latest uninstall" "installed server hides bench when not serving models"
  opts_inst="$(_host_build_options_list true false "" true)"
  assert_eq "$opts_inst" "update service bench latest uninstall" "installed server shows update/service/bench/latest/uninstall when serving a model"
  opts_docker_idle="$(_host_build_options_list false true "" false)"
  assert_eq "$opts_docker_idle" "latest" "Docker-only server hides bench when not serving models"
  opts_docker="$(_host_build_options_list false true "" true)"
  assert_eq "$opts_docker" "bench latest" "Docker-only server shows bench and latest when serving a model"
  opt_row="$(_host_option_row 0 "install" "Ollama" "ollama.service" "" false true)"
  assert_contains "$opt_row" "Install Ollama" "_host_option_row formats install option"
  uninst_row="$(_host_option_row 0 "uninstall" "llama.cpp" "llamacpp.service" "" false false)"
  assert_contains "$uninst_row" "Uninstall llama.cpp" "_host_option_row formats uninstall option"
  _host_http_get() { echo '{"data":[]}'; }
  if _host_has_served_model "http://127.0.0.1:8080"; then
    fail "_host_has_served_model should return 1 for empty model list"
  else
    pass "_host_has_served_model returns 1 when no model is served"
  fi
  _host_http_get() { echo '{"data":[{"id":"qwen3-8b"}]}'; }
  _host_has_served_model "http://127.0.0.1:8080" && pass "_host_has_served_model returns 0 when model is served" || fail "_host_has_served_model"

  fake_bin="${TMP_DIR}/fake-llama-server"
  touch "$fake_bin"
  service_installed() { return 1; }
  _host_standard_uninstall "llamacpp" "llama.cpp" "llamacpp.service" "$fake_bin" "manual" "llama.cpp" <<< "y" >/dev/null
  [[ ! -e "$fake_bin" ]] && pass "_host_standard_uninstall removes manual binary after confirmation" || fail "_host_standard_uninstall"

  # _host_endpoint_running ignores another server (e.g. Strata) sharing port 8080
  _host_http_get() { echo '{"status":"ok"}'; }
  unit_active() { return 1; }
  _host_proc_running() { return 1; }
  LLAMACPP_DOCKER=""
  if _llamacpp_running; then
    fail "_llamacpp_running should not match another server on port 8080 without llama-server process"
  else
    pass "_llamacpp_running ignores port 8080 collision when llama-server is not running"
  fi
  _host_proc_running() { return 0; }
  _llamacpp_running && pass "_llamacpp_running returns 0 when llama-server process and endpoint are active" || fail "_llamacpp_running"

  # Custom port detection (_host_extract_port_from_text & _host_detect_url)
  assert_eq "$(_host_extract_port_from_text "/usr/bin/llama-server -m foo.gguf --port 9090")" "9090" "_host_extract_port_from_text parses --port"
  assert_eq "$(_host_extract_port_from_text "Environment=OLLAMA_HOST=0.0.0.0:11435")" "11435" "_host_extract_port_from_text parses OLLAMA_HOST"
  assert_eq "$(_host_detect_url "http://127.0.0.1:8080" "__unlikely_proc_pattern_12345__" "" "")" "http://127.0.0.1:8080" "_host_detect_url falls back to default URL when not running"

  STRATA_UPDATE_CACHE_DIR="${TMP_DIR}/ucache"
  mkdir -p "$STRATA_UPDATE_CACHE_DIR"
  printf "%s|v0.9.0\n" "$(date +%s)" > "${STRATA_UPDATE_CACHE_DIR}/ollama.cache"
  _host_github_latest_tag() { echo "should_not_fetch"; }
  _host_check_update_cached "ollama" "0.8.0" "ollama/ollama" 7200
  assert_eq "${HOST_UPDATE_AVAIL[ollama]}" "true" "_host_check_update_cached detects available update from TTL cache"
  _host_check_update_cached "ollama" "0.9.0" "ollama/ollama" 7200
  assert_eq "${HOST_UPDATE_AVAIL[ollama]}" "false" "_host_check_update_cached clears update flag when up to date"
  _host_check_update_cached "ollama" "0.10.0" "ollama/ollama" 7200
  assert_eq "${HOST_UPDATE_AVAIL[ollama]}" "false" "_host_check_update_cached does not flag newer local version as outdated"

  AVAILABLE_HOST_PLUGINS=("strata" "ollama")
  STRATA_UPDATE_AVAILABLE=true
  HOST_UPDATE_AVAIL[ollama]=true
  srv_tgl="$(format_servers_toggle_row false)"
  assert_contains "$srv_tgl" "2 updates: Strata, Ollama" "format_servers_toggle_row names outdated servers"
  STRATA_UPDATE_AVAILABLE=false
  HOST_UPDATE_AVAIL[strata]="false"
  HOST_UPDATE_AVAIL[ollama]="false"
  HOST_UPDATE_AVAIL[llamacpp]="true"
  HOST_UPDATE_LATEST[llamacpp]="v1.0.0"
  AVAILABLE_HOST_PLUGINS=("strata" "llamacpp")
  banner_llama="$(format_server_update_banner 100)"
  assert_contains "$banner_llama" "llama.cpp update ready (v1.0.0)" "format_server_update_banner names llama.cpp when only llama.cpp has update"
  assert_not_contains "$banner_llama" "Strata" "format_server_update_banner does not blame Strata when Strata is up to date"
  AVAILABLE_HOST_PLUGINS=("strata" "ollama")
  STRATA_UPDATE_AVAILABLE=true
  HOST_UPDATE_AVAIL[ollama]=true
  OLLAMA_BIN="/usr/bin/ollama"
  srv_upd="$(format_server_row 1 false)"
  assert_contains "$srv_upd" "[UPDATE AVAIL]" "format_server_row shows UPDATE AVAIL badge"
  assert_contains "$srv_upd" "↑" "format_server_row shows ↑ in Upd column"

  HOST_UPDATE_AVAIL[llamacpp]="false"
  printf "llamacpp|true|b5000\nollama|true|v0.9.0\n" > "${STRATA_UPDATE_CACHE_DIR}/summary.state"
  load_server_update_states
  assert_eq "${HOST_UPDATE_AVAIL[llamacpp]}" "true" "load_server_update_states loads background update summary"
  _host_clear_update_cache "llamacpp"
  assert_not_contains "$(cat "${STRATA_UPDATE_CACHE_DIR}/summary.state")" "llamacpp|" "_host_clear_update_cache removes server entry from summary.state"
  assert_contains "$(cat "${STRATA_UPDATE_CACHE_DIR}/summary.state")" "ollama|true|v0.9.0" "_host_clear_update_cache preserves other entries in summary.state"

  # Startup direct update check & banner visibility across all header modes
  (
    STRATA_UPDATE_CACHE_DIR="${TMP_DIR}/startup_ucache"
    mkdir -p "$STRATA_UPDATE_CACHE_DIR" "${TMP_DIR}/fake_strata_bin"
    # Pre-seed stale summary.state claiming no update so startup check must refresh it directly
    printf "strata|false|\nollama|false|\n" > "${STRATA_UPDATE_CACHE_DIR}/summary.state"
    printf "%s|v0.1.0\n" "$(date +%s)" > "${STRATA_UPDATE_CACHE_DIR}/ollama.cache"
    cat > "${TMP_DIR}/fake_strata_bin/strata" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "strata 0.4.0"
elif [[ "${1:-}" == "update" && "${2:-}" == "--check" ]]; then
  echo '[info] checking update feed'
  echo '{"engine":{"installed":{"version":"0.4.0"},"offered":{"version":"0.5.0"},"status":"update-available"},"control":{"installed":"0.4.0","offered":"0.4.0","status":"current"}}'
fi
EOF
    chmod +x "${TMP_DIR}/fake_strata_bin/strata"
    PATH="${TMP_DIR}/fake_strata_bin:${PATH}"
    unset "HOST_PLUGIN_LOADED[strata]"
    LOADED_HOST_PLUGINS=()
    AVAILABLE_HOST_PLUGINS=("strata")
    HOST_UPDATE_AVAIL=()
    HOST_UPDATE_LATEST=()
    STRATA_UPDATE_AVAILABLE=false
    STRATA_UPDATE_SUMMARY=""
    NO_PLUGINS=false
    CHECK_ONLY=false
    discover_host_plugins() { AVAILABLE_HOST_PLUGINS=("strata"); }
    check_server_updates_now
    assert_eq "$STRATA_UPDATE_AVAILABLE" "true" "check_server_updates_now sets STRATA_UPDATE_AVAILABLE directly on startup"
    assert_eq "$STRATA_UPDATE_SUMMARY" "engine 0.4.0 -> 0.5.0" "check_server_updates_now parses Strata update summary with leading log output"
    # Simulate fresh render on every header mode before any timeout tick
    HOST_UPDATE_AVAIL=()
    STRATA_UPDATE_AVAILABLE=false
    STRATA_UPDATE_SUMMARY=""
    for _hmode in "toggle" "stats" "none"; do
      HOST_UPDATE_AVAIL=()
      STRATA_UPDATE_AVAILABLE=false
      hdr_out="$(print_header "$_hmode")"
      assert_contains "$hdr_out" "[UPDATE AVAILABLE] Strata update ready (engine 0.4.0 -> 0.5.0)" "print_header (${_hmode}) renders Strata update banner immediately"
    done
    hdr_skip="$(print_header none true)"
    assert_contains "$hdr_skip" "[UPDATE AVAILABLE] Strata update ready (engine 0.4.0 -> 0.5.0)" "print_header (skip_rule) renders Strata update banner on history page"
    _host_clear_update_cache "strata"
    assert_eq "$STRATA_UPDATE_AVAILABLE" "false" "_host_clear_update_cache resets STRATA_UPDATE_AVAILABLE"
    hdr_cleared="$(print_header none)"
    assert_not_contains "$hdr_cleared" "[UPDATE AVAILABLE]" "print_header hides banner once Strata update cache is cleared"
  )

  DISTRO_FAMILY="arch" IS_MACOS=false AUR_HELPER="" LLAMACPP_BIN="/usr/local/bin/llama-server"
  pacman() { return 1; }
  PKG_INST_CACHE=()
  src_manual="$(_host_detect_install_source "llamacpp" "/usr/local/bin/llama-server" "llama.cpp" false)"
  assert_eq "$src_manual" "manual" "_host_detect_install_source detects manual build when unowned by package manager"
  src_venv="$(_host_detect_install_source "vllm" "$(_host_venv_dir "vllm")/bin/vllm" "vllm" false)"
  assert_eq "$src_venv" "venv" "_host_detect_install_source detects managed venv install"
  HOST_UPDATE_AVAIL[llamacpp]="true"
  _host_check_update_by_source "llamacpp" "manual" "0.6.0-dev" "llama.cpp" "ggml-org/llama.cpp"
  assert_eq "${HOST_UPDATE_AVAIL[llamacpp]}" "false" "_host_check_update_by_source does not flag manual builds from GitHub"
  opts_manual="$(_host_build_options_list true false "manual" true)"
  assert_eq "$opts_manual" "service bench latest uninstall" "manual build hides update option and keeps uninstall"
  HOST_INSTALL_SOURCE[llamacpp]="manual"
  HOST_UPDATE_AVAIL[llamacpp]="false"
  AVAILABLE_HOST_PLUGINS=("llamacpp")
  srv_manual_row="$(format_server_row 0 false | sed -E $'s/\033\\[[0-9;]*m//g')"
  assert_contains "$srv_manual_row" "| -       | ✓" "manual install hides Updates checkmark in Servers table"
  LLAMACPP_SOURCE="$src_manual"
  rc_ll=0; _llamacpp_install_or_update >/dev/null 2>&1 || rc_ll=$?
  assert_eq "$rc_ll" "1" "_llamacpp_install_or_update returns 1 cleanly without unbound variable when no package exists"
)

if command -v curl >/dev/null 2>&1; then
  dl_cache="${TMP_DIR}/dl_cache"
  mkdir -p "$dl_cache"
  standalone_dl="${TMP_DIR}/standalone/strata-performance-setup.sh"
  if [[ -x "$standalone_dl" ]]; then
    dl_out="$(STRATA_PLUGIN_BASE_URL="file://${REPO_ROOT}" STRATA_PLUGIN_CACHE_DIR="$dl_cache" "$standalone_dl" --download-plugins)"
    assert_contains "$dl_out" "All plugins cached" "--download-plugins succeeds in standalone mode"
    [[ -f "${dl_cache}/hosts/_common.sh" ]] && pass "--download-plugins caches hosts/_common.sh" || fail "--download-plugins caches hosts/_common.sh"
    [[ -f "${dl_cache}/hosts/mlx-lm.sh" ]] && pass "--download-plugins caches hosts/mlx-lm.sh" || fail "--download-plugins caches hosts/mlx-lm.sh"
  fi
fi

# 15. Raspberry Pi cmdline.txt, rpm-ostree, NixOS, WSL2, and NPU/accelerator detection
(
  # 15a. Raspberry Pi cmdline.txt
  BR="${TMP_DIR}/boot_rpi"
  mkdir -p "${BR}/boot/firmware" "${BR}/proc"
  : > "${BR}/proc/cmdline"
  printf 'console=serial0,115200 root=/dev/mmcblk0p2 rw\n' > "${BR}/boot/firmware/cmdline.txt"
  STRATA_BOOT_ROOT="$BR" DISTRO_FAMILY="debian" IS_OSTREE=false IS_NIXOS=false
  add_kernel_param "init_on_alloc=0"
  has_kernel_param "init_on_alloc=0" && pass "Raspberry Pi cmdline.txt updated & detected" || fail "Raspberry Pi cmdline.txt"
  remove_kernel_param "init_on_alloc=0"
  assert_not_contains "$(cat "${BR}/boot/firmware/cmdline.txt")" "init_on_alloc=0" "remove_kernel_param cleans Raspberry Pi cmdline.txt"

  # 15b. rpm-ostree kargs
  mkdir -p "${TMP_DIR}/ostree_bin"
  OSTREE_KARGS_FILE="${TMP_DIR}/ostree_kargs.txt"
  printf 'rhgb quiet mitigations=off\n' > "$OSTREE_KARGS_FILE"
  cat > "${TMP_DIR}/ostree_bin/rpm-ostree" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${TMP_DIR}/ostree_calls"
if [[ "\$1" == "kargs" && \$# -eq 1 ]]; then
  cat "${OSTREE_KARGS_FILE}"
elif [[ "\$1" == "kargs" && "\$2" == --delete-if-present=* ]]; then
  tok="\${2#--delete-if-present=}"
  sed -i "s/ \${tok}//g; s/\${tok} //g" "${OSTREE_KARGS_FILE}"
fi
EOF
  chmod +x "${TMP_DIR}/ostree_bin/rpm-ostree"
  PATH="${TMP_DIR}/ostree_bin:${PATH}" IS_OSTREE=true IS_NIXOS=false DISTRO_FAMILY="fedora"
  STRATA_BOOT_ROOT="${TMP_DIR}/boot_ostree"
  mkdir -p "${STRATA_BOOT_ROOT}/proc"
  printf 'rhgb quiet mitigations=off\n' > "${STRATA_BOOT_ROOT}/proc/cmdline"
  add_kernel_param "iommu=pt"
  assert_contains "$(cat "${TMP_DIR}/ostree_calls")" "--append-if-missing=iommu=pt" "IS_OSTREE uses rpm-ostree kargs --append-if-missing"
  has_kernel_param "mitigations=off" && pass "has_kernel_param reads rpm-ostree kargs" || fail "has_kernel_param rpm-ostree"
  REBOOT_REQUIRED=false
  remove_kernel_param "not_present=1"
  assert_eq "$REBOOT_REQUIRED" "false" "IS_OSTREE remove_kernel_param is no-op when param absent"
  remove_kernel_param "mitigations=off"
  assert_contains "$(cat "${TMP_DIR}/ostree_calls")" "--delete-if-present=mitigations=off" "IS_OSTREE uses rpm-ostree kargs --delete-if-present"
  if has_kernel_param "mitigations=off"; then
    fail "has_kernel_param should return 1 after rpm-ostree deletion before reboot"
  else
    pass "has_kernel_param clears immediately after rpm-ostree removal"
  fi

  # 15c. NixOS guard
  IS_OSTREE=false IS_NIXOS=true DISTRO_FAMILY="nixos"
  rc_nix=0; add_kernel_param "iommu=pt" >/dev/null 2>&1 || rc_nix=$?
  assert_eq "$rc_nix" "1" "NixOS refuses imperative add_kernel_param cleanly"

  # 15d. WSL2 active step gating
  IS_MACOS=false IS_WSL2=true IS_VIRT="wsl" IS_NIXOS=false IS_OSTREE=false
  STRATA_WSLCONFIG_PATH="${TMP_DIR}/wslconfig"
  touch "$STRATA_WSLCONFIG_PATH"
  build_active_steps
  wsl_steps="${ACTIVE_STEPS[*]}"
  assert_contains "$wsl_steps" "wsl2_windows_config" "WSL2 enables wsl2_windows_config"
  assert_contains "$wsl_steps" "wsl2_linux_tuning" "WSL2 enables wsl2_linux_tuning"
  assert_contains "$wsl_steps" "memlock_realtime" "WSL2 enables memlock_realtime"
  assert_not_contains "$wsl_steps" "cpu_performance" "WSL2 hides bare-metal cpu_performance"
  assert_not_contains "$wsl_steps" "kernel_mitigations_off" "WSL2 hides kernel_mitigations_off"

  # 15e. Accelerator & NPU applicability flags
  HAS_TENSTORRENT=true; applicable_tenstorrent_setup && pass "tenstorrent_setup applicable when HAS_TENSTORRENT=true" || fail "tenstorrent_setup"
  HAS_AMD_NPU=true; applicable_amd_xdna_npu && pass "amd_xdna_npu applicable when HAS_AMD_NPU=true" || fail "amd_xdna_npu"
  HAS_INTEL_NPU=true; applicable_intel_npu_stack && pass "intel_npu_stack applicable when HAS_INTEL_NPU=true" || fail "intel_npu_stack"
  HAS_ROCKCHIP_NPU=true; applicable_rockchip_rk3588_npu && pass "rockchip_rk3588_npu applicable when HAS_ROCKCHIP_NPU=true" || fail "rockchip_rk3588_npu"
  HAS_HAILO=true; applicable_hailo_npu_setup && pass "hailo_npu_setup applicable when HAS_HAILO=true" || fail "hailo_npu_setup"
  HAS_ASCEND=true; applicable_huawei_ascend_cann && pass "huawei_ascend_cann applicable when HAS_ASCEND=true" || fail "huawei_ascend_cann"
  HAS_MTHREADS=true; applicable_moore_threads_musa && pass "moore_threads_musa applicable when HAS_MTHREADS=true" || fail "moore_threads_musa"

  # 15f. Regression checks for review findings
  if is_recommended_step amd_compute_profile; then
    fail "amd_compute_profile should be opt_in, not recommended"
  else
    pass "amd_compute_profile is opt_in (avoids race with amd_gpu_perf)"
  fi
  assert_eq "${HOST_PLUGIN_CAPS[ik-llamacpp]}" "install,service,bench,stats" "ik-llamacpp caps omit unimplemented updates"

  STRATA_WSLCONFIG_PATH="${TMP_DIR}/reapply_wslconfig"
  printf '# keep me\n[wsl2]\nkernel=C:\\custom\\bzImage\n' > "$STRATA_WSLCONFIG_PATH"
  apply_wsl2_windows_config <<< "24" >/dev/null
  apply_wsl2_windows_config <<< "32" >/dev/null
  assert_contains "$(cat "$STRATA_WSLCONFIG_PATH")" "kernel=C:\\custom\\bzImage" "wsl2_windows_config preserves custom keys"
  assert_contains "$(cat "$STRATA_WSLCONFIG_PATH")" "# keep me" "wsl2_windows_config preserves user comments"
  assert_contains "$(cat "$STRATA_WSLCONFIG_PATH")" "memory=32GB" "wsl2_windows_config updates memory on reapply"
  revert_wsl2_windows_config >/dev/null
  assert_not_contains "$(cat "$STRATA_WSLCONFIG_PATH")" "memory=32GB" "revert_wsl2_windows_config restores original .wslconfig even after reapply"

  printf '[wsl2]\n[wsl2]\n' > "${TMP_DIR}/bad_wslconfig"
  STRATA_WSLCONFIG_PATH="${TMP_DIR}/bad_wslconfig"
  rc_wslbad=0; apply_wsl2_windows_config <<< "24" >/dev/null 2>&1 || rc_wslbad=$?
  assert_eq "$rc_wslbad" "1" "apply_wsl2_windows_config fails loudly on unparsable .wslconfig"
  assert_eq "$(cat "${TMP_DIR}/bad_wslconfig")" "$(printf '[wsl2]\n[wsl2]\n')" "unparsable .wslconfig left unchanged"

  printf '# user hand-written\nmemory=10GB\n' > "${TMP_DIR}/foreign_wslconfig"
  STRATA_WSLCONFIG_PATH="${TMP_DIR}/foreign_wslconfig"
  revert_wsl2_windows_config >/dev/null
  assert_contains "$(cat "${TMP_DIR}/foreign_wslconfig")" "memory=10GB" "revert_wsl2_windows_config leaves unmanaged .wslconfig alone"
  printf '# strata-wsl2-managed\n[wsl2]\nmemory=24GB\n' > "${TMP_DIR}/ours_wslconfig"
  STRATA_WSLCONFIG_PATH="${TMP_DIR}/ours_wslconfig"
  revert_wsl2_windows_config >/dev/null
  if [[ -e "${TMP_DIR}/ours_wslconfig" ]]; then
    fail "revert_wsl2_windows_config should delete marker-tagged file with no backup"
  else
    pass "revert_wsl2_windows_config deletes marker-tagged file with no backup"
  fi

  MACOS_TM_LIST="${TMP_DIR}/tm_missing.list"
  printf '%s/does-not-exist\n' "$TMP_DIR" > "$MACOS_TM_LIST"
  if status_macos_timemachine_exclude; then
    fail "status_macos_timemachine_exclude should fail when no listed dirs exist"
  else
    pass "status_macos_timemachine_exclude rejects empty/missing dir list"
  fi

  # 16. Inference server warnings appear on Inference Servers page, not Index page
  (
    LOADED_HOST_PLUGINS=("testhost")
    AVAILABLE_HOST_PLUGINS=("testhost")
    HOST_PLUGIN_LOADED=([testhost]=1)
    HOST_PLUGIN_NAMES=([testhost]="TestHost")
    HOST_PLUGIN_CAPS=([testhost]="install")
    testhost_hw_warnings() { echo "  [TestHost] Simulated inference server warning"; }
    testhost_table_status() { echo "NOT INSTALLED|—"; }
    print_header() { :; }
    discover_host_plugins() { :; }
    IS_NIXOS=false

    read_choice_with_live_stats() { printf -v "$1" '%s' "q"; }
    idx_out="$(show_index)"
    assert_not_contains "$idx_out" "Simulated inference server warning" "show_index omits inference server hw_warnings"

    srv_out="$(show_inference_servers_page <<< "q")"
    assert_contains "$srv_out" "Simulated inference server warning" "show_inference_servers_page displays inference server hw_warnings"

    HOST_PLUGIN_URLS=([testhost]="https://example.com/testhost")
    link_row="$(format_server_row 0 false)"
    assert_contains "$link_row" $'\033]8;;https://example.com/testhost\033\\TestHost\033]8;;\033\\' "format_server_row wraps server name in OSC 8 hyperlink"
  )

  # 17. PolyStrata, Basalt, and Adamant host plugins
  (
    IS_MACOS=false HAS_NVIDIA=true HAS_AMD=false HAS_INTEL_GPU=false
    AVAILABLE_HOST_PLUGINS=()
    discover_host_plugins
    assert_contains "${AVAILABLE_HOST_PLUGINS[*]}" "polystrata" "Linux with NVIDIA shows polystrata host plugin"
    assert_contains "${AVAILABLE_HOST_PLUGINS[*]}" "basalt" "Linux with NVIDIA shows basalt host plugin"
    assert_contains "${AVAILABLE_HOST_PLUGINS[*]}" "adamant" "Linux with NVIDIA shows adamant host plugin"
  )
)

# 18. sysctl previous-value capture round-trip (write_sysctl_with_prev / restore_sysctl_prev)
(
  log="${TMP_DIR}/sysctl_calls"
  : > "$log"
  sysctl() {
    case "$1" in
      -n) echo 60 ;;
      -w) echo "$2" >> "$log" ;;
      --system) : ;;
    esac
    return 0
  }
  conf="${TMP_DIR}/sysctl.d/99-strata-test.conf"
  mkdir -p "${TMP_DIR}/sysctl.d"
  write_sysctl_with_prev "$conf" "vm.foo=50"
  assert_contains "$(cat "$conf")" "# prev vm.foo=60" "write_sysctl_with_prev captures previous value"
  assert_contains "$(cat "$conf")" "vm.foo = 50" "write_sysctl_with_prev writes new value"
  restore_sysctl_prev "$conf"
  assert_contains "$(cat "$log")" "vm.foo=60" "restore_sysctl_prev replays previous value"
  [[ ! -f "$conf" ]] && pass "restore_sysctl_prev removes conf file" || fail "restore_sysctl_prev removes conf file"
)

# 18b. sysctl_tuning & numa_balancing apply/status/revert round-trip (override dirs)
(
  STRATA_SYSCTL_DIR="${TMP_DIR}/sysctl_tune"
  STRATA_TMPFILES_DIR="${TMP_DIR}/tmpfiles_tune"
  mkdir -p "$STRATA_SYSCTL_DIR" "$STRATA_TMPFILES_DIR"
  thp_supported() { return 1; }
  sysctl() { case "$1" in -n) echo 65530 ;; *) : ;; esac; return 0; }
  status_zram_swap() { return 1; }
  unit_exists() { return 1; }
  DISTRO_FAMILY="arch"
  rc_st=0; apply_sysctl_tuning >/dev/null || rc_st=$?
  assert_eq "$rc_st" "0" "apply_sysctl_tuning succeeds against fake dirs"
  status_sysctl_tuning && pass "status_sysctl_tuning true after apply" || fail "status_sysctl_tuning after apply"
  revert_sysctl_tuning >/dev/null
  [[ ! -f "${STRATA_SYSCTL_DIR}/99-strata-perf.conf" && ! -f "${STRATA_SYSCTL_DIR}/99-strata-swappiness.conf" ]] &&
    pass "revert_sysctl_tuning removes conf files" || fail "revert_sysctl_tuning removes conf files"
  status_sysctl_tuning && fail "status_sysctl_tuning should be false after revert" || pass "status_sysctl_tuning false after revert"

  sysctl() { return 0; }
  apply_numa_balancing >/dev/null
  assert_contains "$(cat "${STRATA_SYSCTL_DIR}/99-strata-numa.conf")" "kernel.numa_balancing = 0" "apply_numa_balancing writes conf to override dir"
  numa_balancing_managed && pass "numa_balancing_managed hook detects conf (dispatch to pack hook)" || fail "numa_balancing_managed after apply"
  is_step_managed_by_wizard numa_balancing && pass "is_step_managed_by_wizard dispatches to numa_balancing_managed" || fail "managed dispatch numa"
  revert_numa_balancing >/dev/null
  [[ ! -f "${STRATA_SYSCTL_DIR}/99-strata-numa.conf" ]] && pass "revert_numa_balancing removes conf" || fail "revert_numa_balancing removes conf"
  numa_balancing_managed && fail "numa_balancing_managed should be false after revert" || pass "numa_balancing_managed false after revert"
)

# 19. nvidia_clock_lock apply/status/revert round-trip (fake nvidia-smi, rc-dir service)
(
  HAS_SYSTEMD=false HAS_LAUNCHD=false IS_UNRAID=false IS_SYNOLOGY=false
  STRATA_RC_DIR="${TMP_DIR}/nvclk_rc"
  mkdir -p "$STRATA_RC_DIR"
  nvbin="${TMP_DIR}/nvclk_bin"
  mkdir -p "$nvbin"
  printf '#!/usr/bin/env bash\necho "All done."\nexit 0\n' > "${nvbin}/nvidia-smi"
  chmod +x "${nvbin}/nvidia-smi"
  PATH="${nvbin}:${PATH}"
  unit_enabled() { return 0; }
  HAS_NVIDIA=true NVIDIA_MAX_GFX_CLK=1455
  NVIDIA_GPU_INDICES=(0) NVIDIA_GPU_MAX_GFX_CLK=(1455) NVIDIA_GPU_MAX_MEM_CLK=(1000)
  NVIDIA_GPU_COMPUTE_CAP=(8.6) NVIDIA_GPU_NAMES=("Fake GPU")
  rc_cl=0; apply_nvidia_clock_lock >/dev/null || rc_cl=$?
  assert_eq "$rc_cl" "0" "apply_nvidia_clock_lock succeeds with fake nvidia-smi"
  assert_contains "$(cat "${STRATA_RC_DIR}/rc.strata.nvidia-clock-lock")" "-lgc 1455,1455" "clock-lock service locks max core clocks"
  status_nvidia_clock_lock && pass "status_nvidia_clock_lock true after apply" || fail "status_nvidia_clock_lock after apply"
  revert_nvidia_clock_lock >/dev/null
  [[ ! -f "${STRATA_RC_DIR}/rc.strata.nvidia-clock-lock" ]] && pass "revert_nvidia_clock_lock removes service" || fail "revert_nvidia_clock_lock removes service"
)

# 20. Security & regression tests from audit
(
  # 20a. --plugin rejects path traversal
  rc_trav=0
  bash "$SCRIPT" --plugin ../../../../tmp/evil --check >/dev/null 2>&1 || rc_trav=$?
  assert_eq "$rc_trav" "2" "--plugin rejects path traversal with exit 2"

  # 20b. _fetch_verified_plugin rejects tampered checksum
  bad_dir="${TMP_DIR}/bad_sha"
  mkdir -p "${bad_dir}/plugins/hosts" "${bad_dir}/cache"
  printf 'echo evil\n' > "${bad_dir}/plugins/hosts/fake.sh"
  printf 'hosts\tfake\tFake\tFake\tplugins/hosts/fake.sh\t0000000000000000000000000000000000000000000000000000000000000000\tall\n' > "${bad_dir}/plugins/registry.tsv"
  SCRIPT_DIR="${TMP_DIR}/nonexistent_repo"
  PLUGIN_CACHE_DIR="${bad_dir}/cache"
  PLUGIN_BASE_URL="file://${bad_dir}"
  REGISTRY_FETCHED=false REGISTRY_FILE_PATH=""
  rc_sha=0
  _fetch_verified_plugin hosts fake >/dev/null 2>&1 || rc_sha=$?
  [[ "$rc_sha" -ne 0 ]] && pass "_fetch_verified_plugin rejects SHA-256 mismatch" || fail "_fetch_verified_plugin accepted bad SHA-256"

  # 20c. _host_standard_uninstall refuses to remove shared system python3
  source "${REPO_ROOT}/plugins/hosts/_common.sh"
  confirm_yn() { return 0; }
  _host_owning_pkg() { echo "python"; }
  _host_pkg_uninstall() { touch "${TMP_DIR}/python_removed"; return 0; }
  _host_standard_uninstall "sglang" "SGLang" "sglang.service" "/usr/bin/python3" "manual" "sglang" >/dev/null 2>&1
  [[ ! -e "${TMP_DIR}/python_removed" ]] && pass "_host_standard_uninstall protects shared python3" || fail "_host_standard_uninstall tried to uninstall python3"

  # 20d. Boot hook exact suffix match: removing # strata:strata keeps # strata:strata-cpu-perf
  bh_file="${TMP_DIR}/rc.local.test"
  add_boot_hook "$bh_file" "# strata:strata" "[ -x /etc/rc.d/rc.strata.strata ] && /etc/rc.d/rc.strata.strata start # strata:strata"
  add_boot_hook "$bh_file" "# strata:strata-cpu-perf" "[ -x /etc/rc.d/rc.strata.strata-cpu-perf ] && /etc/rc.d/rc.strata.strata-cpu-perf start # strata:strata-cpu-perf"
  remove_boot_hook "$bh_file" "# strata:strata"
  assert_not_contains "$(cat "$bh_file")" "rc.strata.strata " "remove_boot_hook removes exact tag"
  assert_contains "$(cat "$bh_file")" "rc.strata.strata-cpu-perf" "remove_boot_hook preserves longer prefix-sharing tags"

  # 20e. _remove_kparam_from_file preserves rEFInd entry spacing (first token + untouched lines)
  rf_file="${TMP_DIR}/refind_test.conf"
  printf '"Boot standard"  "pcie_aspm=off root=UUID=abc"\n"Boot recovery"  "root=UUID=abc single"\n' > "$rf_file"
  _remove_kparam_from_file "pcie_aspm=off" "$rf_file"
  assert_contains "$(cat "$rf_file")" '"Boot standard" "root=UUID=abc"' "rEFInd python removal preserves quote delimiter"
  assert_contains "$(cat "$rf_file")" '"Boot recovery"  "root=UUID=abc single"' "rEFInd removal leaves untouched lines intact"

  # 20f. macOS launchd: root LaunchDaemon uses safe PATH, User= service installs as user LaunchAgent
  HAS_SYSTEMD=false HAS_LAUNCHD=true IS_MACOS=true
  TARGET_HOME="${TMP_DIR}/mac_home" TARGET_USER="testuser"
  STRATA_LAUNCHD_SYS_DIR="${TMP_DIR}/mac_sys_plists"
  STRATA_LAUNCHD_SYS_BIN_DIR="${TMP_DIR}/mac_sys_bin"
  STRATA_LAUNCHD_USER_DIR="${TMP_DIR}/mac_usr_plists"
  STRATA_LAUNCHD_USER_BIN_DIR="${TMP_DIR}/mac_usr_bin"
  mkdir -p "$TARGET_HOME" "$STRATA_LAUNCHD_SYS_DIR" "$STRATA_LAUNCHD_SYS_BIN_DIR" "$STRATA_LAUNCHD_USER_DIR" "$STRATA_LAUNCHD_USER_BIN_DIR"
  run_as_user_exec() { "$@"; }
  launchctl() { return 0; }
  install_service strata-macos-wired-limit.service >/dev/null 2>&1 <<'EOF'
[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl -w iogpu.wired_limit_mb=8192
EOF
  assert_not_contains "$(cat "${STRATA_LAUNCHD_SYS_BIN_DIR}/strata-macos-wired-limit.sh")" "$TARGET_HOME" "macOS root LaunchDaemon omits TARGET_HOME from PATH"
  install_service ollama.service >/dev/null 2>&1 <<'EOF'
[Service]
Type=simple
User=testuser
ExecStart=/opt/homebrew/bin/ollama serve
EOF
  [[ -f "${STRATA_LAUNCHD_USER_DIR}/com.strata.ollama.plist" ]] && pass "macOS User= service installs as user LaunchAgent" || fail "macOS User= service installed as root LaunchDaemon"
)

PASS="$(grep -c '^P$' "$RESULTS_FILE" || true)"
FAIL="$(grep -c '^F$' "$RESULTS_FILE" || true)"
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
