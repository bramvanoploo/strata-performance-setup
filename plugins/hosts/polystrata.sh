#!/usr/bin/env bash
# PLUGIN_ID: polystrata
# PLUGIN_NAME: PolyStrata
# PLUGIN_DESC: Install, update, manage service, and benchmark PolyStrata (Strata fork, multi-engine)
# PLUGIN_PLATFORMS: all

_POLYSTRATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_POLYSTRATA_DIR}/_common.sh" ]] && source "${_POLYSTRATA_DIR}/_common.sh"

register_host_plugin \
  --id "polystrata" \
  --name "PolyStrata" \
  --description "Install, update, manage service, and benchmark PolyStrata (Strata fork, multi-engine)" \
  --platforms "all" \
  --url "https://github.com/simplexai-labs/PolyStrata"

POLYSTRATA_BIN=""
POLYSTRATA_VERSION=""
POLYSTRATA_DOCKER=""
POLYSTRATA_SOURCE="none"
POLYSTRATA_PORT="${POLYSTRATA_PORT:-8080}"
POLYSTRATA_URL="http://127.0.0.1:${POLYSTRATA_PORT}"

_polystrata_prefix() {
  echo "${TARGET_HOME:-$HOME}/.local/share/strata-hosts/polystrata"
}

_polystrata_refresh() {
  local pfx src_dir py_bin=""
  pfx="$(_polystrata_prefix)"
  src_dir="${pfx}/src"
  POLYSTRATA_BIN=""
  POLYSTRATA_VERSION=""
  if [[ -x "${src_dir}/terminal/.venv/bin/python3" && -f "${src_dir}/polystrata.py" ]]; then
    py_bin="${src_dir}/terminal/.venv/bin/python3"
  elif [[ -x "${src_dir}/terminal/python/bin/python3" && -f "${src_dir}/polystrata.py" ]]; then
    py_bin="${src_dir}/terminal/python/bin/python3"
  else
    py_bin="$(_host_find_bin polystrata strata-poly || true)"
  fi
  if [[ -n "$py_bin" ]]; then
    POLYSTRATA_BIN="$py_bin"
    if [[ -d "${src_dir}/.git" ]]; then
      POLYSTRATA_VERSION="$(run_as_user_exec git -C "$src_dir" describe --tags --abbrev=0 2>/dev/null || run_as_user_exec git -C "$src_dir" rev-parse --short HEAD 2>/dev/null || echo "installed")"
    else
      POLYSTRATA_VERSION="installed"
    fi
  fi
  POLYSTRATA_DOCKER=""
  if [[ -z "$POLYSTRATA_BIN" ]]; then
    POLYSTRATA_DOCKER="$(_host_find_docker 'polystrata|strata-poly' || true)"
  fi
  POLYSTRATA_SOURCE="none"
  if [[ -n "$POLYSTRATA_BIN" ]]; then
    if [[ "$POLYSTRATA_BIN" == "${pfx}/"* ]]; then
      POLYSTRATA_SOURCE="installer"
    else
      POLYSTRATA_SOURCE="manual"
    fi
  fi
  HOST_INSTALL_SOURCE[polystrata]="$POLYSTRATA_SOURCE"
  POLYSTRATA_URL="$(_host_detect_url "http://127.0.0.1:${POLYSTRATA_PORT}" 'polystrata|strata-poly|serve/server\.py' "$POLYSTRATA_DOCKER" "polystrata.service")"
}

_polystrata_running() {
  _host_endpoint_running "${POLYSTRATA_URL}/v1/models" 'polystrata|strata-poly|serve/server\.py' "$POLYSTRATA_DOCKER" "polystrata.service"
}

polystrata_init() {
  _polystrata_refresh
}

polystrata_menu_row() {
  local running=false
  _polystrata_running && running=true
  _host_std_menu_row "POLYSTRATA" "PolyStrata" "${POLYSTRATA_BIN:+$POLYSTRATA_VERSION}" "$POLYSTRATA_DOCKER" "$running" "${1:-false}"
}

polystrata_check_summary() {
  local running=false
  _polystrata_running && running=true
  _host_std_check_summary "PolyStrata" "${POLYSTRATA_BIN:+$POLYSTRATA_VERSION}" "$POLYSTRATA_URL" "$POLYSTRATA_DOCKER" "$running" "$POLYSTRATA_BIN"
}

