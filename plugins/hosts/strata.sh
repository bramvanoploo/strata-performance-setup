#!/usr/bin/env bash
# PLUGIN_ID: strata
# PLUGIN_NAME: Strata
# PLUGIN_DESC: Install, update, launch, and benchmark Strata LLM server

register_host_plugin \
  --id "strata" \
  --name "Strata" \
  --description "Install, update, launch, and benchmark Strata LLM server" \
  --url "https://github.com/Niko1221/Strata"

strata_init() {
  refresh_strata_bin
  refresh_strata_running
  [[ "${_IN_SERVER_UPDATE_POLLER:-false}" != true ]] && start_strata_update_poller
}

strata_menu_row() {
  local selected="${1:-false}"
  format_strata_toggle_row "$selected"
}

strata_open() {
  show_strata_options_page
}

strata_live_stats() {
  refresh_strata_running
  collect_strata_stats_lines
}

strata_table_status() {
  local inst=false svc="not installed"
  if [[ -n "$STRATA_BIN" || -n "$STRATA_DOCKER_CONTAINER" ]]; then
    inst=true
    if [[ -n "$STRATA_DOCKER_CONTAINER" && -z "$STRATA_BIN" ]]; then
      svc="${C_GREEN}running (docker)${C_RESET}"
    elif strata_service_installed; then
      if unit_active strata.service; then
        svc="${C_GREEN}active (service)${C_RESET}"
      elif [[ -n "$STRATA_RUNNING_PRESET" ]]; then
        svc="${C_YELLOW}running (manual)${C_RESET}"
      else
        svc="${C_YELLOW}inactive (service)${C_RESET}"
      fi
    elif [[ -n "$STRATA_RUNNING_PRESET" ]]; then
      svc="${C_GREEN}running (manual)${C_RESET}"
    else
      svc="${C_DIM}no service${C_RESET}"
    fi
  fi
  printf "%s|%s" "$inst" "$svc"
}

strata_bench_stats() {
  collect_strata_bench_lines
}

strata_check_summary() {
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
  echo "  Strata:   ${strata_desc}"
}

strata_hw_warnings() {
  format_strata_hw_warnings
}

strata_cleanup() {
  stop_strata_update_poller
}

strata_check_update() {
  load_strata_update_state
}

strata_update() {
  perform_strata_update
}

refresh_strata_bin() {
  if command -v strata >/dev/null 2>&1; then STRATA_BIN="$(command -v strata)"
  elif [[ -x "$TARGET_HOME/.local/bin/strata" ]]; then STRATA_BIN="$TARGET_HOME/.local/bin/strata"
  elif [[ -x "/opt/homebrew/bin/strata" ]]; then STRATA_BIN="/opt/homebrew/bin/strata"
  elif [[ -x "/opt/homebrew/sbin/strata" ]]; then STRATA_BIN="/opt/homebrew/sbin/strata"
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
  if [[ -n "$st_json" ]] && has_working_python3; then
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


# 13. Strata Manager
strata_service_label() {
  if [[ "$HAS_LAUNCHD" == true ]]; then
    echo "com.strata.server"
  else
    echo "strata.service"
  fi
}
applicable_strata_manager() { return 0; }
title_strata_manager() {
  if [[ "$HAS_LAUNCHD" == true ]]; then
    echo "Strata: Install, Update, Launch & launchd Service"
  else
    echo "Strata: Install, Update, Launch & Systemd Service"
  fi
}
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
  if [[ "$IS_MACOS" == true ]]; then
    mtime_sig="$(stat -f '%N:%m:%z' "$eng_dir" "$eng_dir"/*/engine-component.json 2>/dev/null || true)"
  else
    mtime_sig="$(stat -c '%n:%Y:%s' "$eng_dir" "$eng_dir"/*/engine-component.json 2>/dev/null || true)"
  fi
  ckey="${eng_dir}|${missing_key}|${mtime_sig}"
  [[ "$ckey" == "$LOCAL_HIP_INFO_CACHE_KEY" ]] && return 0

  LOCAL_HIP_INFO_CACHE_MATCH=""
  LOCAL_HIP_INFO_CACHE_ANY=""
  if has_working_python3; then
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
  if [[ -n "$json_out" ]] && has_working_python3; then
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
  if [[ -z "$STRATA_UPDATE_CACHE_FILE" ]]; then
    mkdir -p "$(_host_update_cache_dir)" 2>/dev/null || return 0
    STRATA_UPDATE_CACHE_FILE="$(_host_update_cache_dir)/strata-update-check.$$"
  fi
  [[ -n "$STRATA_UPDATE_CACHE_FILE" ]] || return 0
  (
    trap 'kill $(jobs -p) 2>/dev/null || true; exit 0' TERM INT
    while true; do
      check_strata_update_sync >/dev/null 2>&1 || true
      # shortcut: 2h matches the update-cache TTL in _host_check_update_cached; polling faster only burns requests
      sleep 7200 &
      wait $! 2>/dev/null || exit 0
    done
  ) &
  STRATA_POLLER_PID=$!
}

