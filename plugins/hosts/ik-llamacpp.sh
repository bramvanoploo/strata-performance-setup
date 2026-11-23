#!/usr/bin/env bash
# PLUGIN_ID: ik-llamacpp
# PLUGIN_NAME: ik_llama.cpp
# PLUGIN_DESC: Install, update, manage service, and benchmark ik_llama.cpp (CPU/hybrid MoE)
# PLUGIN_PLATFORMS: all

_IK_LLAMACPP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_IK_LLAMACPP_DIR}/_common.sh" ]] && source "${_IK_LLAMACPP_DIR}/_common.sh"

register_host_plugin \
  --id "ik-llamacpp" \
  --name "ik_llama.cpp" \
  --description "Install, update, manage service, and benchmark ik_llama.cpp (CPU/hybrid MoE)" \
  --platforms "all" \
  --caps "install,service,bench,stats" \
  --url "https://github.com/ikawrakow/ik_llama.cpp"

IK_LLAMACPP_BIN=""
IK_LLAMACPP_BENCH_BIN=""
IK_LLAMACPP_VERSION=""
IK_LLAMACPP_DOCKER=""
IK_LLAMACPP_SOURCE="none"
IK_LLAMACPP_PORT="${IK_LLAMACPP_PORT:-8082}"
IK_LLAMACPP_URL="http://127.0.0.1:${IK_LLAMACPP_PORT}"

_ik_llamacpp_prefix() {
  echo "${TARGET_HOME:-$HOME}/.local/share/strata-hosts/ik-llamacpp"
}

_ik_llamacpp_refresh() {
  local pfx
  pfx="$(_ik_llamacpp_prefix)"
  IK_LLAMACPP_BIN=""
  IK_LLAMACPP_BENCH_BIN=""
  if [[ -x "${pfx}/build/bin/llama-server" ]]; then
    IK_LLAMACPP_BIN="${pfx}/build/bin/llama-server"
    [[ -x "${pfx}/build/bin/llama-bench" ]] && IK_LLAMACPP_BENCH_BIN="${pfx}/build/bin/llama-bench"
  else
    IK_LLAMACPP_BIN="$(_host_find_bin ik-llama-server || true)"
    IK_LLAMACPP_BENCH_BIN="$(_host_find_bin ik-llama-bench || true)"
  fi
  IK_LLAMACPP_VERSION=""
  if [[ -n "$IK_LLAMACPP_BIN" ]]; then
    if [[ -d "${pfx}/src/.git" ]]; then
      IK_LLAMACPP_VERSION="$(run_as_user_exec git -C "${pfx}/src" rev-parse --short HEAD 2>/dev/null || echo "installed")"
    else
      IK_LLAMACPP_VERSION="$(run_as_user_exec "$IK_LLAMACPP_BIN" --version 2>&1 | awk '/version:/ {print $2; exit}' || true)"
      [[ -z "$IK_LLAMACPP_VERSION" ]] && IK_LLAMACPP_VERSION="installed"
    fi
  fi
  IK_LLAMACPP_DOCKER=""
  if [[ -z "$IK_LLAMACPP_BIN" ]]; then
    IK_LLAMACPP_DOCKER="$(_host_find_docker 'ik[_-]?llama' || true)"
  fi
  IK_LLAMACPP_SOURCE="none"
  if [[ -n "$IK_LLAMACPP_BIN" ]]; then
    if [[ "$IK_LLAMACPP_BIN" == "${pfx}/"* ]]; then
      IK_LLAMACPP_SOURCE="installer"
    else
      IK_LLAMACPP_SOURCE="manual"
    fi
  fi
  HOST_INSTALL_SOURCE[ik-llamacpp]="$IK_LLAMACPP_SOURCE"
  IK_LLAMACPP_URL="$(_host_detect_url "http://127.0.0.1:${IK_LLAMACPP_PORT}" 'ik-llamacpp/build/bin/llama-server|(^|/)ik-llama-server([[:space:]]|$)' "$IK_LLAMACPP_DOCKER" "ik-llamacpp.service")"
}

_ik_llamacpp_running() {
  _host_endpoint_running "${IK_LLAMACPP_URL}/health" 'ik-llamacpp/build/bin/llama-server|(^|/)ik-llama-server([[:space:]]|$)' "$IK_LLAMACPP_DOCKER" "ik-llamacpp.service"
}

ik-llamacpp_init() {
  _ik_llamacpp_refresh
}

ik-llamacpp_menu_row() {
  local running=false
  _ik_llamacpp_running && running=true
  _host_std_menu_row "IK-LLAMA" "ik_llama.cpp" "${IK_LLAMACPP_BIN:+$IK_LLAMACPP_VERSION}" "$IK_LLAMACPP_DOCKER" "$running" "${1:-false}"
}

ik-llamacpp_check_summary() {
  local running=false
  _ik_llamacpp_running && running=true
  _host_std_check_summary "ik_llama.cpp" "${IK_LLAMACPP_BIN:+$IK_LLAMACPP_VERSION}" "$IK_LLAMACPP_URL" "$IK_LLAMACPP_DOCKER" "$running" "$IK_LLAMACPP_BIN"
}

ik-llamacpp_live_stats() {
  local running=false
  _ik_llamacpp_running && running=true
  _host_std_live_stats "ik_llama" "$IK_LLAMACPP_BIN" "$IK_LLAMACPP_URL" "$running"
}

ik-llamacpp_table_status() {
  local running=false
  _ik_llamacpp_running && running=true
  _host_std_table_status "$IK_LLAMACPP_BIN" "$IK_LLAMACPP_DOCKER" "$running" "ik-llamacpp.service"
}

