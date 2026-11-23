#!/usr/bin/env bash
# PLUGIN_ID: sglang
# PLUGIN_NAME: SGLang
# PLUGIN_DESC: Install, update, manage service, and benchmark SGLang inference server
# PLUGIN_PLATFORMS: linux

_SGLANG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_SGLANG_DIR}/_common.sh" ]] && source "${_SGLANG_DIR}/_common.sh"

register_host_plugin \
  --id "sglang" \
  --name "SGLang" \
  --description "Install, update, manage service, and benchmark SGLang inference server" \
  --platforms "linux"

SGLANG_PY=""
SGLANG_VERSION=""
SGLANG_DOCKER=""
SGLANG_SOURCE="none"
SGLANG_PORT="${SGLANG_PORT:-30000}"
SGLANG_URL="http://127.0.0.1:${SGLANG_PORT}"

_sglang_refresh() {
  local vdir
  vdir="$(_host_venv_dir "sglang")"
  SGLANG_PY=""
  SGLANG_VERSION=""
  if [[ -x "${vdir}/bin/python3" ]]; then
    SGLANG_PY="${vdir}/bin/python3"
    SGLANG_VERSION="$(_host_venv_pkg_version "sglang" "sglang" || true)"
  elif has_working_python3 && python3 -c 'import sglang' 2>/dev/null; then
    SGLANG_PY="$(command -v python3)"
    SGLANG_VERSION="$(_host_venv_pkg_version "sglang" "sglang" || echo "installed")"
  fi
  SGLANG_DOCKER=""
  if [[ -z "$SGLANG_VERSION" ]]; then
    SGLANG_DOCKER="$(_host_find_docker 'sglang' || true)"
  fi
  SGLANG_SOURCE="$(_host_detect_install_source "sglang" "$SGLANG_PY" "sglang" false)"
}

_sglang_running() {
  _host_http_ok "${SGLANG_URL}/health" 1
}

sglang_init() {
  _sglang_refresh
}

sglang_menu_row() {
  local running=false
  _sglang_running && running=true
  _host_std_menu_row "SGLANG" "SGLang" "$SGLANG_VERSION" "$SGLANG_DOCKER" "$running" "${1:-false}"
}

sglang_check_summary() {
  local running=false
  _sglang_running && running=true
  _host_std_check_summary "SGLang" "$SGLANG_VERSION" "$SGLANG_URL" "$SGLANG_DOCKER" "$running"
}

sglang_hw_warnings() {
  if [[ "$HAS_NVIDIA" != true && "$HAS_AMD" != true && "$HAS_INTEL_GPU" != true ]]; then
    echo -e "  ${C_YELLOW}[SGLang]${C_RESET} No discrete GPU detected; SGLang typically requires NVIDIA/AMD GPUs."
  fi
}

sglang_live_stats() {
  local running=false
  _sglang_running && running=true
  _host_std_live_stats "SGLang" "$SGLANG_VERSION" "$SGLANG_URL" "$running"
}

sglang_table_status() {
  local running=false
  _sglang_running && running=true
  _host_std_table_status "$SGLANG_VERSION" "$SGLANG_DOCKER" "$running" "sglang.service"
}

sglang_check_update() {
  [[ -n "$SGLANG_VERSION" ]] && _host_check_update_by_source "sglang" "$SGLANG_SOURCE" "$SGLANG_VERSION" "sglang" "sgl-project/sglang" "sglang"
}

sglang_update() {
  _sglang_dispatch update
}

_sglang_dispatch() {
  case "$1" in
    install|update)
      local upgrade=false
      [[ -n "$SGLANG_VERSION" ]] && upgrade=true
      _host_venv_install_or_upgrade "sglang" "sglang[all]" "$upgrade"
      _sglang_refresh
      _host_clear_update_cache "sglang"
      ;;
    latest)
      local latest
      latest="$(_host_github_latest_tag "sgl-project/sglang" || true)"
      echo "  Installed: ${SGLANG_VERSION:-none}"
      echo "  Latest:    ${latest:-unavailable}"
      ;;
    service)
      local model_id=""
      if ! service_installed "sglang.service"; then
        read -r -p "HuggingFace model ID or local path: " model_id
      fi
      if service_installed "sglang.service" || [[ -n "$model_id" ]]; then
        local q_py q_model
        q_py="$(_host_shell_quote "$SGLANG_PY")"
        q_model="$(_host_shell_quote "$model_id")"
        _host_manage_service_action "SGLang" "sglang.service" "SGLang Inference Server" \
          "${q_py} -m sglang.launch_server --model-path ${q_model} --host 0.0.0.0 --port ${SGLANG_PORT}"
      fi
      ;;
    bench)
      _host_openai_bench "SGLang" "$SGLANG_URL"
      ;;
  esac
}

sglang_open() {
  _host_run_options_page \
    --name "SGLang" \
    --unit "sglang.service" \
    --refresh "_sglang_refresh" \
    --bin-var "SGLANG_PY" \
    --ver-var "SGLANG_VERSION" \
    --docker-var "SGLANG_DOCKER" \
    --source-var "SGLANG_SOURCE" \
    --url "$SGLANG_URL" \
    --is-running "_sglang_running" \
    --dispatch "_sglang_dispatch"
}