wait_for_strata_model_live() {
  local max_wait="${1:-120}" elapsed=0 json_out ready_profile="" svc_lbl log_hint=""
  svc_lbl="$(strata_service_label)"
  if [[ "$HAS_SYSTEMD" == true ]]; then
    log_hint=" (check 'journalctl -u strata -n 50')"
  elif [[ "$HAS_LAUNCHD" == true ]]; then
    log_hint=" (check '${TARGET_HOME}/Library/Logs/strata.err.log')"
  fi
  echo -e "${C_DIM}Waiting for Strata model to become ready...${C_RESET}"
  while (( elapsed < max_wait )); do
    if ! unit_active strata.service; then
      echo -e "${C_RED}${svc_lbl} is not active${log_hint}.${C_RESET}"
      return 1
    fi
    json_out="$(run_as_user_exec "$STRATA_BIN" update --check --json 2>/dev/null || true)"
    if [[ -n "$json_out" ]] && has_working_python3; then
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
    echo -e "${C_GREEN}${svc_lbl} is active (model readiness not reported via JSON within ${max_wait}s).${C_RESET}"
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

  local svc_lbl
  svc_lbl="$(strata_service_label)"
  if [[ "$was_active" == true ]]; then
    echo -e "\n${C_CYAN}Stopping ${svc_lbl} before updating...${C_RESET}"
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
    echo -e "\n${C_CYAN}Restarting ${svc_lbl}...${C_RESET}"
    if service_ctl start strata.service; then
      wait_for_strata_model_live 120
    else
      local log_hint=""
      [[ "$HAS_SYSTEMD" == true ]] && log_hint=" (check 'journalctl -u strata -n 50')"
      [[ "$HAS_LAUNCHD" == true ]] && log_hint=" (check '${TARGET_HOME}/Library/Logs/strata.err.log')"
      echo -e "${C_RED}Failed to start ${svc_lbl}${log_hint}.${C_RESET}"
    fi
  elif strata_service_installed; then
    echo ""
    if confirm_yn "${svc_lbl} is installed but was stopped. Start it now? [y/N]: " "N"; then
      if service_ctl start strata.service; then
        wait_for_strata_model_live 120
      else
        echo -e "${C_RED}Failed to start ${svc_lbl}.${C_RESET}"
      fi
    fi
  fi

  start_strata_update_poller
}
format_strata_hw_warnings() {
  if [[ "$IS_MACOS" == true ]]; then
    if [[ "$IS_APPLE_SILICON" == false ]]; then
      echo -e "${C_RED}[WARNING] Intel Macs (x86_64) are not supported by Strata for macOS. Upstream Strata requires Apple Silicon (M1 or newer).${C_RESET}"
      return 0
    fi
    if (( MACOS_MAJOR > 0 && MACOS_MAJOR < 15 )); then
      echo -e "${C_RED}[WARNING] Detected macOS ${MACOS_VER}. Strata's Metal engine requires macOS 15 or newer (Metal residency sets).${C_RESET}"
    fi
    if (( RAM_GB > 0 && RAM_GB < 16 )); then
      echo -e "${C_YELLOW}[WARNING] Unified memory is ${RAM_GB} GiB (< 16 GiB). Strata models require at least 16 GiB unified memory.${C_RESET}"
    elif (( RAM_GB >= 16 && RAM_GB < 64 )); then
      echo -e "${C_YELLOW}[NOTE] Unified memory is ${RAM_GB} GiB (16-48 GiB tier): Strata streams experts from the internal SSD. Keep models on the internal SSD and apply Spotlight exclusion.${C_RESET}"
    fi
    return 0
  fi

  if (( RAM_MB > 0 && RAM_MB <= 31744 )) || (( RAM_MB == 0 && RAM_GB > 0 && RAM_GB <= 31 )); then
    echo -e "${C_YELLOW}[WARNING] System RAM is ${RAM_GB} GiB (<= 31 GiB). Larger Strata models may not fit or may swap.${C_RESET}"
  fi
  if [[ "$IS_JETSON" == true ]]; then
    return 0
  elif [[ "$IS_ASAHI_LINUX" == true && "$HAS_NVIDIA" == false && "$HAS_AMD" == false && "$HAS_INTEL_ARC" == false ]]; then
    echo -e "${C_YELLOW}[NOTE] Apple Silicon on Linux (Asahi) detected. Upstream Strata's Apple Silicon Metal engine currently requires macOS 15+ (Linux ARM64 prebuilt engines target DGX Spark CUDA).${C_RESET}"
    return 0
  elif [[ "$HAS_NVIDIA" == false && "$HAS_AMD" == false && "$HAS_INTEL_ARC" == false ]]; then
    echo -e "${C_YELLOW}[WARNING] No dedicated NVIDIA, AMD Radeon, or Intel Arc GPU detected (${GPU_SUMMARY}). Strata models may not run.${C_RESET}"
  elif [[ "$HAS_NVIDIA" == true && "$HAS_NVIDIA_UNIFIED_MEM" == false && "$NVIDIA_VRAM_MB" -gt 0 && "$NVIDIA_VRAM_MB" -le 5120 ]]; then
    echo -e "${C_YELLOW}[WARNING] NVIDIA GPU VRAM is $((NVIDIA_VRAM_MB / 1024)) GiB (<= 5 GiB). Larger Strata models may not fit in VRAM.${C_RESET}"
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
  local svc_lbl
  svc_lbl="$(strata_service_label)"
  cat <<EOF
Impact:
  Installs Strata (Niko1221/Strata), checks for updates ('strata update'),
  runs 'strata launch', benchmarks running instances ('strata bench run'),
  and installs/uninstalls ${svc_lbl} using a saved preset.
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
  local svc_mgr="systemd" svc_lbl
  svc_lbl="$(strata_service_label)"
  [[ "$HAS_LAUNCHD" == true ]] && svc_mgr="launchd"
  [[ "$HAS_SYSTEMD" == false && "$HAS_LAUNCHD" == false ]] && svc_mgr="service"
  echo -e "\n${C_BOLD}Select a Strata preset for ${svc_mgr} service:${C_RESET}"
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
  echo -e "${C_GREEN}${svc_lbl} installed and started with preset '${selected_preset}'.${C_RESET}"
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
        fm="$(file_mtime "$f")"
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


_strata_bench_search_dirs() {
  printf '%s\n' \
    "$PWD/bench/results" \
    "$PWD/bench-results" \
    "$TARGET_HOME/bench/results" \
    "$TARGET_HOME/bench-results" \
    "$TARGET_HOME/.local/share/strata/bench-results" \
    "$TARGET_HOME/.config/strata/bench-results"
}

_strata_bench_py() {
  local action="$1"; shift
  python3 - "$action" "$STRATA_BENCH_HISTORY_FILE" "$@" <<'PY'
import datetime, glob, json, os, statistics, sys

action = sys.argv[1]
hist_path = sys.argv[2]
rest = sys.argv[3:]

def fmt_ts(ts):
    ts = (ts or "").replace("T", " ")
    if ts.endswith("Z"):
        ts = ts[:-1] + " UTC"
    if len(ts) > 20 and " UTC" in ts:
        ts = ts[:16] + " UTC"
    return ts

def load_hist(path):
    hist_list, hist_by_file = [], {}
    if path and os.path.exists(path):
        try:
            with open(path) as f:
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
    return hist_list, hist_by_file

def extract_metrics(d, path=None, he=None, default_tag="", preset=""):
    run = d.get("run") if isinstance(d.get("run"), dict) else {}
    raw_ts = run.get("started_at") or run.get("timestamp") or d.get("timestamp") or ""
    ts = fmt_ts(raw_ts)
    if not ts and path:
        try:
            ts = datetime.datetime.fromtimestamp(os.path.getmtime(path), tz=datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        except Exception:
            ts = "Unknown"
    cfg = d.get("configuration") if isinstance(d.get("configuration"), dict) else {}
    proto_d = d.get("protocol") if isinstance(d.get("protocol"), dict) else {}
    prof = proto_d.get("profile") or cfg.get("profile") or preset or ""
    proto = proto_d.get("id") or d.get("protocol_id") or d.get("format") or ""
    tag = prof or ("standard-v1" if "standard" in proto else proto) or (he.get("tag") if he else "") or default_tag
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
    dec = pre = tot_r = None
    fail_r = 0
    if isinstance(sums_raw, list):
        perf_dec = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("phase") == "performance" and s.get("metric") == "decode_tps" and isinstance(s.get("median"), (int, float))]
        all_dec = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("metric") == "decode_tps" and isinstance(s.get("median"), (int, float))]
        perf_pre = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("phase") == "performance" and s.get("metric") == "prompt_tps" and isinstance(s.get("median"), (int, float))]
        all_pre = [s.get("median") for s in sums_raw if isinstance(s, dict) and s.get("metric") == "prompt_tps" and isinstance(s.get("median"), (int, float))]
        dec = statistics.median(perf_dec) if perf_dec else (statistics.median(all_dec) if all_dec else None)
        pre = statistics.median(perf_pre) if perf_pre else (statistics.median(all_pre) if all_pre else None)
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
    avg_dec_vals, avg_pre_vals = [], []
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

    req_d, opt_d = run.get("required_duration_s"), run.get("optional_duration_s")
    dur_s = f"{req_d + (opt_d if isinstance(opt_d, (int, float)) else 0.0):.1f}s" if isinstance(req_d, (int, float)) else ""

    rcounts = d.get("request_counts") if isinstance(d.get("request_counts"), dict) else {}
    if not isinstance(tot_r, int) and rcounts:
        tot_r = sum(v.get("attempted", 0) for v in rcounts.values() if isinstance(v, dict) and isinstance(v.get("attempted"), int))
        fail_r = sum(v.get("failed", 0) for v in rcounts.values() if isinstance(v, dict) and isinstance(v.get("failed"), int))
    if not isinstance(tot_r, int) and reqs:
        tot_r = len(reqs)
        fail_r = sum(1 for r in reqs if isinstance(r, dict) and r.get("status") not in (None, "ok", "completed"))

    qual = d.get("quality") if isinstance(d.get("quality"), dict) else {}
    qp = qual.get("sanity_checks_passed") if qual.get("sanity_checks_passed") is not None else qual.get("passed")
    qt = qual.get("sanity_checks_total") if qual.get("sanity_checks_total") is not None else qual.get("total")
    pwr = he.get("avg_power") if isinstance((he or {}).get("avg_power"), dict) else {}
    has_opts = "1" if (he is not None and "active_steps" in he) else "0"
    act_list = he.get("active_steps") if isinstance((he or {}).get("active_steps"), list) else []

    return {
        "run_id": run.get("id"), "raw_ts": raw_ts, "ts": ts, "tag": tag, "model": model_s,
        "dec": float(dec) if isinstance(dec, (int, float)) else None,
        "pre": float(pre) if isinstance(pre, (int, float)) else None,
        "avg_dec": float(avg_dec) if isinstance(avg_dec, (int, float)) else None,
        "avg_pre": float(avg_pre) if isinstance(avg_pre, (int, float)) else None,
        "tot_r": tot_r if isinstance(tot_r, int) else None,
        "fail_r": fail_r if isinstance(fail_r, int) else 0,
        "qp": qp, "qt": qt, "dur_s": dur_s,
        "sw": str(pwr.get("sys_w") or ""), "gw": str(pwr.get("gpu_w") or ""), "cw": str(pwr.get("cpu_w") or ""),
        "has_opts": has_opts, "act_list": act_list,
        "key": os.path.realpath(path) if path else "",
    }

