#!/usr/bin/env bash
# PLUGIN_ID: ollama
# PLUGIN_NAME: Ollama
# PLUGIN_DESC: Install, update, manage service, and benchmark Ollama LLM server
# PLUGIN_PLATFORMS: all

_OLLAMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_OLLAMA_DIR}/_common.sh" ]] && source "${_OLLAMA_DIR}/_common.sh"

register_host_plugin \
  --id "ollama" \
  --name "Ollama" \
  --description "Install, update, manage service, and benchmark Ollama LLM server" \
  --platforms "all"

OLLAMA_BIN=""
OLLAMA_VERSION=""
OLLAMA_DOCKER=""
OLLAMA_URL="${OLLAMA_HOST:-http://127.0.0.1:11434}"
[[ "$OLLAMA_URL" != http* ]] && OLLAMA_URL="http://${OLLAMA_URL}"

_ollama_refresh() {
  OLLAMA_BIN="$(_host_find_bin ollama || true)"
  OLLAMA_VERSION=""
  if [[ -n "$OLLAMA_BIN" ]]; then
    OLLAMA_VERSION="$(run_as_user_exec "$OLLAMA_BIN" --version 2>/dev/null | head -n1 | sed -E 's/.*version is //; s/ollama version //i' || true)"
  fi
  OLLAMA_DOCKER=""
  if [[ -z "$OLLAMA_BIN" ]]; then
    OLLAMA_DOCKER="$(_host_find_docker '(^|[/_-])ollama(:|@|$)' || true)"
  fi
}

_ollama_running() {
  _host_http_ok "${OLLAMA_URL}/api/tags" 1
}

_ollama_loaded_models() {
  local body=""
  body="$(_host_http_get "${OLLAMA_URL}/api/ps" 1 || true)"
  [[ -n "$body" ]] || return 0
  if has_working_python3; then
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(", ".join(m.get("name", "") for m in (d.get("models") or []) if m.get("name")))
except Exception:
    pass
' <<< "$body" 2>/dev/null || true
  fi
}

ollama_init() {
  _ollama_refresh
}

ollama_menu_row() {
  local running=false
  _ollama_running && running=true
  _host_std_menu_row "OLLAMA" "Ollama" "${OLLAMA_BIN:+${OLLAMA_VERSION:-installed}}" "$OLLAMA_DOCKER" "$running" "${1:-false}"
}

ollama_check_summary() {
  local running=false
  _ollama_running && running=true
  _host_std_check_summary "Ollama" "${OLLAMA_BIN:+${OLLAMA_VERSION:-installed}}" "$OLLAMA_URL" "$OLLAMA_DOCKER" "$running" "$OLLAMA_BIN"
}

ollama_live_stats() {
  local running=false models=""
  if _ollama_running; then
    running=true
    models="$(_ollama_loaded_models)"
  fi
  _host_std_live_stats "Ollama" "$OLLAMA_BIN" "$OLLAMA_URL" "$running" "$models"
}

ollama_table_status() {
  local running=false
  _ollama_running && running=true
  _host_std_table_status "$OLLAMA_BIN" "$OLLAMA_DOCKER" "$running" "ollama.service"
}

ollama_check_update() {
  [[ -n "$OLLAMA_BIN" ]] && _host_check_update_cached "ollama" "$OLLAMA_VERSION" "ollama/ollama"
}

ollama_update() {
  _ollama_dispatch update
}

_ollama_install_or_update() {
  if [[ "$IS_MACOS" == true ]] && command -v brew >/dev/null 2>&1; then
    if [[ -n "$OLLAMA_BIN" ]]; then
      run_as_user_exec brew upgrade ollama || true
    else
      run_as_user_exec brew install ollama
    fi
  elif [[ "$IS_MACOS" == false ]]; then
    if [[ -z "$OLLAMA_BIN" ]] && pkg_available repo ollama 2>/dev/null; then
      pkg_install ollama || true
    else
      echo -e "${C_CYAN}Running official Ollama installer...${C_RESET}"
      run_root bash -c 'curl -fsSL https://ollama.com/install.sh | sh'
    fi
  else
    echo -e "${C_YELLOW}Install Homebrew or download Ollama from https://ollama.com/download${C_RESET}"
    return 1
  fi
  _ollama_refresh
}

_ollama_dispatch() {
  case "$1" in
    install|update)
      _ollama_install_or_update
      _host_clear_update_cache "ollama"
      ;;
    latest)
      local latest
      latest="$(_host_github_latest_tag "ollama/ollama" || true)"
      echo "  Installed: ${OLLAMA_VERSION:-none}"
      echo "  Latest:    ${latest:-unavailable}"
      ;;
    service)
      local q_bin
      q_bin="$(_host_shell_quote "$OLLAMA_BIN")"
      _host_manage_service_action "Ollama" "ollama.service" "Ollama LLM Service" "${q_bin} serve"
      ;;
    bench)
      _host_openai_bench "Ollama" "$OLLAMA_URL"
      ;;
  esac
}

ollama_open() {
  _host_run_options_page \
    --name "Ollama" \
    --unit "ollama.service" \
    --refresh "_ollama_refresh" \
    --bin-var "OLLAMA_BIN" \
    --ver-var "OLLAMA_VERSION" \
    --docker-var "OLLAMA_DOCKER" \
    --url "$OLLAMA_URL" \
    --is-running "_ollama_running" \
    --dispatch "_ollama_dispatch"
}
