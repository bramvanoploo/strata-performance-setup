#!/usr/bin/env bash
# PLUGIN_ID: tensorrt-llm
# PLUGIN_NAME: TensorRT-LLM
# PLUGIN_DESC: Install, update, manage service, and benchmark NVIDIA TensorRT-LLM (trtllm-serve)
# PLUGIN_PLATFORMS: linux-nvidia

_TRTLLM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_TRTLLM_DIR}/_common.sh" ]] && source "${_TRTLLM_DIR}/_common.sh"

register_host_plugin \
  --id "tensorrt-llm" \
  --name "TensorRT-LLM" \
  --description "Install, update, manage service, and benchmark NVIDIA TensorRT-LLM (trtllm-serve)" \
  --platforms "linux-nvidia"

_host_vp_setup \
  --id "tensorrt-llm" --tag "TRT-LLM" --name "TensorRT-LLM" --live-label "TRT-LLM" \
  --bin "trtllm-serve" --pip-pkg "tensorrt_llm" --pkg-spec "tensorrt_llm" \
  --repo "NVIDIA/TensorRT-LLM" --port "${TRTLLM_PORT:-8000}" --health "/health /v1/models" \
  --docker-pat "tensorrt[_-]?llm|trtllm|tritonserver" \
  --svc-desc "NVIDIA TensorRT-LLM Server" --model-prompt "HuggingFace model ID or engine dir" \
  --svc-args "{BIN} {MODEL} --host 0.0.0.0 --port {PORT}"

tensorrt-llm_init() { _host_vp_refresh "tensorrt-llm"; }
tensorrt-llm_menu_row() { _host_vp_menu_row "tensorrt-llm" "${1:-false}"; }
tensorrt-llm_check_summary() { _host_vp_check_summary "tensorrt-llm"; }
tensorrt-llm_live_stats() { _host_vp_live_stats "tensorrt-llm"; }
tensorrt-llm_table_status() { _host_vp_table_status "tensorrt-llm"; }
tensorrt-llm_check_update() { _host_vp_check_update "tensorrt-llm"; }
tensorrt-llm_update() { _host_vp_dispatch "tensorrt-llm" update; }
tensorrt-llm_open() { _host_vp_open "tensorrt-llm"; }