def from_results_file(path, he, default_tag=""):
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception:
        return None
    if not isinstance(d, dict):
        return None
    return extract_metrics(d, path=path, he=he, default_tag=default_tag)

def from_hist_entry(e, idx_fallback):
    pwr = e.get("avg_power") if isinstance(e.get("avg_power"), dict) else {}
    rf = e.get("results_file") or ""
    act_list = e.get("active_steps") if isinstance(e.get("active_steps"), list) else []
    dec, pre = e.get("decode_tok_s"), e.get("prefill_tok_s")
    avg_dec, avg_pre = e.get("avg_decode_tok_s"), e.get("avg_prefill_tok_s")
    tot_r = e.get("total_requests")
    fail_r = e.get("failed_requests") if isinstance(e.get("failed_requests"), int) else 0
    return {
        "ts": fmt_ts(e.get("timestamp")),
        "tag": e.get("tag") or e.get("mode") or "",
        "model": e.get("model") or "Unknown",
        "dec": float(dec) if isinstance(dec, (int, float)) else None,
        "pre": float(pre) if isinstance(pre, (int, float)) else None,
        "avg_dec": float(avg_dec) if isinstance(avg_dec, (int, float)) else None,
        "avg_pre": float(avg_pre) if isinstance(avg_pre, (int, float)) else None,
        "tot_r": tot_r if isinstance(tot_r, int) else None,
        "fail_r": fail_r,
        "qp": e.get("sanity_checks_passed"), "qt": e.get("sanity_checks_total"),
        "dur_s": "",
        "sw": str(pwr.get("sys_w") or ""), "gw": str(pwr.get("gpu_w") or ""), "cw": str(pwr.get("cpu_w") or ""),
        "has_opts": "1", "act_list": act_list,
        "key": os.path.realpath(rf) if rf else f"hist:{e.get('id') or e.get('timestamp') or idx_fallback}",
    }

