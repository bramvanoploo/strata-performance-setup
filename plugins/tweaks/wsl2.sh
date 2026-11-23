#!/usr/bin/env bash
# PLUGIN_ID: wsl2
# PLUGIN_NAME: wsl2
# PLUGIN_DESC: Windows Subsystem for Linux 2 (.wslconfig, /etc/wsl.conf, native ext4) tweaks

register_tweak --id "wsl2_windows_config" --stars 5 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --wsl-supported true --experimental-non-arch false
register_tweak --id "wsl2_linux_tuning" --stars 4 --tier "recommended" --os "linux" --laptop-recommended true --vm-supported true --wsl-supported true --experimental-non-arch false

_wsl2_win_wslconfig_path() {
  if [[ -n "${STRATA_WSLCONFIG_PATH:-}" ]]; then
    echo "$STRATA_WSLCONFIG_PATH"
    return 0
  fi
  local win_home="" udir=""
  if command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    win_home="$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r' | head -n1 || true)"
    [[ -n "$win_home" ]] && win_home="$(wslpath -u "$win_home" 2>/dev/null || true)"
  fi
  if [[ -n "$win_home" && -d "$win_home" ]]; then
    echo "${win_home}/.wslconfig"
    return 0
  fi
  for udir in /mnt/c/Users/*; do
    [[ -d "$udir" ]] || continue
    case "$(basename "$udir")" in
      Public|Default|"Default User"|"All Users") continue ;;
    esac
    if [[ -f "${udir}/.wslconfig" ]]; then
      echo "${udir}/.wslconfig"
      return 0
    fi
  done
  for udir in /mnt/c/Users/*; do
    [[ -d "$udir" ]] || continue
    case "$(basename "$udir")" in
      Public|Default|"Default User"|"All Users") continue ;;
    esac
    echo "${udir}/.wslconfig"
    return 0
  done
  return 1
}

applicable_wsl2_windows_config() {
  [[ "$IS_WSL2" == true ]] || return 1
  _wsl2_win_wslconfig_path >/dev/null 2>&1
}
title_wsl2_windows_config() { echo "WSL2 Windows .wslconfig RAM Cap & Idle Timeout Tuning"; }
status_wsl2_windows_config() {
  local cfg
  cfg="$(_wsl2_win_wslconfig_path 2>/dev/null || true)"
  [[ -n "$cfg" && -f "$cfg" ]] && grep -qE '^memory=|# strata-wsl2-managed' "$cfg" 2>/dev/null
}
explain_wsl2_windows_config() {
  cat <<'EOF'
Impact:
  WSL2 defaults to capping Linux RAM at 50% of Windows host memory, causing
  premature OOM kills when loading large models. This writes a tuned
  %USERPROFILE%\.wslconfig raising the RAM ceiling (default: ~80% of host RAM),
  setting swap=16GB, vmIdleTimeout=-1 (prevents background shutdown), and
  networkingMode=mirrored. Run 'wsl --shutdown' on Windows to apply.
EOF
}
apply_wsl2_windows_config() {
  local cfg host_gb=0 rec_gb=0 target_gb=""
  cfg="$(_wsl2_win_wslconfig_path)" || { echo -e "${C_RED}Could not locate Windows .wslconfig path under /mnt/c/Users.${C_RESET}"; return 1; }
  if command -v powershell.exe >/dev/null 2>&1; then
    host_gb="$(powershell.exe -NoProfile -Command "[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)" 2>/dev/null | tr -d '\r[:space:]' || echo 0)"
  fi
  if [[ "$host_gb" =~ ^[0-9]+$ ]] && (( host_gb > 0 )); then
    rec_gb=$(( host_gb * 80 / 100 ))
    (( rec_gb < 8 && host_gb > 8 )) && rec_gb=$(( host_gb - 4 ))
  else
    rec_gb=$(( RAM_GB > 8 ? RAM_GB * 3 / 2 : 16 ))
  fi
  read -r -p "Target WSL2 memory limit in GB [default: ${rec_gb}]: " target_gb || true
  target_gb="${target_gb:-$rec_gb}"
  if ! [[ "$target_gb" =~ ^[0-9]+$ ]] || (( target_gb < 4 )); then
    echo -e "${C_RED}Memory limit must be an integer >= 4 GB.${C_RESET}"
    return 1
  fi
  if [[ -f "$cfg" && ! -f "${cfg}.bak.strata-setup" ]] && ! grep -qF "# strata-wsl2-managed" "$cfg" 2>/dev/null; then
    cp "$cfg" "${cfg}.bak.strata-setup" 2>/dev/null || true
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$cfg" "$target_gb" <<'PY'
import configparser, os, sys

path, mem_gb = sys.argv[1], sys.argv[2]
cp = configparser.ConfigParser()
cp.optionxform = str
if os.path.exists(path):
    cp.read(path)
if not cp.has_section("wsl2"):
    cp.add_section("wsl2")
cp.set("wsl2", "memory", f"{mem_gb}GB")
for k, v in (
    ("swap", "16GB"),
    ("vmIdleTimeout", "-1"),
    ("networkingMode", "mirrored"),
    ("nestedVirtualization", "true"),
):
    if not cp.has_option("wsl2", k):
        cp.set("wsl2", k, v)
with open(path, "w") as f:
    f.write("# strata-wsl2-managed\n")
    cp.write(f, space_around_delimiters=False)
PY
  else
    cat > "$cfg" <<EOF
# strata-wsl2-managed
[wsl2]
memory=${target_gb}GB
swap=16GB
vmIdleTimeout=-1
networkingMode=mirrored
nestedVirtualization=true
EOF
  fi
  echo -e "${C_GREEN}Updated ${cfg} (memory=${target_gb}GB).${C_RESET}"
  echo -e "${C_YELLOW}Run 'wsl --shutdown' in Windows PowerShell and reopen WSL2 for changes to take effect.${C_RESET}"
}
revert_wsl2_windows_config() {
  local cfg
  cfg="$(_wsl2_win_wslconfig_path 2>/dev/null || true)"
  [[ -n "$cfg" ]] || return 0
  if [[ -f "${cfg}.bak.strata-setup" ]]; then
    mv -f "${cfg}.bak.strata-setup" "$cfg"
  else
    rm -f "$cfg"
  fi
  echo -e "${C_GREEN}Restored Windows .wslconfig (run 'wsl --shutdown' to apply).${C_RESET}"
}

WSL2_CONF_MARKER="/etc/strata-wsl2-conf.enabled"

applicable_wsl2_linux_tuning() { [[ "$IS_WSL2" == true ]]; }
title_wsl2_linux_tuning() { echo "WSL2 /etc/wsl.conf (systemd, metadata) & Native ext4 Model Storage"; }
status_wsl2_linux_tuning() {
  [[ -f "$WSL2_CONF_MARKER" ]] && grep -qE '^systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf 2>/dev/null
}
explain_wsl2_linux_tuning() {
  cat <<'EOF'
Impact:
  Enables systemd and Linux file-permission metadata in /etc/wsl.conf, and
  creates ~/models on native WSL2 ext4 instead of /mnt/c (the 9P bridge to
  Windows NTFS is 10-50x slower for GGUF/safetensors mmap and model loading).
EOF
  if [[ "$HAS_NVIDIA" == true ]]; then
    echo -e "\n${C_DIM}Note: Under WSL2, GPU power/clock limits are managed by the Windows host driver.${C_RESET}"
  fi
}
apply_wsl2_linux_tuning() {
  if [[ ! -f "$WSL2_CONF_MARKER" && -f /etc/wsl.conf && ! -f /etc/wsl.conf.strata.bak ]]; then
    run_root cp /etc/wsl.conf /etc/wsl.conf.strata.bak 2>/dev/null || true
  fi
  if command -v python3 >/dev/null 2>&1; then
    run_root python3 - <<'PY'
import configparser, os

p = "/etc/wsl.conf"
cp = configparser.ConfigParser()
if os.path.exists(p):
    cp.read(p)
if not cp.has_section("boot"):
    cp.add_section("boot")
cp.set("boot", "systemd", "true")
if not cp.has_section("automount"):
    cp.add_section("automount")
cp.set("automount", "enabled", "true")
cp.set("automount", "options", '"metadata"')
with open(p, "w") as f:
    cp.write(f, space_around_delimiters=False)
PY
  else
    run_root tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true

[automount]
enabled=true
options="metadata"
EOF
  fi
  run_as_user_exec mkdir -p "${TARGET_HOME}/models"
  echo "1" | run_root tee "$WSL2_CONF_MARKER" >/dev/null
  echo -e "${C_GREEN}Updated /etc/wsl.conf and ensured ${TARGET_HOME}/models exists on native ext4.${C_RESET}"
  echo -e "${C_YELLOW}Keep model weights under ${TARGET_HOME}/models (never /mnt/c) and run 'wsl --shutdown' to activate /etc/wsl.conf changes.${C_RESET}"
}
revert_wsl2_linux_tuning() {
  if [[ -f /etc/wsl.conf.strata.bak ]]; then
    run_root mv -f /etc/wsl.conf.strata.bak /etc/wsl.conf
  else
    run_root rm -f /etc/wsl.conf
  fi
  run_root rm -f "$WSL2_CONF_MARKER"
}
