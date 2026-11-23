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

_host_vp_setup \
  --id "vllm" --tag "VLLM" --name "vLLM" --bin "vllm" --pip-pkg "vllm" \
  --repo "vllm-project/vllm" --port "${VLLM_PORT:-8000}" --health "/health" \
  --svc-desc "vLLM Inference Server" --model-prompt "HuggingFace model ID or local path" \
  --svc-args "{BIN} serve {MODEL} --host 0.0.0.0 --port {PORT}"

vllm_init() { _host_vp_refresh "vllm"; }
vllm_menu_row() { _host_vp_menu_row "vllm" "${1:-false}"; }
vllm_check_summary() { _host_vp_check_summary "vllm"; }
vllm_live_stats() { _host_vp_live_stats "vllm"; }
vllm_table_status() { _host_vp_table_status "vllm"; }
vllm_check_update() { _host_vp_check_update "vllm"; }
vllm_update() { _host_vp_dispatch "vllm" update; }
vllm_open() { _host_vp_open "vllm"; }

vllm_hw_warnings() {
  if [[ "$HAS_NVIDIA" != true && "$HAS_AMD" != true && "$HAS_INTEL_GPU" != true ]]; then
    echo -e "  ${C_YELLOW}[vLLM]${C_RESET} No discrete GPU detected; vLLM will run in CPU mode if installed."
  fi
}