def collect_items(search_dirs, default_tag=""):
    hist_list, hist_by_file = load_hist(hist_path)
    items, seen = [], set()
    for e in reversed(hist_list):
        rf = e.get("results_file") or ""
        rec = from_results_file(rf, e, default_tag) if (rf and os.path.exists(rf)) else from_hist_entry(e, len(items))
        if rec and rec["key"] not in seen:
            seen.add(rec["key"])
            items.append(rec)
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
        rec = from_results_file(p, hist_by_file.get(rp) or hist_by_file.get(p), default_tag)
        if rec:
            seen.add(rp)
            items.append(rec)
    return items

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

if action == "save":
    tmp_path, res_path, mode, preset, url, avg_sys, avg_gpu, avg_cpu, samples_s, active_csv, applicable_csv = rest[:11]
    history, _ = load_hist(hist_path)
    res_data = {}
    if res_path and os.path.exists(res_path):
        try:
            with open(res_path) as f:
                loaded = json.load(f)
                if isinstance(loaded, dict):
                    res_data = loaded
        except Exception:
            pass
    m = extract_metrics(res_data, default_tag=mode, preset=preset)
    ts = m["raw_ts"] or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    entry = {
        "id": m["run_id"] or ts,
        "timestamp": ts,
        "mode": mode,
        "tag": m["tag"],
        "preset": preset,
        "url": url,
        "results_file": res_path,
        "model": m["model"],
        "decode_tok_s": round(m["dec"], 2) if m["dec"] is not None else None,
        "prefill_tok_s": round(m["pre"], 2) if m["pre"] is not None else None,
        "avg_decode_tok_s": round(m["avg_dec"], 2) if m["avg_dec"] is not None else None,
        "avg_prefill_tok_s": round(m["avg_pre"], 2) if m["avg_pre"] is not None else None,
        "total_requests": m["tot_r"],
        "failed_requests": m["fail_r"],
        "sanity_checks_passed": m["qp"],
        "sanity_checks_total": m["qt"],
        "avg_power": {
            "sys_w": avg_sys, "gpu_w": avg_gpu, "cpu_w": avg_cpu,
            "samples": int(samples_s) if samples_s.isdigit() else 0,
        },
        "active_steps": [s for s in active_csv.split(",") if s],
        "applicable_steps": [s for s in applicable_csv.split(",") if s],
    }
    history.append(entry)
    with open(tmp_path, "w") as f:
        json.dump(history, f, indent=2)
    os.replace(tmp_path, hist_path)
