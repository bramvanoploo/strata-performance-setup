#!/usr/bin/env bash
# PLUGIN_ID: ktransformers
# PLUGIN_NAME: KTransformers
# PLUGIN_DESC: Install, update, manage service, and benchmark KTransformers hybrid MoE server
# PLUGIN_PLATFORMS: linux

_KTRANS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_KTRANS_DIR}/_common.sh" ]] && source "${_KTRANS_DIR}/_common.sh"

register_host_plugin \
  --id "ktransformers" \
  --name "KTransformers" \
  --description "Install, update, manage service, and benchmark KTransformers hybrid MoE server" \
  --platforms "linux"

_host_vp_setup \
  --id "ktransformers" --tag "KTRANS" --name "KTransformers" --live-label "KTrans" \
  --bin "ktransformers" --pip-pkg "ktransformers" --repo "kvcache-ai/ktransformers" \
  --port "${KTRANS_PORT:-10002}" --health "/v1/models" \
  --svc-desc "KTransformers Inference Server" --model-prompt "Model path or HuggingFace ID" \
  --svc-args "{BIN} --model_path {MODEL} --host 0.0.0.0 --port {PORT}"

ktransformers_init() { _host_vp_refresh "ktransformers"; }
ktransformers_menu_row() { _host_vp_menu_row "ktransformers" "${1:-false}"; }
ktransformers_check_summary() { _host_vp_check_summary "ktransformers"; }
ktransformers_live_stats() { _host_vp_live_stats "ktransformers"; }
ktransformers_table_status() { _host_vp_table_status "ktransformers"; }
ktransformers_check_update() { _host_vp_check_update "ktransformers"; }
ktransformers_update() { _host_vp_dispatch "ktransformers" update; }
ktransformers_open() { _host_vp_open "ktransformers"; }
