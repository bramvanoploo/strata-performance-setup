#!/usr/bin/env bash
# PLUGIN_ID: vllm
# PLUGIN_NAME: vLLM
# PLUGIN_DESC: Install, update, manage service, and benchmark vLLM inference server
# PLUGIN_PLATFORMS: linux

_VLLM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_VLLM_DIR}/_common.sh" ]] && source "${_VLLM_DIR}/_common.sh"

register_host_plugin \
  --id "vllm" \
  --name "vLLM" \
  --description "Install, update, manage service, and benchmark vLLM inference server" \
  --platforms "linux"

VLLM_BIN=""
VLLM_VERSION=""
VLLM_DOCKER=""
VLLM_SOURCE="none"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_URL="http://127.0.0.1:${VLLM_PORT}"

_vllm_refresh() {
  VLLM_BIN="$(_host_venv_bin "vllm" "vllm" || true)"
  VLLM_VERSION=""
  if [[ -n "$VLLM_BIN" ]]; then
    VLLM_VERSION="$(_host_venv_pkg_version "vllm" "vllm" || true)"
    [[ -z "$VLLM_VERSION" ]] && VLLM_VERSION="installed"
  fi
  VLLM_DOCKER=""
  if [[ -z "$VLLM_BIN" ]]; then
    VLLM_DOCKER="$(_host_find_docker 'vllm' || true)"
  fi
  VLLM_SOURCE="$(_host_detect_install_source "vllm" "$VLLM_BIN" "vllm" false)"
}

_vllm_running() {
  _host_http_ok "${VLLM_URL}/health" 1
}

vllm_init() {
  _vllm_refresh
}

vllm_menu_row() {
  local running=false
  _vllm_running && running=true
  _host_std_menu_row "VLLM" "vLLM" "${VLLM_BIN:+$VLLM_VERSION}" "$VLLM_DOCKER" "$running" "${1:-false}"
}

vllm_check_summary() {
  local running=false
  _vllm_running && running=true
  _host_std_check_summary "vLLM" "${VLLM_BIN:+$VLLM_VERSION}" "$VLLM_URL" "$VLLM_DOCKER" "$running" "$VLLM_BIN"
}

vllm_hw_warnings() {
  if [[ "$HAS_NVIDIA" != true && "$HAS_AMD" != true && "$HAS_INTEL_GPU" != true ]]; then
    echo -e "  ${C_YELLOW}[vLLM]${C_RESET} No discrete GPU detected; vLLM will run in CPU mode if installed."
  fi
}

vllm_live_stats() {
  local running=false
  _vllm_running && running=true
  _host_std_live_stats "vLLM" "$VLLM_BIN" "$VLLM_URL" "$running"
}

vllm_table_status() {
  local running=false
  _vllm_running && running=true
  _host_std_table_status "$VLLM_BIN" "$VLLM_DOCKER" "$running" "vllm.service"
}

vllm_check_update() {
  [[ -n "$VLLM_BIN" ]] && _host_check_update_by_source "vllm" "$VLLM_SOURCE" "$VLLM_VERSION" "vllm" "vllm-project/vllm" "vllm"
}

vllm_update() {
  _vllm_dispatch update
}

_vllm_dispatch() {
  case "$1" in
    install|update)
      local upgrade=false
      [[ -n "$VLLM_BIN" ]] && upgrade=true
      _host_venv_install_or_upgrade "vllm" "vllm" "$upgrade"
      _vllm_refresh
      _host_clear_update_cache "vllm"
      ;;
    latest)
      local latest
      latest="$(_host_github_latest_tag "vllm-project/vllm" || true)"
      echo "  Installed: ${VLLM_VERSION:-none}"
      echo "  Latest:    ${latest:-unavailable}"
      ;;
    service)
      local model_id=""
      if ! service_installed "vllm.service"; then
        read -r -p "HuggingFace model ID or local path: " model_id
      fi
      if service_installed "vllm.service" || [[ -n "$model_id" ]]; then
        local q_bin q_model
        q_bin="$(_host_shell_quote "$VLLM_BIN")"
        q_model="$(_host_shell_quote "$model_id")"
        _host_manage_service_action "vLLM" "vllm.service" "vLLM Inference Server" \
          "${q_bin} serve ${q_model} --host 0.0.0.0 --port ${VLLM_PORT}"
      fi
      ;;
    bench)
      _host_openai_bench "vLLM" "$VLLM_URL"
      ;;
  esac
}

vllm_open() {
  _host_run_options_page \
    --name "vLLM" \
    --unit "vllm.service" \
    --refresh "_vllm_refresh" \
    --bin-var "VLLM_BIN" \
    --ver-var "VLLM_VERSION" \
    --docker-var "VLLM_DOCKER" \
    --source-var "VLLM_SOURCE" \
    --url "$VLLM_URL" \
    --is-running "_vllm_running" \
    --dispatch "_vllm_dispatch"
}