elif action == "count":
    hist_list, _ = load_hist(hist_path)
    seen, count = set(), 0
    for e in hist_list:
        rf = e.get("results_file") or ""
        key = os.path.realpath(rf) if rf else f"hist:{e.get('id') or e.get('timestamp') or count}"
        if key not in seen:
            seen.add(key)
            count += 1
    for sd in rest:
        if not os.path.isdir(sd):
            continue
        for pat in (os.path.join(sd, "*", "results.json"), os.path.join(sd, "results.json")):
            for p in glob.glob(pat):
                rp = os.path.realpath(p)
                if rp not in seen:
                    seen.add(rp)
                    count += 1
    print(count)
elif action == "history":
    items = collect_items(rest, default_tag="cli")
    best_idx = max(range(len(items)), key=lambda i: score_key(items[i])) if any(
        (items[i].get("avg_dec") is not None or items[i].get("dec") is not None) for i in range(len(items))
    ) else None
    for idx, rec in enumerate(items):
        d_pct, p_pct = pct_vs_ref(rec, items[best_idx]) if (best_idx is not None and idx != best_idx) else ("", "")
        is_best = "1" if (best_idx is not None and idx == best_idx) else "0"
        dec_s = f"{rec['dec']:.1f}" if rec["dec"] is not None else "—"
        pre_s = f"{rec['pre']:.1f}" if rec["pre"] is not None else "—"
        avg_dec_s = f"{rec['avg_dec']:.1f}" if rec["avg_dec"] is not None else ""
        avg_pre_s = f"{rec['avg_pre']:.1f}" if rec["avg_pre"] is not None else ""
        req_s = f"{rec['tot_r'] - rec['fail_r']}/{rec['tot_r']} ok" if isinstance(rec["tot_r"], int) and rec["tot_r"] > 0 else ""
        qual_s = f"Sanity {rec['qp']}/{rec['qt']}" if isinstance(rec["qp"], int) and isinstance(rec["qt"], int) and rec["qt"] > 0 else ""
        act = ",".join(rec["act_list"])
        act_n = str(len(rec["act_list"])) if rec["has_opts"] == "1" else "untracked"
        cols = [idx, rec["ts"], rec["tag"], rec["model"], dec_s, pre_s, rec["sw"], rec["gw"], rec["cw"],
                act_n, act, req_s, qual_s, rec["has_opts"], avg_dec_s, avg_pre_s, rec["dur_s"], d_pct, p_pct, is_best]
        print("|".join(str(c).replace("|", "/").replace("\n", " ").replace("\r", "") for c in cols))