polystrata_hw_warnings() {
  if [[ "$IS_MACOS" == true && "$IS_APPLE_SILICON" != true ]]; then
    echo -e "  ${C_YELLOW}[PolyStrata]${C_RESET} Apple Silicon (arm64) is required on macOS."
  elif [[ "$IS_MACOS" != true && "$HAS_NVIDIA" != true && "$HAS_AMD" != true ]]; then
    echo -e "  ${C_YELLOW}[PolyStrata]${C_RESET} No NVIDIA or AMD GPU detected; PolyStrata's engines target NVIDIA CUDA and AMD ROCm/HIP."
  fi
}

polystrata_live_stats() {
  local running=false
  _polystrata_running && running=true
  _host_std_live_stats "PolyStrata" "$POLYSTRATA_BIN" "$POLYSTRATA_URL" "$running"
}

polystrata_table_status() {
  local running=false
  _polystrata_running && running=true
  _host_std_table_status "$POLYSTRATA_BIN" "$POLYSTRATA_DOCKER" "$running" "polystrata.service"
}

polystrata_check_update() {
  [[ -n "$POLYSTRATA_BIN" ]] && _host_check_update_by_source "polystrata" "$POLYSTRATA_SOURCE" "$POLYSTRATA_VERSION" "polystrata" "simplexai-labs/PolyStrata"
}

polystrata_update() {
  _polystrata_dispatch update
}

_polystrata_install_or_update() {
  if ! command -v git >/dev/null 2>&1; then
    echo -e "${C_RED}git is required to install/update PolyStrata.${C_RESET}"
    return 1
  fi
  local pfx src_dir
  pfx="$(_polystrata_prefix)"
  src_dir="${pfx}/src"
  run_as_user_exec mkdir -p "$pfx"
  if [[ -d "${src_dir}/.git" ]]; then
    run_as_user_exec git -C "$src_dir" pull --ff-only || return 1
  else
    run_as_user_exec git clone --depth 1 https://github.com/simplexai-labs/PolyStrata.git "$src_dir" || return 1
  fi
  if [[ -x "${src_dir}/setup.sh" ]]; then
    run_as_user_exec sh "${src_dir}/setup.sh" --setup || return 1
  fi
  _polystrata_refresh
}

_polystrata_dispatch() {
  case "$1" in
    install|update)
      _polystrata_install_or_update
      _host_clear_update_cache "polystrata"
      ;;
    latest)
      local latest
      latest="$(_host_github_latest_tag "simplexai-labs/PolyStrata" || true)"
      echo "  Installed: ${POLYSTRATA_VERSION:-none}"
      echo "  Latest:    ${latest:-unavailable}"
      ;;
    service)
      local pfx src_dir q_py q_srv work_dir
      pfx="$(_polystrata_prefix)"
      src_dir="${pfx}/src"
      if [[ -f "${src_dir}/terminal/serve/server.py" ]]; then
        q_py="$(_host_shell_quote "$POLYSTRATA_BIN")"
        q_srv="$(_host_shell_quote "${src_dir}/terminal/serve/server.py")"
        work_dir="${src_dir}/terminal"
        _host_manage_service_action "PolyStrata" "polystrata.service" "PolyStrata LLM Server" \
          "${q_py} ${q_srv} --port ${POLYSTRATA_PORT}" "$work_dir"
      else
        q_py="$(_host_shell_quote "$POLYSTRATA_BIN")"
        _host_manage_service_action "PolyStrata" "polystrata.service" "PolyStrata LLM Server" \
          "${q_py} serve --port ${POLYSTRATA_PORT}" "${TARGET_HOME:-$HOME}"
      fi
      ;;
    bench)
      _host_openai_bench "PolyStrata" "$POLYSTRATA_URL"
      ;;
    uninstall)
      _host_standard_uninstall "polystrata" "PolyStrata" "polystrata.service" "$POLYSTRATA_BIN" "$POLYSTRATA_SOURCE" "polystrata"
      _polystrata_refresh
      _host_clear_update_cache "polystrata"
      ;;
  esac
}

polystrata_open() {
  _host_run_options_page \
    --name "PolyStrata" \
    --unit "polystrata.service" \
    --refresh "_polystrata_refresh" \
    --bin-var "POLYSTRATA_BIN" \
    --ver-var "POLYSTRATA_VERSION" \
    --docker-var "POLYSTRATA_DOCKER" \
    --source-var "POLYSTRATA_SOURCE" \
    --url "$POLYSTRATA_URL" \
    --url-var "POLYSTRATA_URL" \
    --is-running "_polystrata_running" \
    --dispatch "_polystrata_dispatch"
}
