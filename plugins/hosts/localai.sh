#!/usr/bin/env bash
# PLUGIN_ID: localai
# PLUGIN_NAME: LocalAI
# PLUGIN_DESC: Install, update, manage service, and benchmark LocalAI server
# PLUGIN_PLATFORMS: all

_LOCALAI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_LOCALAI_DIR}/_common.sh" ]] && source "${_LOCALAI_DIR}/_common.sh"

register_host_plugin \
  --id "localai" \
  --name "LocalAI" \
  --description "Install, update, manage service, and benchmark LocalAI server" \
  --platforms "all"

LOCALAI_BIN=""
LOCALAI_VERSION=""
LOCALAI_DOCKER=""
LOCALAI_SOURCE="none"
LOCALAI_PORT="${LOCALAI_PORT:-8080}"
LOCALAI_URL="http://127.0.0.1:${LOCALAI_PORT}"

_localai_refresh() {
  LOCALAI_BIN="$(_host_find_bin local-ai localai || true)"
  LOCALAI_VERSION=""
  if [[ -n "$LOCALAI_BIN" ]]; then
    LOCALAI_VERSION="$(run_as_user_exec "$LOCALAI_BIN" --version 2>/dev/null | head -n1 || true)"
    [[ -z "$LOCALAI_VERSION" ]] && LOCALAI_VERSION="installed"
  fi
  LOCALAI_DOCKER=""
  if [[ -z "$LOCALAI_BIN" ]]; then
    LOCALAI_DOCKER="$(_host_find_docker 'local-ai|localai' || true)"
  fi
  LOCALAI_SOURCE="$(_host_detect_install_source "localai" "$LOCALAI_BIN" "localai" true)"
}

_localai_running() {
  _host_http_ok "${LOCALAI_URL}/readyz" 1 || _host_http_ok "${LOCALAI_URL}/v1/models" 1
}

localai_init() {
  _localai_refresh
}

localai_menu_row() {
  local running=false
  _localai_running && running=true
  _host_std_menu_row "LOCALAI" "LocalAI" "${LOCALAI_BIN:+$LOCALAI_VERSION}" "$LOCALAI_DOCKER" "$running" "${1:-false}"
}

localai_check_summary() {
  local running=false
  _localai_running && running=true
  _host_std_check_summary "LocalAI" "${LOCALAI_BIN:+$LOCALAI_VERSION}" "$LOCALAI_URL" "$LOCALAI_DOCKER" "$running" "$LOCALAI_BIN"
}

localai_live_stats() {
  local running=false
  _localai_running && running=true
  _host_std_live_stats "LocalAI" "$LOCALAI_BIN" "$LOCALAI_URL" "$running"
}

localai_table_status() {
  local running=false
  _localai_running && running=true
  _host_std_table_status "$LOCALAI_BIN" "$LOCALAI_DOCKER" "$running" "localai.service"
}

localai_check_update() {
  [[ -n "$LOCALAI_BIN" ]] && _host_check_update_by_source "localai" "$LOCALAI_SOURCE" "$LOCALAI_VERSION" "localai" "mudler/LocalAI"
}

localai_update() {
  _localai_dispatch update
}

_localai_install_or_update() {
  if [[ -n "$LOCALAI_BIN" ]]; then
    case "$LOCALAI_SOURCE" in
      brew)   run_as_user_exec brew upgrade localai || true ;;
      distro) pkg_install localai ;;
      aur)    aur_install localai ;;
      installer)
        echo -e "${C_CYAN}Running official LocalAI installer...${C_RESET}"
        run_root bash -c 'curl -fsSL https://localai.io/install.sh | sh'
        ;;
      *)
        echo -e "${C_YELLOW}LocalAI at ${LOCALAI_BIN} is not managed by a package manager; update it from its original source.${C_RESET}"
        return 1
        ;;
    esac
  elif [[ "$IS_MACOS" == true ]] && command -v brew >/dev/null 2>&1; then
    run_as_user_exec brew install localai
  elif [[ "$IS_MACOS" == false ]]; then
    echo -e "${C_CYAN}Running official LocalAI installer...${C_RESET}"
    run_root bash -c 'curl -fsSL https://localai.io/install.sh | sh'
  else
    echo -e "${C_YELLOW}Install Homebrew or see https://localai.io/basics/getting_started/${C_RESET}"
    return 1
  fi
  _localai_refresh
}

_localai_dispatch() {
  case "$1" in
    install|update)
      _localai_install_or_update
      _host_clear_update_cache "localai"
      ;;
    latest)
      local latest
      latest="$(_host_github_latest_tag "mudler/LocalAI" || true)"
      echo "  Installed: ${LOCALAI_VERSION:-none}"
      echo "  Latest:    ${latest:-unavailable}"
      ;;
    service)
      local q_bin
      q_bin="$(_host_shell_quote "$LOCALAI_BIN")"
      _host_manage_service_action "LocalAI" "localai.service" "LocalAI Server" \
        "${q_bin} run --address 0.0.0.0:${LOCALAI_PORT}"
      ;;
    bench)
      _host_openai_bench "LocalAI" "$LOCALAI_URL"
      ;;
  esac
}

localai_open() {
  _host_run_options_page \
    --name "LocalAI" \
    --unit "localai.service" \
    --refresh "_localai_refresh" \
    --bin-var "LOCALAI_BIN" \
    --ver-var "LOCALAI_VERSION" \
    --docker-var "LOCALAI_DOCKER" \
    --source-var "LOCALAI_SOURCE" \
    --url "$LOCALAI_URL" \
    --is-running "_localai_running" \
    --dispatch "_localai_dispatch"
}