elif action == "summary":
    items = collect_items(rest, default_tag="")
    if not items:
        sys.exit(0)
    def fmt_rec(kind, rec, d_pct="", p_pct="", prev_d_pct="", prev_p_pct=""):
        dec_s = f"{rec['dec']:.1f} tok/s" if rec["dec"] is not None else "—"
        pre_s = f"{rec['pre']:.1f} tok/s" if rec["pre"] is not None else "—"
        avg_dec_s = f"{rec['avg_dec']:.1f} tok/s" if rec.get("avg_dec") is not None else ""
        avg_pre_s = f"{rec['avg_pre']:.1f} tok/s" if rec.get("avg_pre") is not None else ""
        req_s = f"{rec['tot_r'] - rec['fail_r']}/{rec['tot_r']} ok" if isinstance(rec["tot_r"], int) and rec["tot_r"] > 0 else ""
        qual_s = f"Sanity: {rec['qp']}/{rec['qt']}" if isinstance(rec["qp"], int) and isinstance(rec["qt"], int) and rec["qt"] > 0 else ""
        cols = [kind, rec["ts"], rec["tag"], rec["model"], dec_s, pre_s, req_s, qual_s,
                rec["sw"], rec["gw"], rec["cw"], d_pct, p_pct, avg_dec_s, avg_pre_s, prev_d_pct, prev_p_pct]
        return "|".join(str(c).replace("|", "/").replace("\n", " ").replace("\r", "") for c in cols)
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
}

save_bench_history_entry() {
  local results_file="$1" mode="$2" avg_sys="$3" avg_gpu="$4" avg_cpu="$5" samples="$6" active_csv="$7" applicable_csv="$8"
  has_working_python3 || return 0
  local hist_dir
  hist_dir="$(dirname "$STRATA_BENCH_HISTORY_FILE")"
  run_as_user_exec mkdir -p "$hist_dir" 2>/dev/null || mkdir -p "$hist_dir"
  local tmp_file
  tmp_file="$(mktemp "${STRATA_BENCH_HISTORY_FILE}.tmp.XXXXXX" 2>/dev/null || echo "")"
  [[ -n "$tmp_file" ]] || return 1

  _strata_bench_py save "$tmp_file" "$results_file" "$mode" "${STRATA_RUNNING_PRESET:-}" "${STRATA_RUNNING_URL:-}" "$avg_sys" "$avg_gpu" "$avg_cpu" "${samples:-0}" "$active_csv" "$applicable_csv"
  if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
    chown -R "$TARGET_USER:$(id -gn "$TARGET_USER")" "$hist_dir" 2>/dev/null || true
  fi
}

count_bench_history() {
  has_working_python3 || { echo 0; return 0; }
  local newest="" hist_mtime="0" newest_mtime="0" ckey
  newest="$(find_latest_results_json 0)"
  [[ -r "$STRATA_BENCH_HISTORY_FILE" ]] && hist_mtime="$(file_mtime "$STRATA_BENCH_HISTORY_FILE")"
  [[ -n "$newest" ]] && newest_mtime="$(file_mtime "$newest")"
  ckey="${STRATA_BENCH_HISTORY_FILE}:${hist_mtime}:${newest}:${newest_mtime}"
  if [[ "$ckey" == "$BENCH_HISTORY_COUNT_KEY" ]]; then
    echo "$BENCH_HISTORY_COUNT_CACHE"
    return 0
  fi
  local -a _sdirs=()
  mapfile -t _sdirs < <(_strata_bench_search_dirs)
  local cnt
  cnt="$(_strata_bench_py count "${_sdirs[@]}" 2>/dev/null || echo 0)"
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
    if ! has_working_python3; then
      echo -e "${C_BOLD}Strata Benchmark History & Coupled Configurations${C_RESET}"
      echo -e "${C_DIM}----------------------------------------------------------------------${C_RESET}"
      echo -e "${C_DIM}python3 is required to parse benchmark results.${C_RESET}"
      pause_prompt
      return 0
    fi

    local -a rows=() _sdirs=()
    mapfile -t _sdirs < <(_strata_bench_search_dirs)
    while IFS= read -r line; do
      [[ -n "$line" ]] && rows+=("$line")
    done < <(_strata_bench_py history "${_sdirs[@]}" 2>/dev/null || true)
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
      cur_line_no="$(printf "%s" "$body" | wc -l | tr -d '[:space:]')"
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
    body_lines="$(printf "%s" "$body" | wc -l | tr -d '[:space:]')"
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
  [[ -n "$pwr_disp" ]] && echo -e "  Average Power: ${C_YELLOW}${pwr_disp}${C_RESET} (${samples} samples)"
  return "$rc"
}

