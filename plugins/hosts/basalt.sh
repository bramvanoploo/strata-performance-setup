#!/usr/bin/env bash
# PLUGIN_ID: basalt
# PLUGIN_NAME: Basalt
# PLUGIN_DESC: Install, update, manage service, and benchmark Basalt (NVIDIA Blackwell Strata fork)
# PLUGIN_PLATFORMS: linux-nvidia

_BASALT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_BASALT_DIR}/_common.sh" ]] && source "${_BASALT_DIR}/_common.sh"

register_host_plugin \
  --id "basalt" \
  --name "Basalt" \
  --description "Install, update, manage service, and benchmark Basalt (NVIDIA Blackwell Strata fork)" \
  --platforms "linux-nvidia" \
  --url "https://github.com/jesdga95/basalt"

BASALT_BIN=""
BASALT_VERSION=""
BASALT_DOCKER=""
BASALT_SOURCE="none"
BASALT_PORT="${BASALT_PORT:-8080}"
BASALT_URL="http://127.0.0.1:${BASALT_PORT}"

_basalt_prefix() {
  echo "${TARGET_HOME:-$HOME}/.local/share/strata-hosts/basalt"
}

_basalt_refresh() {
  local pfx
  pfx="$(_basalt_prefix)"
  BASALT_BIN=""
  BASALT_VERSION=""
  if [[ -x "${pfx}/bin/basalt" ]]; then
    BASALT_BIN="${pfx}/bin/basalt"
  elif [[ -x "${pfx}/build/bin/basalt" ]]; then
    BASALT_BIN="${pfx}/build/bin/basalt"
  else
    BASALT_BIN="$(_host_find_bin basalt || true)"
  fi
  if [[ -n "$BASALT_BIN" ]]; then
    if [[ -f "${pfx}/.version" ]]; then
      BASALT_VERSION="$(cat "${pfx}/.version" 2>/dev/null | tr -d '[:space:]')"
    elif [[ -d "${pfx}/src/.git" ]]; then
      BASALT_VERSION="$(run_as_user_exec git -C "${pfx}/src" describe --tags --abbrev=0 2>/dev/null || run_as_user_exec git -C "${pfx}/src" rev-parse --short HEAD 2>/dev/null || echo "installed")"
    else
      BASALT_VERSION="$(run_as_user_exec "$BASALT_BIN" --version 2>&1 | head -n 1 | grep -oE 'v?[0-9]+(\.[0-9]+)+' | head -n 1 || true)"
    fi
    [[ -z "$BASALT_VERSION" ]] && BASALT_VERSION="installed"
  fi
  BASALT_DOCKER=""
  if [[ -z "$BASALT_BIN" ]]; then
    BASALT_DOCKER="$(_host_find_docker 'basalt' || true)"
  fi
  BASALT_SOURCE="none"
  if [[ -n "$BASALT_BIN" ]]; then
    if [[ "$BASALT_BIN" == "${pfx}/"* ]]; then
      BASALT_SOURCE="installer"
    else
      BASALT_SOURCE="manual"
    fi
  fi
  HOST_INSTALL_SOURCE[basalt]="$BASALT_SOURCE"
  BASALT_URL="$(_host_detect_url "http://127.0.0.1:${BASALT_PORT}" 'hosts/basalt/(build/)?bin/basalt|(^|/)basalt[[:space:]]+serve' "$BASALT_DOCKER" "basalt.service")"
}

_basalt_running() {
  _host_endpoint_running "${BASALT_URL}/v1/models" 'hosts/basalt/(build/)?bin/basalt|(^|/)basalt[[:space:]]+serve' "$BASALT_DOCKER" "basalt.service"
}

basalt_init() {
  _basalt_refresh
}

basalt_menu_row() {
  local running=false
  _basalt_running && running=true
  _host_std_menu_row "BASALT" "Basalt" "${BASALT_BIN:+$BASALT_VERSION}" "$BASALT_DOCKER" "$running" "${1:-false}"
}

basalt_check_summary() {
  local running=false
  _basalt_running && running=true
  _host_std_check_summary "Basalt" "${BASALT_BIN:+$BASALT_VERSION}" "$BASALT_URL" "$BASALT_DOCKER" "$running" "$BASALT_BIN"
}

basalt_hw_warnings() {
  if [[ "$HAS_NVIDIA" == true ]] && command -v nvidia-smi >/dev/null 2>&1; then
    local cc
    cc="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
    if [[ -n "$cc" && "$cc" != 12.* ]]; then
      echo -e "  ${C_YELLOW}[Basalt]${C_RESET} Detected NVIDIA compute capability ${cc}; Basalt targets Blackwell (sm_120). For Ada/Ampere (sm_89/sm_86), see Adamant."
    fi
  fi
}

basalt_live_stats() {
  local running=false
  _basalt_running && running=true
  _host_std_live_stats "Basalt" "$BASALT_BIN" "$BASALT_URL" "$running"
}

basalt_table_status() {
  local running=false
  _basalt_running && running=true
  _host_std_table_status "$BASALT_BIN" "$BASALT_DOCKER" "$running" "basalt.service"
}

