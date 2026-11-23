#!/usr/bin/env bash
# PLUGIN_ID: exo
# PLUGIN_NAME: exo
# PLUGIN_DESC: Install, update, manage service, and benchmark exo distributed cluster server
# PLUGIN_PLATFORMS: all

_EXO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_EXO_DIR}/_common.sh" ]] && source "${_EXO_DIR}/_common.sh"

register_host_plugin \
  --id "exo" \
  --name "exo" \
  --description "Install, update, manage service, and benchmark exo distributed cluster server" \
  --platforms "all" \
  --url "https://github.com/exo-explore/exo"

EXO_BIN=""
EXO_VERSION=""
EXO_DOCKER=""
EXO_SOURCE="none"
EXO_PORT="${EXO_PORT:-52415}"
EXO_URL="http://127.0.0.1:${EXO_PORT}"

_exo_prefix() {
  echo "${TARGET_HOME:-$HOME}/.local/share/strata-hosts/exo"
}

_exo_refresh() {
  EXO_BIN="$(_host_venv_bin "exo" "exo" || true)"
  EXO_VERSION=""
  if [[ -n "$EXO_BIN" ]]; then
    EXO_VERSION="$(_host_venv_pkg_version "exo" "exo" || true)"
    if [[ -z "$EXO_VERSION" ]] && [[ -d "$(_exo_prefix)/src/.git" ]]; then
      EXO_VERSION="$(run_as_user_exec git -C "$(_exo_prefix)/src" rev-parse --short HEAD 2>/dev/null || echo "installed")"
    fi
    [[ -z "$EXO_VERSION" ]] && EXO_VERSION="installed"
  fi
  EXO_DOCKER=""
  if [[ -z "$EXO_BIN" ]]; then
    EXO_DOCKER="$(_host_find_docker '(^|[/_-])exo(:|@|$)' || true)"
  fi
  EXO_SOURCE="$(_host_detect_install_source "exo" "$EXO_BIN" "exo" false)"
  EXO_URL="$(_host_detect_url "http://127.0.0.1:${EXO_PORT}" '(^|/)exo([[:space:]]|$)|hosts/exo/src' "$EXO_DOCKER" "exo.service")"
}

_exo_running() {
  _host_endpoint_running "${EXO_URL}/v1/models" '(^|/)exo([[:space:]]|$)|hosts/exo/src' "$EXO_DOCKER" "exo.service"
}

exo_init() {
  _exo_refresh
}

exo_menu_row() {
  local running=false
  _exo_running && running=true
  _host_std_menu_row "EXO" "exo" "${EXO_BIN:+$EXO_VERSION}" "$EXO_DOCKER" "$running" "${1:-false}"
}

exo_check_summary() {
  local running=false
  _exo_running && running=true
  _host_std_check_summary "exo" "${EXO_BIN:+$EXO_VERSION}" "$EXO_URL" "$EXO_DOCKER" "$running" "$EXO_BIN"
}

exo_live_stats() {
  local running=false
  _exo_running && running=true
  _host_std_live_stats "exo" "$EXO_BIN" "$EXO_URL" "$running"
}

exo_table_status() {
  local running=false
  _exo_running && running=true
  _host_std_table_status "$EXO_BIN" "$EXO_DOCKER" "$running" "exo.service"
}

exo_check_update() {
  [[ -n "$EXO_BIN" ]] && _host_check_update_by_source "exo" "$EXO_SOURCE" "$EXO_VERSION" "exo" "exo-explore/exo"
}

exo_update() {
  _exo_dispatch update
}

_exo_install_or_update() {
  _host_git_venv_install_or_update "exo" "https://github.com/exo-explore/exo.git" "editable" || return 1
  _exo_refresh
}

_exo_dispatch() {
  case "$1" in
    install|update)
      _exo_install_or_update
      _host_clear_update_cache "exo"
      ;;
    latest)
      local latest
      latest="$(_host_github_latest_tag "exo-explore/exo" || true)"
      echo "  Installed: ${EXO_VERSION:-none}"
      echo "  Latest:    ${latest:-unavailable}"
      ;;
    service)
      local q_bin
      q_bin="$(_host_shell_quote "$EXO_BIN")"
      _host_manage_service_action "exo" "exo.service" "exo Distributed Cluster Server" \
        "${q_bin} --chatgpt-api-port ${EXO_PORT}"
      ;;
    bench)
      _host_openai_bench "exo" "$EXO_URL"
      ;;
    uninstall)
      _host_standard_uninstall "exo" "exo" "exo.service" "$EXO_BIN" "$EXO_SOURCE" "exo"
      _exo_refresh
      _host_clear_update_cache "exo"
      ;;
  esac
}

exo_open() {
  _host_run_options_page \
    --name "exo" \
    --unit "exo.service" \
    --refresh "_exo_refresh" \
    --bin-var "EXO_BIN" \
    --ver-var "EXO_VERSION" \
    --docker-var "EXO_DOCKER" \
    --source-var "EXO_SOURCE" \
    --url "$EXO_URL" \
    --url-var "EXO_URL" \
    --is-running "_exo_running" \
    --dispatch "_exo_dispatch"
}
