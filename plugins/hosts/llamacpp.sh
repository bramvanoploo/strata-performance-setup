#!/usr/bin/env bash
# PLUGIN_ID: llamacpp
# PLUGIN_NAME: llama.cpp
# PLUGIN_DESC: Install, update, manage service, and benchmark llama.cpp (llama-server)
# PLUGIN_PLATFORMS: all

_LLAMACPP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_LLAMACPP_DIR}/_common.sh" ]] && source "${_LLAMACPP_DIR}/_common.sh"

register_host_plugin \
  --id "llamacpp" \
  --name "llama.cpp" \
  --description "Install, update, manage service, and benchmark llama.cpp (llama-server)" \
  --platforms "all" \
  --url "https://github.com/ggml-org/llama.cpp"

LLAMACPP_BIN=""
LLAMACPP_BENCH_BIN=""
LLAMACPP_VERSION=""
LLAMACPP_DOCKER=""
LLAMACPP_SOURCE="none"
LLAMACPP_PORT="${LLAMACPP_PORT:-8080}"
LLAMACPP_URL="http://127.0.0.1:${LLAMACPP_PORT}"

_llamacpp_refresh() {
  LLAMACPP_BIN="$(_host_find_bin llama-server || true)"
  LLAMACPP_BENCH_BIN="$(_host_find_bin llama-bench || true)"
  LLAMACPP_VERSION=""
  if [[ -n "$LLAMACPP_BIN" ]]; then
    LLAMACPP_VERSION="$(run_as_user_exec "$LLAMACPP_BIN" --version 2>&1 | awk '/version:/ {print $2; exit}' || true)"
    [[ -z "$LLAMACPP_VERSION" ]] && LLAMACPP_VERSION="installed"
  fi
  LLAMACPP_DOCKER=""
  if [[ -z "$LLAMACPP_BIN" ]]; then
    LLAMACPP_DOCKER="$(_host_find_docker 'llama[.]?cpp|llama-server' || true)"
  fi
  LLAMACPP_SOURCE="$(_host_detect_install_source "llamacpp" "$LLAMACPP_BIN" "llama.cpp" false)"
  LLAMACPP_URL="$(_host_detect_url "http://127.0.0.1:${LLAMACPP_PORT}" '(^|/)llama-server([[:space:]]|$)' "$LLAMACPP_DOCKER" "llamacpp.service")"
}

_llamacpp_running() {
  _host_endpoint_running "${LLAMACPP_URL}/health" '(^|/)llama-server([[:space:]]|$)' "$LLAMACPP_DOCKER" "llamacpp.service"
}

llamacpp_init() {
  _llamacpp_refresh
}

llamacpp_menu_row() {
  local running=false
  _llamacpp_running && running=true
  _host_std_menu_row "LLAMACPP" "llama.cpp" "${LLAMACPP_BIN:+$LLAMACPP_VERSION}" "$LLAMACPP_DOCKER" "$running" "${1:-false}"
}

llamacpp_check_summary() {
  local running=false
  _llamacpp_running && running=true
  _host_std_check_summary "llama.cpp" "${LLAMACPP_BIN:+$LLAMACPP_VERSION}" "$LLAMACPP_URL" "$LLAMACPP_DOCKER" "$running" "$LLAMACPP_BIN"
}

llamacpp_live_stats() {
  local running=false
  _llamacpp_running && running=true
  _host_std_live_stats "llama.cpp" "$LLAMACPP_BIN" "$LLAMACPP_URL" "$running"
}

llamacpp_table_status() {
  local running=false
  _llamacpp_running && running=true
  _host_std_table_status "$LLAMACPP_BIN" "$LLAMACPP_DOCKER" "$running" "llamacpp.service"
}

llamacpp_check_update() {
  [[ -n "$LLAMACPP_BIN" ]] && _host_check_update_by_source "llamacpp" "$LLAMACPP_SOURCE" "$LLAMACPP_VERSION" "llama.cpp" "ggml-org/llama.cpp"
}