basalt_check_update() {
  [[ -n "$BASALT_BIN" ]] && _host_check_update_by_source "basalt" "$BASALT_SOURCE" "$BASALT_VERSION" "basalt" "jesdga95/basalt"
}

basalt_update() {
  _basalt_dispatch update
}

_basalt_install_or_update() {
  local pfx arch latest tag_url tmp_tgz
  pfx="$(_basalt_prefix)"
  arch="$(uname -m)"
  run_as_user_exec mkdir -p "$pfx" "${TARGET_HOME:-$HOME}/.local/bin"

  if [[ "$arch" == "x86_64" || "$arch" == "amd64" ]] && command -v curl >/dev/null 2>&1; then
    latest="$(_host_github_latest_tag "jesdga95/basalt" || true)"
    if [[ -n "$latest" ]]; then
      tag_url="https://github.com/jesdga95/basalt/releases/download/${latest}/basalt-${latest}-linux-x64.tar.gz"
      tmp_tgz="${pfx}/basalt-${latest}.tar.gz"
      if run_as_user_exec curl -fsSL -o "$tmp_tgz" "$tag_url"; then
        run_as_user_exec mkdir -p "${pfx}/bin"
        if run_as_user_exec tar -xzf "$tmp_tgz" -C "${pfx}/bin" --strip-components=1 2>/dev/null || run_as_user_exec tar -xzf "$tmp_tgz" -C "${pfx}/bin"; then
          rm -f "$tmp_tgz"
          if [[ -x "${pfx}/bin/bin/basalt" ]]; then
            mv "${pfx}/bin/bin/"* "${pfx}/bin/" 2>/dev/null || true
          fi
          if [[ -x "${pfx}/bin/basalt" ]]; then
            printf '%s\n' "$latest" > "${pfx}/.version"
            run_as_user_exec ln -sf "${pfx}/bin/basalt" "${TARGET_HOME:-$HOME}/.local/bin/basalt"
            _basalt_refresh
            return 0
          fi
        fi
        rm -f "$tmp_tgz"
      fi
    fi
  fi

  if ! command -v git >/dev/null 2>&1 || ! command -v cmake >/dev/null 2>&1; then
    echo -e "${C_RED}git and cmake are required to build Basalt from source.${C_RESET}"
    return 1
  fi
  local src_dir="${pfx}/src" bld_dir="${pfx}/build"
  if [[ -d "${src_dir}/.git" ]]; then
    run_as_user_exec git -C "$src_dir" pull --ff-only || return 1
  else
    run_as_user_exec git clone --depth 1 https://github.com/jesdga95/basalt.git "$src_dir" || return 1
  fi
  run_as_user_exec cmake -S "$src_dir" -B "$bld_dir" -DCMAKE_BUILD_TYPE=Release || return 1
  run_as_user_exec cmake --build "$bld_dir" -j"$(nproc 2>/dev/null || echo 4)" || return 1
  if [[ -x "${bld_dir}/bin/basalt" ]]; then
    run_as_user_exec ln -sf "${bld_dir}/bin/basalt" "${TARGET_HOME:-$HOME}/.local/bin/basalt"
  fi
  _basalt_refresh
}

_basalt_dispatch() {
  case "$1" in
    install|update)
      _basalt_install_or_update
      _host_clear_update_cache "basalt"
      ;;
    latest)
      local latest
      latest="$(_host_github_latest_tag "jesdga95/basalt" || true)"
      echo "  Installed: ${BASALT_VERSION:-none}"
      echo "  Latest:    ${latest:-unavailable}"
      ;;
    service)
      local pfx q_bin cmd
      pfx="$(_basalt_prefix)"
      q_bin="$(_host_shell_quote "$BASALT_BIN")"
      cmd="${q_bin} serve --port ${BASALT_PORT}"
      [[ -f "${pfx}/basalt_config.json" ]] && cmd="${q_bin} serve --config $(_host_shell_quote "${pfx}/basalt_config.json")"
      _host_manage_service_action "Basalt" "basalt.service" "Basalt LLM Inference Server" "$cmd" "$pfx"
      ;;
    bench)
      _host_openai_bench "Basalt" "$BASALT_URL"
      ;;
    uninstall)
      _host_standard_uninstall "basalt" "Basalt" "basalt.service" "$BASALT_BIN" "$BASALT_SOURCE" "basalt"
      _basalt_refresh
      _host_clear_update_cache "basalt"
      ;;
  esac
}

basalt_open() {
  _host_run_options_page \
    --name "Basalt" \
    --unit "basalt.service" \
    --refresh "_basalt_refresh" \
    --bin-var "BASALT_BIN" \
    --ver-var "BASALT_VERSION" \
    --docker-var "BASALT_DOCKER" \
    --source-var "BASALT_SOURCE" \
    --url "$BASALT_URL" \
    --url-var "BASALT_URL" \
    --is-running "_basalt_running" \
    --dispatch "_basalt_dispatch"
}
