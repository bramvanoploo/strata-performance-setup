#!/usr/bin/env bash
# PLUGIN_ID: tabbyapi
# PLUGIN_NAME: TabbyAPI
# PLUGIN_DESC: Install, update, manage service, and benchmark TabbyAPI (ExLlamaV2/V3)
# PLUGIN_PLATFORMS: linux-gpu

_TABBYAPI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_TABBYAPI_DIR}/_common.sh" ]] && source "${_TABBYAPI_DIR}/_common.sh"

register_host_plugin \
  --id "tabbyapi" \
  --name "TabbyAPI" \
  --description "Install, update, manage service, and benchmark TabbyAPI (ExLlamaV2/V3)" \
  --platforms "linux-gpu"

TABBYAPI_BIN=""
TABBYAPI_VERSION=""
TABBYAPI_DOCKER=""
TABBYAPI_SOURCE="none"
TABBYAPI_PORT="${TABBYAPI_PORT:-5000}"
TABBYAPI_URL="http://127.0.0.1:${TABBYAPI_PORT}"

_tabbyapi_prefix() {
  echo "${TARGET_HOME:-$HOME}/.local/share/strata-hosts/tabbyapi"
}

_tabbyapi_refresh() {
  local pfx vdir
  pfx="$(_tabbyapi_prefix)"
  vdir="$(_host_venv_dir "tabbyapi")"
  TABBYAPI_BIN=""
  TABBYAPI_VERSION=""
  if [[ -x "${vdir}/bin/python3" && -f "${pfx}/src/main.py" ]]; then
    TABBYAPI_BIN="${vdir}/bin/python3"
    TABBYAPI_VERSION="$(run_as_user_exec git -C "${pfx}/src" describe --tags --abbrev=0 2>/dev/null || run_as_user_exec git -C "${pfx}/src" rev-parse --short HEAD 2>/dev/null || echo "installed")"
  fi
  TABBYAPI_DOCKER=""
  if [[ -z "$TABBYAPI_BIN" ]]; then
    TABBYAPI_DOCKER="$(_host_find_docker 'tabbyapi' || true)"
  fi
  TABBYAPI_SOURCE="none"
  [[ -n "$TABBYAPI_BIN" ]] && TABBYAPI_SOURCE="installer"
  HOST_INSTALL_SOURCE[tabbyapi]="$TABBYAPI_SOURCE"
  TABBYAPI_URL="$(_host_detect_url "http://127.0.0.1:${TABBYAPI_PORT}" 'hosts/tabbyapi/src/main\.py|tabbyAPI' "$TABBYAPI_DOCKER" "tabbyapi.service")"
}

_tabbyapi_running() {
  _host_endpoint_running "${TABBYAPI_URL}/v1/models" 'hosts/tabbyapi/src/main\.py|tabbyAPI' "$TABBYAPI_DOCKER" "tabbyapi.service"
}

tabbyapi_init() {
  _tabbyapi_refresh
}

tabbyapi_menu_row() {
  local running=false
  _tabbyapi_running && running=true
  _host_std_menu_row "TABBY" "TabbyAPI" "${TABBYAPI_BIN:+$TABBYAPI_VERSION}" "$TABBYAPI_DOCKER" "$running" "${1:-false}"
}

tabbyapi_check_summary() {
  local running=false
  _tabbyapi_running && running=true
  _host_std_check_summary "TabbyAPI" "${TABBYAPI_BIN:+$TABBYAPI_VERSION}" "$TABBYAPI_URL" "$TABBYAPI_DOCKER" "$running"
}

tabbyapi_live_stats() {
  local running=false
  _tabbyapi_running && running=true
  _host_std_live_stats "TabbyAPI" "$TABBYAPI_BIN" "$TABBYAPI_URL" "$running"
}

tabbyapi_table_status() {
  local running=false
  _tabbyapi_running && running=true
  _host_std_table_status "$TABBYAPI_BIN" "$TABBYAPI_DOCKER" "$running" "tabbyapi.service"
}

tabbyapi_check_update() {
  [[ -n "$TABBYAPI_BIN" ]] && _host_check_update_by_source "tabbyapi" "$TABBYAPI_SOURCE" "$TABBYAPI_VERSION" "tabbyapi" "theroyallab/tabbyAPI"
}

tabbyapi_update() {
  _tabbyapi_dispatch update
}

_tabbyapi_install_or_update() {
  local pfx src_dir req_file="requirements.txt"
  pfx="$(_tabbyapi_prefix)"
  src_dir="${pfx}/src"
  [[ "$HAS_AMD" == true && -f "${src_dir}/requirements-rocm.txt" ]] && req_file="requirements-rocm.txt"
  _host_git_venv_install_or_update "tabbyapi" "https://github.com/theroyallab/tabbyAPI.git" "req" "$req_file" || return 1
  _tabbyapi_refresh
}

_tabbyapi_dispatch() {
  case "$1" in
    install|update)
      _tabbyapi_install_or_update
      _host_clear_update_cache "tabbyapi"
      ;;
    latest)
      local latest
      latest="$(_host_github_latest_tag "theroyallab/tabbyAPI" || true)"
      echo "  Installed: ${TABBYAPI_VERSION:-none}"
      echo "  Latest:    ${latest:-unavailable}"
      ;;
    service)
      local pfx src_dir q_py q_main
      pfx="$(_tabbyapi_prefix)"
      src_dir="${pfx}/src"
      q_py="$(_host_shell_quote "$TABBYAPI_BIN")"
      q_main="$(_host_shell_quote "${src_dir}/main.py")"
      _host_manage_service_action "TabbyAPI" "tabbyapi.service" "TabbyAPI (ExLlamaV2/V3) Server" \
        "${q_py} ${q_main} --host 0.0.0.0 --port ${TABBYAPI_PORT}" "$src_dir"
      ;;
    bench)
      _host_openai_bench "TabbyAPI" "$TABBYAPI_URL"
      ;;
    uninstall)
      _host_standard_uninstall "tabbyapi" "TabbyAPI" "tabbyapi.service" "$TABBYAPI_BIN" "$TABBYAPI_SOURCE" "tabbyapi"
      _tabbyapi_refresh
      _host_clear_update_cache "tabbyapi"
      ;;
  esac
}

tabbyapi_open() {
  _host_run_options_page \
    --name "TabbyAPI" \
    --unit "tabbyapi.service" \
    --refresh "_tabbyapi_refresh" \
    --bin-var "TABBYAPI_BIN" \
    --ver-var "TABBYAPI_VERSION" \
    --docker-var "TABBYAPI_DOCKER" \
    --source-var "TABBYAPI_SOURCE" \
    --url "$TABBYAPI_URL" \
    --url-var "TABBYAPI_URL" \
    --is-running "_tabbyapi_running" \
    --dispatch "_tabbyapi_dispatch"
}