llamacpp_update() {
  _llamacpp_dispatch update
}

_llamacpp_install_or_update() {
  if [[ -n "$LLAMACPP_BIN" ]]; then
    case "$LLAMACPP_SOURCE" in
      brew)   run_as_user_exec brew upgrade llama.cpp || true ;;
      distro) pkg_install llama.cpp ;;
      aur)    aur_install llama.cpp ;;
      *)
        echo -e "${C_YELLOW}llama.cpp at ${LLAMACPP_BIN} is not managed by a package manager; update it from its original build source.${C_RESET}"
        return 1
        ;;
    esac
  elif [[ "$IS_MACOS" == true ]] && command -v brew >/dev/null 2>&1; then
    run_as_user_exec brew install llama.cpp
  elif pkg_available repo llama.cpp 2>/dev/null; then
    pkg_install llama.cpp
  elif [[ "$DISTRO_FAMILY" == "arch" ]] && pkg_available aur llama.cpp 2>/dev/null; then
    aur_install llama.cpp
  else
    echo -e "${C_YELLOW}No repo/AUR package 'llama.cpp' found. Install via Homebrew, your distro/AUR, or build from https://github.com/ggml-org/llama.cpp${C_RESET}"
    return 1
  fi
  _llamacpp_refresh
}

_llamacpp_dispatch() {
  case "$1" in
    install|update)
      _llamacpp_install_or_update
      _host_clear_update_cache "llamacpp"
      ;;
    latest)
      local latest
      latest="$(_host_github_latest_tag "ggml-org/llama.cpp" || true)"
      echo "  Installed: ${LLAMACPP_VERSION:-none}"
      echo "  Latest:    ${latest:-unavailable}"
      ;;
    service)
      local model_path=""
      if ! service_installed "llamacpp.service"; then
        read -r -p "Path to GGUF model file: " model_path
      fi
      if service_installed "llamacpp.service" || [[ -n "$model_path" ]]; then
        local q_bin q_model
        q_bin="$(_host_shell_quote "$LLAMACPP_BIN")"
        q_model="$(_host_shell_quote "$model_path")"
        _host_manage_service_action "llama.cpp" "llamacpp.service" "llama.cpp Server" \
          "${q_bin} -m ${q_model} --host 0.0.0.0 --port ${LLAMACPP_PORT}"
      fi
      ;;
    bench)
      if _llamacpp_running; then
        _host_openai_bench "llama.cpp" "$LLAMACPP_URL"
      elif [[ -n "$LLAMACPP_BENCH_BIN" ]]; then
        local gpath=""
        read -r -p "Path to GGUF model for llama-bench: " gpath
        [[ -n "$gpath" ]] && run_as_user_exec "$LLAMACPP_BENCH_BIN" -m "$gpath"
      else
        echo -e "${C_YELLOW}Start llama-server or install llama-bench first.${C_RESET}"
      fi
      ;;
    uninstall)
      local -a _ll_extra=()
      [[ "$LLAMACPP_SOURCE" == "manual" && -n "$LLAMACPP_BENCH_BIN" ]] && _ll_extra+=("$LLAMACPP_BENCH_BIN")
      _host_standard_uninstall "llamacpp" "llama.cpp" "llamacpp.service" "$LLAMACPP_BIN" "$LLAMACPP_SOURCE" "llama.cpp" "${_ll_extra[@]}"
      _llamacpp_refresh
      _host_clear_update_cache "llamacpp"
      ;;
  esac
}

llamacpp_open() {
  _host_run_options_page \
    --name "llama.cpp" \
    --unit "llamacpp.service" \
    --refresh "_llamacpp_refresh" \
    --bin-var "LLAMACPP_BIN" \
    --ver-var "LLAMACPP_VERSION" \
    --docker-var "LLAMACPP_DOCKER" \
    --source-var "LLAMACPP_SOURCE" \
    --url "$LLAMACPP_URL" \
    --url-var "LLAMACPP_URL" \
    --is-running "_llamacpp_running" \
    --dispatch "_llamacpp_dispatch"
}
