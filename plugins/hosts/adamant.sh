#!/usr/bin/env bash
# PLUGIN_ID: adamant
# PLUGIN_NAME: Adamant
# PLUGIN_DESC: Install, update, manage service, and benchmark Adamant (NVIDIA Ada/Ampere Basalt/Strata fork)
# PLUGIN_PLATFORMS: linux-nvidia

_ADAMANT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_ADAMANT_DIR}/_common.sh" ]] && source "${_ADAMANT_DIR}/_common.sh"

register_host_plugin \
  --id "adamant" \
  --name "Adamant" \
  --description "Install, update, manage service, and benchmark Adamant (NVIDIA Ada/Ampere Basalt/Strata fork)" \
  --platforms "linux-nvidia" \
  --caps "install,service,bench,stats" \
  --url "https://github.com/nixcat-dev/adamant"

ADAMANT_BIN=""
ADAMANT_VERSION=""
ADAMANT_DOCKER=""
ADAMANT_SOURCE="none"
ADAMANT_PORT="${ADAMANT_PORT:-8080}"
ADAMANT_URL="http://127.0.0.1:${ADAMANT_PORT}"

_adamant_prefix() {
  echo "${TARGET_HOME:-$HOME}/.local/share/strata-hosts/adamant"
}

_adamant_refresh() {
  local pfx
  pfx="$(_adamant_prefix)"
  ADAMANT_BIN=""
  ADAMANT_VERSION=""
  if [[ -x "${pfx}/build/bin/basalt" ]]; then
    ADAMANT_BIN="${pfx}/build/bin/basalt"
  else
    ADAMANT_BIN="$(_host_find_bin adamant || true)"
  fi
  if [[ -n "$ADAMANT_BIN" ]]; then
    if [[ -d "${pfx}/src/.git" ]]; then
      ADAMANT_VERSION="$(run_as_user_exec git -C "${pfx}/src" rev-parse --short HEAD 2>/dev/null || echo "installed")"
    else
      ADAMANT_VERSION="installed"
    fi
  fi
  ADAMANT_DOCKER=""
  if [[ -z "$ADAMANT_BIN" ]]; then
    ADAMANT_DOCKER="$(_host_find_docker 'adamant' || true)"
  fi
  ADAMANT_SOURCE="none"
  if [[ -n "$ADAMANT_BIN" ]]; then
    if [[ "$ADAMANT_BIN" == "${pfx}/"* ]]; then
      ADAMANT_SOURCE="installer"
    else
      ADAMANT_SOURCE="manual"
    fi
  fi
  HOST_INSTALL_SOURCE[adamant]="$ADAMANT_SOURCE"
  ADAMANT_URL="$(_host_detect_url "http://127.0.0.1:${ADAMANT_PORT}" 'hosts/adamant/build/bin/basalt|(^|/)adamant[[:space:]]+serve' "$ADAMANT_DOCKER" "adamant.service")"
}

_adamant_running() {
  _host_endpoint_running "${ADAMANT_URL}/v1/models" 'hosts/adamant/build/bin/basalt|(^|/)adamant[[:space:]]+serve' "$ADAMANT_DOCKER" "adamant.service"
}

adamant_init() {
  _adamant_refresh
}

adamant_menu_row() {
  local running=false
  _adamant_running && running=true
  _host_std_menu_row "ADAMANT" "Adamant" "${ADAMANT_BIN:+$ADAMANT_VERSION}" "$ADAMANT_DOCKER" "$running" "${1:-false}"
}

adamant_check_summary() {
  local running=false
  _adamant_running && running=true
  _host_std_check_summary "Adamant" "${ADAMANT_BIN:+$ADAMANT_VERSION}" "$ADAMANT_URL" "$ADAMANT_DOCKER" "$running" "$ADAMANT_BIN"
}

adamant_hw_warnings() {
  if [[ "$HAS_NVIDIA" == true ]] && command -v nvidia-smi >/dev/null 2>&1; then
    local cc
    cc="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
    if [[ -n "$cc" && "$cc" != "8.9" && "$cc" != "8.6" ]]; then
      echo -e "  ${C_YELLOW}[Adamant]${C_RESET} Detected NVIDIA compute capability ${cc}; Adamant targets Ada Lovelace (sm_89) and Ampere (sm_86)."
    fi
  fi
}

