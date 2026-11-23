#!/usr/bin/env bash
# PLUGIN_ID: lemonade
# PLUGIN_NAME: Lemonade
# PLUGIN_DESC: Install, update, manage service, and benchmark AMD Lemonade (Ryzen AI NPU/iGPU)
# PLUGIN_PLATFORMS: linux

_LEMONADE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_LEMONADE_DIR}/_common.sh" ]] && source "${_LEMONADE_DIR}/_common.sh"

register_host_plugin \
  --id "lemonade" \
  --name "Lemonade" \
  --description "Install, update, manage service, and benchmark AMD Lemonade (Ryzen AI NPU/iGPU)" \
  --platforms "linux" \
  --url "https://github.com/lemonade-sdk/lemonade"

_host_vp_setup \
  --id "lemonade" --tag "LEMONADE" --name "Lemonade" \
  --bin "lemonade-server" --pip-pkg "lemonade-sdk" --pkg-spec "lemonade-sdk" \
  --repo "lemonade-sdk/lemonade" --port "${LEMONADE_PORT:-8000}" --health "/api/v1/health /v1/models" \
  --svc-desc "AMD Lemonade LLM Server" \
  --svc-args "{BIN} serve --host 0.0.0.0 --port {PORT}"

lemonade_init() { _host_vp_refresh "lemonade"; }
lemonade_menu_row() { _host_vp_menu_row "lemonade" "${1:-false}"; }
lemonade_check_summary() { _host_vp_check_summary "lemonade"; }
lemonade_live_stats() { _host_vp_live_stats "lemonade"; }
lemonade_table_status() { _host_vp_table_status "lemonade"; }
lemonade_check_update() { _host_vp_check_update "lemonade"; }
lemonade_update() { _host_vp_dispatch "lemonade" update; }
lemonade_open() { _host_vp_open "lemonade"; }

lemonade_hw_warnings() {
  if [[ "$HAS_AMD_NPU" != true && "$HAS_AMD" != true ]]; then
    echo -e "  ${C_YELLOW}[Lemonade]${C_RESET} No AMD Ryzen AI NPU or Radeon GPU detected; Lemonade targets Ryzen AI NPU/iGPU."
  fi
}