ACTIVE_STRATA_OPTIONS=()

strata_show_build_hip() {
  [[ "$IS_MACOS" == true ]] && return 1
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
title_strata_service()   {
  if [[ "$HAS_LAUNCHD" == true ]]; then
    echo "Manage Strata launchd Service (com.strata.server)"
  else
    echo "Manage Strata Systemd Service (strata.service)"
  fi
}
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

_strata_run_installer() {
  command -v curl >/dev/null 2>&1 || prompt_install_deps repo curl || return 1
  run_as_user_exec sh -c 'curl -fsSL https://github.com/Niko1221/Strata/releases/latest/download/install.sh | sh'
  refresh_strata_bin
  [[ -n "$STRATA_BIN" && -z "$STRATA_POLLER_PID" ]] && start_strata_update_poller
  return 0
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
    _strata_run_installer || return 0
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
  local svc_lbl
  svc_lbl="$(strata_service_label)"
  echo -e "${C_YELLOW}This will stop any running Strata instance, uninstall ${svc_lbl} (if installed), and remove ${STRATA_BIN:-the Strata binary}.${C_RESET}"
  confirm_yn "Remove Strata now? [y/N]: " "N" || return 0
  stop_strata_update_poller
  if strata_service_installed; then
    remove_service strata.service && echo -e "${C_GREEN}${svc_lbl} uninstalled.${C_RESET}"
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
  local svc_lbl log_hint=""
  svc_lbl="$(strata_service_label)"
  [[ "$HAS_SYSTEMD" == true ]] && log_hint=" (check 'journalctl -u strata -n 50')"
  [[ "$HAS_LAUNCHD" == true ]] && log_hint=" (check '${TARGET_HOME}/Library/Logs/strata.err.log')"
  if strata_service_installed; then
    echo -e "${C_GREEN}${svc_lbl} is installed ($(unit_active strata.service && echo "active" || echo "inactive")).${C_RESET}"
    echo "  1) Start / Restart ${svc_lbl}"
    echo "  2) Stop ${svc_lbl}"
    echo "  3) Change preset / reinstall ${svc_lbl}"
    echo "  4) Uninstall ${svc_lbl}"
    echo "  5) Cancel"
    local svc_choice
    read -r -p "Choose [1-5]: " svc_choice
    case "$svc_choice" in
      1)
        if service_ctl restart strata.service; then
          wait_for_strata_model_live 120
        else
          echo -e "${C_RED}Failed to start ${svc_lbl}${log_hint}.${C_RESET}"
        fi
        ;;
      2)
        service_ctl stop strata.service && echo -e "${C_GREEN}${svc_lbl} stopped.${C_RESET}"
        ;;
      3) install_strata_service_fn ;;
      4) remove_service strata.service && echo -e "${C_GREEN}${svc_lbl} uninstalled.${C_RESET}" ;;
      5|"") ;;
      *) echo -e "${C_RED}Invalid selection '${svc_choice}'. Cancelled.${C_RESET}" ;;
    esac
  else
    local preset_count
    preset_count="$(list_strata_presets | wc -l | tr -d '[:space:]')"
    if (( preset_count == 0 )); then
      echo -e "${C_YELLOW}No saved Strata presets found yet.${C_RESET}"
      if confirm_yn "Launch Strata interactively now ('strata launch') to create a preset? [y/N]: " "N"; then
        run_as_user_exec "$STRATA_BIN" launch
        preset_count="$(list_strata_presets | wc -l | tr -d '[:space:]')"
      fi
    fi
    if (( preset_count > 0 )); then
      confirm_yn "Saved presets detected ($preset_count). Install ${svc_lbl}? [Y/n]: " "Y" && install_strata_service_fn
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
  local svc_lbl
  svc_lbl="$(strata_service_label)"
  cat <<EOF