adamant_live_stats() {
  local running=false
  _adamant_running && running=true
  _host_std_live_stats "Adamant" "$ADAMANT_BIN" "$ADAMANT_URL" "$running"
}

adamant_table_status() {
  local running=false
  _adamant_running && running=true
  _host_std_table_status "$ADAMANT_BIN" "$ADAMANT_DOCKER" "$running" "adamant.service"
}

adamant_check_update() {
  HOST_UPDATE_AVAIL[adamant]="false"
  HOST_UPDATE_LATEST[adamant]=""
}

adamant_update() {
  _adamant_dispatch update
}

_adamant_install_or_update() {
  if ! command -v git >/dev/null 2>&1 || ! command -v cmake >/dev/null 2>&1; then
    echo -e "${C_RED}git and cmake are required to build Adamant from source.${C_RESET}"
    return 1
  fi
  local pfx src_dir bld_dir
  pfx="$(_adamant_prefix)"
  src_dir="${pfx}/src"
  bld_dir="${pfx}/build"
  run_as_user_exec mkdir -p "$pfx" "${TARGET_HOME:-$HOME}/.local/bin"
  if [[ -d "${src_dir}/.git" ]]; then
    run_as_user_exec git -C "$src_dir" pull --ff-only || return 1
  else
    run_as_user_exec git clone --depth 1 https://github.com/nixcat-dev/adamant.git "$src_dir" || return 1
  fi
  run_as_user_exec cmake -S "$src_dir" -B "$bld_dir" -DCMAKE_BUILD_TYPE=Release || return 1
  run_as_user_exec cmake --build "$bld_dir" -j"$(nproc 2>/dev/null || echo 4)" || return 1
  if [[ -x "${bld_dir}/bin/basalt" ]]; then
    run_as_user_exec ln -sf "${bld_dir}/bin/basalt" "${TARGET_HOME:-$HOME}/.local/bin/adamant"
  fi
  _adamant_refresh
}

_adamant_dispatch() {
  case "$1" in
    install|update)
      _adamant_install_or_update
      _host_clear_update_cache "adamant"
      ;;
    latest)
      echo "  Installed commit: ${ADAMANT_VERSION:-none}"
      echo "  Upstream repo:    https://github.com/nixcat-dev/adamant"
      ;;
    service)
      local pfx q_bin cmd
      pfx="$(_adamant_prefix)"
      q_bin="$(_host_shell_quote "$ADAMANT_BIN")"
      cmd="${q_bin} serve --port ${ADAMANT_PORT}"
      [[ -f "${pfx}/basalt_config.json" ]] && cmd="${q_bin} serve --config $(_host_shell_quote "${pfx}/basalt_config.json")"
      _host_manage_service_action "Adamant" "adamant.service" "Adamant LLM Inference Server" "$cmd" "$pfx"
      ;;
    bench)
      _host_openai_bench "Adamant" "$ADAMANT_URL"
      ;;
    uninstall)
      _host_standard_uninstall "adamant" "Adamant" "adamant.service" "$ADAMANT_BIN" "$ADAMANT_SOURCE" "adamant" "${TARGET_HOME:-$HOME}/.local/bin/adamant"
      _adamant_refresh
      _host_clear_update_cache "adamant"
      ;;
  esac
}

adamant_open() {
  _host_run_options_page \
    --name "Adamant" \
    --unit "adamant.service" \
    --refresh "_adamant_refresh" \
    --bin-var "ADAMANT_BIN" \
    --ver-var "ADAMANT_VERSION" \
    --docker-var "ADAMANT_DOCKER" \
    --source-var "ADAMANT_SOURCE" \
    --url "$ADAMANT_URL" \
    --url-var "ADAMANT_URL" \
    --is-running "_adamant_running" \
    --dispatch "_adamant_dispatch"
}
