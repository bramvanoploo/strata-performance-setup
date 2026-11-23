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
  --platforms "linux" \
  --url "https://github.com/sgl-project/sglang"

_host_vp_setup \
  --id "sglang" --tag "SGLANG" --name "SGLang" --bin "python3" --pip-pkg "sglang" \
  --pkg-spec "sglang[all]" --repo "sgl-project/sglang" --port "${SGLANG_PORT:-30000}" \
  --health "/health" --svc-desc "SGLang Inference Server" \
  --model-prompt "HuggingFace model ID or local path" \
  --svc-args "{BIN} -m sglang.launch_server --model-path {MODEL} --host 0.0.0.0 --port {PORT}"

sglang_init() { _host_vp_refresh "sglang"; }
sglang_menu_row() { _host_vp_menu_row "sglang" "${1:-false}"; }
sglang_check_summary() { _host_vp_check_summary "sglang"; }
sglang_live_stats() { _host_vp_live_stats "sglang"; }
sglang_table_status() { _host_vp_table_status "sglang"; }
sglang_check_update() { _host_vp_check_update "sglang"; }
sglang_update() { _host_vp_dispatch "sglang" update; }
sglang_open() { _host_vp_open "sglang"; }

sglang_hw_warnings() {
  if [[ "$HAS_NVIDIA" != true && "$HAS_AMD" != true && "$HAS_INTEL_GPU" != true ]]; then
    echo -e "  ${C_YELLOW}[SGLang]${C_RESET} No discrete GPU detected; SGLang typically requires NVIDIA/AMD GPUs."
  fi
}
