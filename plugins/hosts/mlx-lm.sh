#!/usr/bin/env bash
# PLUGIN_ID: mlx-lm
# PLUGIN_NAME: MLX LM
# PLUGIN_DESC: Install, update, manage service, and benchmark MLX LM on Apple Silicon
# PLUGIN_PLATFORMS: macos-arm64

_MLX_LM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_MLX_LM_DIR}/_common.sh" ]] && source "${_MLX_LM_DIR}/_common.sh"

register_host_plugin \
  --id "mlx-lm" \
  --name "MLX LM" \
  --description "Install, update, manage service, and benchmark MLX LM on Apple Silicon" \
  --platforms "macos-arm64" \
  --url "https://github.com/ml-explore/mlx-lm"

MLX_LM_BIN=""
MLX_LM_VERSION=""
MLX_LM_SOURCE="none"
MLX_LM_PORT="${MLX_LM_PORT:-8080}"
MLX_LM_URL="http://127.0.0.1:${MLX_LM_PORT}"

_mlx_lm_refresh() {
  MLX_LM_BIN="$(_host_venv_bin "mlx-lm" "mlx_lm.server" || true)"
  MLX_LM_VERSION=""
  if [[ -n "$MLX_LM_BIN" ]]; then
    MLX_LM_VERSION="$(_host_venv_pkg_version "mlx-lm" "mlx-lm" || true)"
    [[ -z "$MLX_LM_VERSION" ]] && MLX_LM_VERSION="installed"
  fi
  MLX_LM_SOURCE="$(_host_detect_install_source "mlx-lm" "$MLX_LM_BIN" "mlx-lm" false)"
  MLX_LM_URL="$(_host_detect_url "http://127.0.0.1:${MLX_LM_PORT}" 'mlx_lm\.server' "" "mlx-lm.service")"
}

_mlx_lm_running() {
  _host_endpoint_running "${MLX_LM_URL}/v1/models" 'mlx_lm\.server' "" "mlx-lm.service"
}

mlx-lm_init() {
  _mlx_lm_refresh
}

mlx-lm_menu_row() {
  local running=false
  _mlx_lm_running && running=true
  _host_std_menu_row "MLX-LM" "MLX LM" "${MLX_LM_BIN:+$MLX_LM_VERSION}" "" "$running" "${1:-false}"
}

mlx-lm_check_summary() {
  local running=false
  _mlx_lm_running && running=true
  _host_std_check_summary "MLX LM" "${MLX_LM_BIN:+$MLX_LM_VERSION}" "$MLX_LM_URL" "" "$running" "$MLX_LM_BIN"
}

mlx-lm_live_stats() {
  local running=false
  _mlx_lm_running && running=true
  _host_std_live_stats "MLX LM" "$MLX_LM_BIN" "$MLX_LM_URL" "$running"
}

mlx-lm_table_status() {
  local running=false
  _mlx_lm_running && running=true
  _host_std_table_status "$MLX_LM_BIN" "" "$running" "mlx-lm.service"
}

mlx-lm_check_update() {
  [[ -n "$MLX_LM_BIN" ]] && _host_check_update_by_source "mlx-lm" "$MLX_LM_SOURCE" "$MLX_LM_VERSION" "mlx-lm" "ml-explore/mlx-lm" "mlx-lm"
}

mlx-lm_update() {
  _mlx_lm_dispatch update
}

_mlx_lm_dispatch() {
  case "$1" in
    install|update)
      local upgrade=false
      [[ -n "$MLX_LM_BIN" ]] && upgrade=true
      _host_venv_install_or_upgrade "mlx-lm" "mlx-lm" "$upgrade"
      _mlx_lm_refresh
      _host_clear_update_cache "mlx-lm"
      ;;
    latest)
      local latest
      latest="$(_host_github_latest_tag "ml-explore/mlx-lm" || true)"
      echo "  Installed: ${MLX_LM_VERSION:-none}"
      echo "  Latest:    ${latest:-unavailable}"
      ;;
    service)
      local model_id=""
      if ! service_installed "mlx-lm.service"; then
        read -r -p "MLX HuggingFace model ID or local path: " model_id
      fi
      if service_installed "mlx-lm.service" || [[ -n "$model_id" ]]; then
        local q_bin q_model
        q_bin="$(_host_shell_quote "$MLX_LM_BIN")"
        q_model="$(_host_shell_quote "$model_id")"
        _host_manage_service_action "MLX LM" "mlx-lm.service" "MLX LM Server" \
          "${q_bin} --model ${q_model} --host 127.0.0.1 --port ${MLX_LM_PORT}"
      fi
      ;;
    bench)
      if _mlx_lm_running; then
        _host_openai_bench "MLX LM" "$MLX_LM_URL"
      else
        local bench_bin
        bench_bin="$(_host_venv_bin "mlx-lm" "mlx_lm.benchmark" || true)"
        if [[ -n "$bench_bin" ]]; then
          local bmodel=""
          read -r -p "MLX model ID or path for mlx_lm.benchmark: " bmodel
          [[ -n "$bmodel" ]] && run_as_user_exec "$bench_bin" --model "$bmodel"
        else
          echo -e "${C_YELLOW}Start mlx_lm.server or install mlx-lm first.${C_RESET}"
        fi
      fi
      ;;
    uninstall)
      _host_standard_uninstall "mlx-lm" "MLX LM" "mlx-lm.service" "$MLX_LM_BIN" "$MLX_LM_SOURCE" "mlx-lm"
      _mlx_lm_refresh
      _host_clear_update_cache "mlx-lm"
      ;;
  esac
}

mlx-lm_open() {
  _host_run_options_page \
    --name "MLX LM" \
    --unit "mlx-lm.service" \
    --refresh "_mlx_lm_refresh" \
    --bin-var "MLX_LM_BIN" \
    --ver-var "MLX_LM_VERSION" \
    --source-var "MLX_LM_SOURCE" \
    --url "$MLX_LM_URL" \
    --url-var "MLX_LM_URL" \
    --is-running "_mlx_lm_running" \
    --dispatch "_mlx_lm_dispatch"
}