ik-llamacpp_check_update() {
  HOST_UPDATE_AVAIL[ik-llamacpp]="false"
  HOST_UPDATE_LATEST[ik-llamacpp]=""
}

ik-llamacpp_update() {
  _ik_llamacpp_dispatch update
}

_ik_llamacpp_install_or_update() {
  if ! command -v git >/dev/null 2>&1 || ! command -v cmake >/dev/null 2>&1; then
    echo -e "${C_RED}git and cmake are required to build ik_llama.cpp from source.${C_RESET}"
    return 1
  fi
  local pfx src_dir bld_dir
  pfx="$(_ik_llamacpp_prefix)"
  src_dir="${pfx}/src"
  bld_dir="${pfx}/build"
  run_as_user_exec mkdir -p "$pfx" "${TARGET_HOME:-$HOME}/.local/bin"
  if [[ -d "${src_dir}/.git" ]]; then
    run_as_user_exec git -C "$src_dir" pull --ff-only || return 1
  else
    run_as_user_exec git clone --depth 1 https://github.com/ikawrakow/ik_llama.cpp.git "$src_dir" || return 1
  fi
  local -a cmake_args=(-B "$bld_dir" -S "$src_dir" -DCMAKE_BUILD_TYPE=Release)
  if [[ "$HAS_NVIDIA" == true ]] && command -v nvcc >/dev/null 2>&1; then
    cmake_args+=(-DGGML_CUDA=ON)
  elif [[ "$HAS_AMD" == true ]] && command -v hipcc >/dev/null 2>&1; then
    cmake_args+=(-DGGML_HIP=ON)
  elif [[ "$IS_MACOS" == true && "$IS_APPLE_SILICON" == true ]]; then
    cmake_args+=(-DGGML_METAL=ON)
  fi
  run_as_user_exec cmake "${cmake_args[@]}" || return 1
  run_as_user_exec cmake --build "$bld_dir" --config Release -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)" --target llama-server llama-bench || return 1
  if [[ -x "${bld_dir}/bin/llama-server" ]]; then
    run_as_user_exec ln -sf "${bld_dir}/bin/llama-server" "${TARGET_HOME:-$HOME}/.local/bin/ik-llama-server"
  fi
  if [[ -x "${bld_dir}/bin/llama-bench" ]]; then
    run_as_user_exec ln -sf "${bld_dir}/bin/llama-bench" "${TARGET_HOME:-$HOME}/.local/bin/ik-llama-bench"
  fi
  _ik_llamacpp_refresh
}

_ik_llamacpp_dispatch() {
  case "$1" in
    install|update)
      _ik_llamacpp_install_or_update
      _host_clear_update_cache "ik-llamacpp"
      ;;
    latest)
      echo "  Installed commit: ${IK_LLAMACPP_VERSION:-none}"
      echo "  Upstream repo:    https://github.com/ikawrakow/ik_llama.cpp"
      ;;
    service)
      local model_path=""
      if ! service_installed "ik-llamacpp.service"; then
        read -r -p "Path to GGUF model file: " model_path
      fi
      if service_installed "ik-llamacpp.service" || [[ -n "$model_path" ]]; then
        local q_bin q_model
        q_bin="$(_host_shell_quote "$IK_LLAMACPP_BIN")"
        q_model="$(_host_shell_quote "$model_path")"
        _host_manage_service_action "ik_llama.cpp" "ik-llamacpp.service" "ik_llama.cpp Inference Server" \
          "${q_bin} -m ${q_model} --host 0.0.0.0 --port ${IK_LLAMACPP_PORT}"
      fi
      ;;
    bench)
      if _ik_llamacpp_running; then
        _host_openai_bench "ik_llama.cpp" "$IK_LLAMACPP_URL"
      elif [[ -n "$IK_LLAMACPP_BENCH_BIN" ]]; then
        local gpath=""
        read -r -p "Path to GGUF model for ik-llama-bench: " gpath
        [[ -n "$gpath" ]] && run_as_user_exec "$IK_LLAMACPP_BENCH_BIN" -m "$gpath"
      else
        echo -e "${C_YELLOW}Start ik-llama-server or install ik_llama.cpp first.${C_RESET}"
      fi
      ;;
    uninstall)
      _host_standard_uninstall "ik-llamacpp" "ik_llama.cpp" "ik-llamacpp.service" "$IK_LLAMACPP_BIN" "$IK_LLAMACPP_SOURCE" "ik-llamacpp" \
        "${TARGET_HOME:-$HOME}/.local/bin/ik-llama-server" "${TARGET_HOME:-$HOME}/.local/bin/ik-llama-bench"
      _ik_llamacpp_refresh
      _host_clear_update_cache "ik-llamacpp"
      ;;
  esac
}

ik-llamacpp_open() {
  _host_run_options_page \
    --name "ik_llama.cpp" \
    --unit "ik-llamacpp.service" \
    --refresh "_ik_llamacpp_refresh" \
    --bin-var "IK_LLAMACPP_BIN" \
    --ver-var "IK_LLAMACPP_VERSION" \
    --docker-var "IK_LLAMACPP_DOCKER" \
    --source-var "IK_LLAMACPP_SOURCE" \
    --url "$IK_LLAMACPP_URL" \
    --url-var "IK_LLAMACPP_URL" \
    --is-running "_ik_llamacpp_running" \
    --dispatch "_ik_llamacpp_dispatch"
}