Impact:
  Checks whether a newer Strata engine/control release is available and runs
  'strata update --yes'. Stops ${svc_lbl} (if active) or any running
  'strata launch' instance and waits until Strata is fully stopped before
  updating, then restarts ${svc_lbl} if it was active.
EOF
  if [[ -n "$STRATA_BIN" ]]; then
    echo -e "\nInstalled: ${STRATA_VERSION:-$STRATA_BIN}"
    [[ "$STRATA_UPDATE_AVAILABLE" == true ]] && echo -e "${C_BGREEN}Update available: ${STRATA_UPDATE_SUMMARY}${C_RESET}"
  fi
}

explain_strata_remove() {
  local svc_lbl
  svc_lbl="$(strata_service_label)"
  cat <<EOF
Impact:
  Stops any running Strata instance, uninstalls ${svc_lbl} (if present),
  and removes the Strata binary from the host. Saved launch presets and
  coupled benchmark history are preserved.
EOF
  [[ -n "$STRATA_BIN" ]] && echo -e "\nBinary: ${STRATA_BIN}"
}

explain_strata_service() {
  local svc_lbl
  svc_lbl="$(strata_service_label)"
  if [[ "$HAS_LAUNCHD" == true ]]; then
    cat <<EOF
Impact:
  Configures ${svc_lbl} (launchd LaunchAgent) using a saved 'strata launch'
  preset with AbandonProcessGroup=true and any configured Metal switches.
  Lets you start, stop, restart, change preset, or uninstall the service.
EOF
  else
    cat <<EOF
Impact:
  Configures ${svc_lbl} (systemd) using a saved 'strata launch' preset
  with LimitMEMLOCK=infinity (and numactl --interleave=all when enabled).
  Lets you start, stop, restart, change preset, or uninstall the service.
EOF
  fi
  local preset_count
  preset_count="$(list_strata_presets | wc -l | tr -d '[:space:]')"
  echo -e "\nSaved presets: ${preset_count}"
}

explain_strata_benchmark() {
  local svc_lbl
  svc_lbl="$(strata_service_label)"
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
    echo -e "\n${C_YELLOW}Strata is not currently serving. Start ${svc_lbl} or 'strata launch' first.${C_RESET}"
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
      _strata_run_installer || return 1
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
    body_lines="$(printf "%s" "$body" | wc -l | tr -d '[:space:]')"
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
  if [[ -n "$STRATA_RUNNING_URL" ]] && (command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1) && has_working_python3; then
    local m_json hdr=()
    [[ -n "${STRATA_API_KEY:-}" ]] && hdr=("Authorization: Bearer ${STRATA_API_KEY}" "X-API-Key: ${STRATA_API_KEY}")
    m_json="$(_host_http_get "${STRATA_RUNNING_URL}/metrics" 1 ${hdr[@]+"${hdr[@]}"})"
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
  [[ -r "$STRATA_BENCH_HISTORY_FILE" ]] && hist_mtime="$(file_mtime "$STRATA_BENCH_HISTORY_FILE")"

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
  [[ -n "$newest" ]] && mtime="$(file_mtime "$newest")"
  cache_key="${newest}:${mtime}:${hist_mtime}"
  if [[ "$cache_key" == "$STRATA_BENCH_CACHE_KEY" && ${#STRATA_BENCH_LINES[@]} -gt 0 ]]; then
    return 0
  fi

  local parsed=""
  if has_working_python3; then
    local -a _sdirs=()
    mapfile -t _sdirs < <(_strata_bench_search_dirs)
    parsed="$(_strata_bench_py summary "${_sdirs[@]}" 2>/dev/null || true)"
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

# shortcut: near-duplicate raw-key loop (see read_line_with_live_stats in core)
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
    _tui_stop_live_stats_sampler "$poller_pid" "$tmp_file"
    poller_pid="" tmp_file=""
    _tui_restore_tty "$saved_tty"
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
        _tui_read_esc_seq esc_seq
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
        if [[ -z "$buf" && ( "$ch" == "q" || "$ch" == "Q" ) ]]; then
          _cleanup_strata_tty
          trap - INT TERM
          printf "\n"
          _out_var="$ch"
          return 0
        fi
        local accept=false
        if [[ -z "$buf" ]]; then
          if [[ "$ch" =~ ^[uUhHiIbBsS]$ ]] || { [[ "$ch" =~ ^[1-9]$ ]] && (( 10#$ch <= n_str )); }; then
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


