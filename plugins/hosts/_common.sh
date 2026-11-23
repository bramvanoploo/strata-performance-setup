#!/usr/bin/env bash
# Shared helpers for LLM host plugins in plugins/hosts/.
# Prefixed with '_' so plugin discovery and registry generation skip this file.

[[ -n "${_HOST_PLUGINS_COMMON_LOADED:-}" ]] && return 0
_HOST_PLUGINS_COMMON_LOADED=1

_host_find_bin() {
  local name p
  for name in "$@"; do
    if command -v "$name" >/dev/null 2>&1; then
      command -v "$name"
      return 0
    fi
    for p in \
      "${TARGET_HOME:-$HOME}/.local/bin/${name}" \
      "/opt/homebrew/bin/${name}" \
      "/opt/homebrew/sbin/${name}" \
      "/usr/local/bin/${name}"; do
      if [[ -x "$p" ]]; then
        echo "$p"
        return 0
      fi
    done
  done
  return 1
}

_host_find_docker() {
  local pattern="$1" cli="" line=""
  if command -v docker >/dev/null 2>&1; then
    cli="docker"
  elif command -v podman >/dev/null 2>&1; then
    cli="podman"
  else
    return 1
  fi
  line="$("$cli" ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | awk -F'|' -v pat="$pattern" 'tolower($2) ~ pat || tolower($1) ~ pat {print $1 "|" $2; exit}' || true)"
  [[ -n "$line" ]] || return 1
  echo "$line"
}

_host_http_get() {
  local url="$1" timeout="${2:-2}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time "$timeout" "$url" 2>/dev/null || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout="$timeout" "$url" 2>/dev/null || return 1
  else
    return 1
  fi
}

_host_http_ok() {
  _host_http_get "$1" "${2:-2}" >/dev/null 2>&1
}

_host_openai_models() {
  local base_url="${1%/}" body=""
  body="$(_host_http_get "${base_url}/v1/models" 2 || true)"
  [[ -n "$body" ]] || return 1
  if has_working_python3; then
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    ids = [str(m.get("id", "")) for m in (d.get("data") or []) if m.get("id")]
    print(",".join(ids))
except Exception:
    pass
' <<< "$body" 2>/dev/null || true
  else
    grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' <<< "$body" | sed -E 's/.*"([^"]+)"$/\1/' | paste -sd',' - || true
  fi
}

_host_github_latest_tag() {
  local repo="$1" body=""
  body="$(_host_http_get "https://api.github.com/repos/${repo}/releases/latest" 4 || true)"
  [[ -n "$body" ]] || return 1
  sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' <<< "$body" | head -n1
}

_host_update_cache_dir() {
  echo "${STRATA_UPDATE_CACHE_DIR:-${TARGET_HOME:-$HOME}/.cache/strata-performance-setup/updates}"
}

_host_norm_ver() {
  local v="${1:-}"
  v="${v#v}"
  v="${v#V}"
  echo "${v%%[[:space:]]*}"
}

_host_ver_older() {
  local inst="$1" lat="$2"
  [[ -n "$inst" && -n "$lat" && "$inst" != "$lat" ]] || return 1
  if printf '1\n2\n' | sort -V >/dev/null 2>&1; then
    [[ "$(printf '%s\n%s\n' "$inst" "$lat" | sort -V | head -n1)" == "$inst" ]]
  else
    return 0
  fi
}

_host_check_update_cached() {
  local id="$1" inst_ver="$2" target="$3" ttl="${4:-7200}" kind="${5:-github}"
  HOST_UPDATE_AVAIL[$id]="false"
  HOST_UPDATE_LATEST[$id]=""
  [[ -n "$inst_ver" && "$inst_ver" != "installed" && "$inst_ver" != "n/a" ]] || return 0

  local cdir cfile now ts="" latest=""
  cdir="$(_host_update_cache_dir)"
  cfile="${cdir}/${id}.cache"
  now="$(date +%s 2>/dev/null || echo 0)"
  if [[ -r "$cfile" ]]; then
    IFS='|' read -r ts latest < "$cfile" || true
    if [[ "$ts" =~ ^[0-9]+$ ]] && (( now - ts < ttl )) && [[ -n "$latest" ]]; then
      :
    else
      latest=""
    fi
  fi
  if [[ -z "$latest" ]]; then
    if [[ "$kind" == "pypi" ]]; then
      latest="$(_host_pypi_latest_ver "$target" || true)"
    else
      latest="$(_host_github_latest_tag "$target" || true)"
    fi
    if [[ -n "$latest" ]]; then
      mkdir -p "$cdir" 2>/dev/null || true
      printf "%s|%s\n" "$now" "$latest" > "$cfile" 2>/dev/null || true
      [[ $EUID -eq 0 && "${TARGET_USER:-root}" != "root" ]] && chown "$TARGET_USER" "$cdir" "$cfile" 2>/dev/null || true
    fi
  fi
  [[ -n "$latest" ]] || return 0
  HOST_UPDATE_LATEST[$id]="$latest"
  local norm_inst norm_lat
  norm_inst="$(_host_norm_ver "$inst_ver")"
  norm_lat="$(_host_norm_ver "$latest")"
  if _host_ver_older "$norm_inst" "$norm_lat"; then
    HOST_UPDATE_AVAIL[$id]="true"
  fi
}

_host_clear_update_cache() {
  local id="$1" cdir sfile tmp_sfile
  cdir="$(_host_update_cache_dir)"
  HOST_UPDATE_AVAIL[$id]="false"
  HOST_UPDATE_LATEST[$id]=""
  rm -f "${cdir}/${id}.cache" 2>/dev/null || true
  sfile="${cdir}/summary.state"
  if [[ -f "$sfile" ]]; then
    tmp_sfile="${sfile}.tmp.$$"
    awk -F'|' -v id="$id" '$1 != id' "$sfile" > "$tmp_sfile" 2>/dev/null || true
    mv -f "$tmp_sfile" "$sfile" 2>/dev/null || rm -f "$tmp_sfile" 2>/dev/null || true
    [[ $EUID -eq 0 && "${TARGET_USER:-root}" != "root" ]] && chown "$TARGET_USER" "$sfile" 2>/dev/null || true
  fi
}

_host_detect_install_source() {
  local id="$1" bin_path="$2" pkg_name="$3" has_installer="${4:-false}" src="manual"
  if [[ -z "$bin_path" ]]; then
    src="none"
  elif [[ "$bin_path" == "$(_host_venv_dir "$id")/"* ]]; then
    src="venv"
  elif [[ "$IS_MACOS" == true ]] && command -v brew >/dev/null 2>&1 && pkg_installed "$pkg_name" 2>/dev/null; then
    src="brew"
  elif [[ "$IS_MACOS" != true ]] && pkg_installed "$pkg_name" 2>/dev/null; then
    if [[ "$DISTRO_FAMILY" == "arch" ]] && pacman -Qm "$pkg_name" >/dev/null 2>&1; then
      src="aur"
    else
      src="distro"
    fi
  elif [[ "$has_installer" == true ]]; then
    src="installer"
  fi
  HOST_INSTALL_SOURCE[$id]="$src"
  echo "$src"
}

_host_pypi_latest_ver() {
  local pkg="$1" body=""
  body="$(_host_http_get "https://pypi.org/pypi/${pkg}/json" 4 || true)"
  [[ -n "$body" ]] || return 1
  if has_working_python3; then
    python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])' <<< "$body" 2>/dev/null || return 1
  else
    sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' <<< "$body" | head -n1
  fi
}

_host_pkg_mgr_update_ver() {
  local src="$1" pkg="$2" out=""
  case "$src" in
    brew)
      command -v brew >/dev/null 2>&1 || return 0
      out="$(run_as_user_exec brew outdated --quiet --formula "$pkg" 2>/dev/null || true)"
      [[ -n "$out" ]] && echo "brew-update"
      ;;
    distro)
      case "$DISTRO_FAMILY" in
        arch)
          out="$(pacman -Qu "$pkg" 2>/dev/null | awk '{print $NF; exit}' || true)"
          [[ -n "$out" ]] && echo "$out"
          ;;
        debian)
          out="$(apt-get -s upgrade 2>/dev/null | awk -v p="$pkg" '$1=="Inst" && $2==p {gsub(/[\[\]()]/,"",$4); print $4; exit}' || true)"
          [[ -n "$out" ]] && echo "$out"
          ;;
        fedora)
          out="$(dnf -q check-update "$pkg" 2>/dev/null | awk -v p="$pkg" '$1 ~ "^"p"\\." {print $2; exit}' || true)"
          [[ -n "$out" ]] && echo "$out"
          ;;
      esac
      ;;
    aur)
      if [[ -n "${AUR_HELPER:-}" ]]; then
        out="$(run_as_user_exec "$AUR_HELPER" -Qu "$pkg" 2>/dev/null | awk '{print $NF; exit}' || true)"
        [[ -n "$out" ]] && echo "$out"
      fi
      ;;
  esac
}

_host_check_update_by_source() {
  local id="$1" src="$2" inst_ver="$3" pkg="$4" repo="$5" pypi_pkg="${6:-}" ttl="${7:-7200}"
  case "$src" in
    none|manual|docker)
      _host_clear_update_cache "$id"
      return 0
      ;;
    installer)
      _host_check_update_cached "$id" "$inst_ver" "$repo" "$ttl" "github"
      ;;
    venv)
      _host_check_update_cached "$id" "$inst_ver" "${pypi_pkg:-$pkg}" "$ttl" "pypi"
      ;;
    brew|distro|aur)
      HOST_UPDATE_AVAIL[$id]="false"
      HOST_UPDATE_LATEST[$id]=""
      local cdir cfile now ts="" cached_ver=""
      cdir="$(_host_update_cache_dir)"
      cfile="${cdir}/${id}.cache"
      now="$(date +%s 2>/dev/null || echo 0)"
      if [[ -r "$cfile" ]]; then
        IFS='|' read -r ts cached_ver < "$cfile" || true
        if [[ "$ts" =~ ^[0-9]+$ ]] && (( now - ts < ttl )); then
          if [[ -n "$cached_ver" && "$cached_ver" != "none" ]]; then
            HOST_UPDATE_AVAIL[$id]="true"
            HOST_UPDATE_LATEST[$id]="$cached_ver"
          fi
          return 0
        fi
      fi
      cached_ver="$(_host_pkg_mgr_update_ver "$src" "$pkg" || true)"
      mkdir -p "$cdir" 2>/dev/null || true
      printf "%s|%s\n" "$now" "${cached_ver:-none}" > "$cfile" 2>/dev/null || true
      [[ $EUID -eq 0 && "${TARGET_USER:-root}" != "root" ]] && chown "$TARGET_USER" "$cdir" "$cfile" 2>/dev/null || true
      if [[ -n "$cached_ver" && "$cached_ver" != "none" ]]; then
        HOST_UPDATE_AVAIL[$id]="true"
        HOST_UPDATE_LATEST[$id]="$cached_ver"
      fi
      ;;
  esac
  return 0
}

_host_format_menu_row() {
  local tag="$1" name="$2" status_text="$3" installed="$4" running="$5" selected="$6"
  local prefix="  "
  [[ "$selected" == true ]] && prefix="▶ "
  local status_color="$C_DIM"
  if [[ "$running" == true ]]; then
    status_color="$C_GREEN"
  elif [[ "$installed" == true ]]; then
    status_color="$C_YELLOW"
  fi
  if [[ "$selected" == true ]]; then
    printf "%b%s[%s]  %s (%s)%b" "${C_BOLD}${C_CYAN}" "$prefix" "$tag" "$name" "$status_text" "$C_RESET"
  else
    printf "%s%b[%s]%b  %b%s%b %b(%s)%b" "$prefix" "${C_MAGENTA}" "$tag" "${C_RESET}" "${C_BOLD}" "$name" "${C_RESET}" "$status_color" "$status_text" "${C_RESET}"
  fi
}

_host_shell_quote() {
  local val="${1:-}"
  val="${val//$'\r'/}"
  val="${val//$'\n'/}"
  printf "'%s'" "${val//\'/\'\\\'\'}"
}

_host_std_menu_row() {
  local tag="$1" name="$2" ver="$3" docker="$4" running="$5" selected="$6"
  local installed=false status="not installed"
  if [[ -n "$ver" ]]; then
    installed=true
    if [[ "$running" == true ]]; then
      status="running, ${ver}"
    else
      status="${ver}"
    fi
  elif [[ -n "$docker" ]]; then
    installed=true
    running=true
    status="Docker: ${docker%%|*}"
  fi
  _host_format_menu_row "$tag" "$name" "$status" "$installed" "$running" "$selected"
}

_host_std_check_summary() {
  local label="$1" ver="$2" url="$3" docker="$4" running="$5" loc="${6:-}"
  if [[ -n "$ver" ]]; then
    local st="stopped"
    [[ "$running" == true ]] && st="running at ${url}"
    if [[ -n "$loc" ]]; then
      printf "  %-9s %s at %s (%s)\n" "${label}:" "$ver" "$loc" "$st"
    else
      printf "  %-9s %s (%s)\n" "${label}:" "$ver" "$st"
    fi
  elif [[ -n "$docker" ]]; then
    printf "  %-9s Docker container (%s)\n" "${label}:" "${docker%%|*}"
  else
    printf "  %-9s not installed\n" "${label}:"
  fi
}

_host_std_live_stats() {
  local label="$1" ver="$2" url="$3" running="$4" models="${5:-}"
  [[ "$running" == true || -n "$ver" ]] || return 0
  local st="${C_DIM}stopped${C_RESET}"
  if [[ "$running" == true ]]; then
    [[ -z "$models" ]] && models="$(_host_openai_models "$url" || true)"
    st="${C_GREEN}running${C_RESET}"
    [[ -n "$models" ]] && st+=" (${models})"
  fi
  LIVE_STAT_LINES+=("$(printf "  %-10s %b" "${label}:" "$st")")
}

_host_std_table_status() {
  local installed_val="$1" docker="$2" running="$3" unit="$4"
  local inst=false svc="not installed"
  if [[ -n "$installed_val" || -n "$docker" ]]; then
    inst=true
    if [[ -n "$docker" ]]; then
      svc="${C_GREEN}running (docker)${C_RESET}"
    elif service_installed "$unit"; then
      if unit_active "$unit"; then
        svc="${C_GREEN}active (service)${C_RESET}"
      elif [[ "$running" == true ]]; then
        svc="${C_YELLOW}running (manual)${C_RESET}"
      else
        svc="${C_YELLOW}inactive (service)${C_RESET}"
      fi
    elif [[ "$running" == true ]]; then
      svc="${C_GREEN}running (manual)${C_RESET}"
    else
      svc="${C_DIM}no service${C_RESET}"
    fi
  fi
  printf "%s|%s" "$inst" "$svc"
}

_host_install_systemd_unit() {
  local unit="$1" desc="$2" exec_start="$3" work_dir="${4:-}" env_lines="${5:-}"
  local svc_user="${TARGET_USER:-${USER:-root}}"
  local unit_body="[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${svc_user}
"
  [[ -n "$work_dir" ]] && unit_body+="WorkingDirectory=${work_dir}
"
  [[ -n "$env_lines" ]] && unit_body+="${env_lines}
"
  unit_body+="ExecStart=${exec_start}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
"
  printf '%s' "$unit_body" | install_service "$unit"
}

_host_venv_dir() {
  local id="$1"
  echo "${TARGET_HOME:-$HOME}/.local/share/strata-hosts/${id}/venv"
}

_host_venv_bin() {
  local id="$1" bin_name="$2"
  local vdir
  vdir="$(_host_venv_dir "$id")"
  if [[ -x "${vdir}/bin/${bin_name}" ]]; then
    echo "${vdir}/bin/${bin_name}"
    return 0
  fi
  _host_find_bin "$bin_name"
}

_host_venv_pkg_version() {
  local id="$1" pkg="$2"
  local vdir py_bin
  vdir="$(_host_venv_dir "$id")"
  if [[ -x "${vdir}/bin/python3" ]]; then
    py_bin="${vdir}/bin/python3"
  elif has_working_python3; then
    py_bin="python3"
  else
    return 1
  fi
  "$py_bin" -c "import importlib.metadata as m; print(m.version('${pkg}'))" 2>/dev/null || return 1
}

_host_venv_install_or_upgrade() {
  local id="$1" pkg="$2" upgrade="${3:-false}"
  local vdir
  vdir="$(_host_venv_dir "$id")"
  run_as_user_exec mkdir -p "$(dirname "$vdir")"
  if command -v uv >/dev/null 2>&1; then
    if [[ ! -x "${vdir}/bin/python3" ]]; then
      run_as_user_exec uv venv "$vdir" || return 1
    fi
    if [[ "$upgrade" == true ]]; then
      run_as_user_exec uv pip install --python "${vdir}/bin/python3" -U "$pkg"
    else
      run_as_user_exec uv pip install --python "${vdir}/bin/python3" "$pkg"
    fi
    return $?
  fi
  if ! has_working_python3; then
    echo "python3 is required to install ${pkg}." >&2
    return 1
  fi
  if [[ ! -x "${vdir}/bin/python3" ]]; then
    run_as_user_exec python3 -m venv "$vdir" || return 1
  fi
  if [[ "$upgrade" == true ]]; then
    run_as_user_exec "${vdir}/bin/pip" install -U "$pkg"
  else
    run_as_user_exec "${vdir}/bin/pip" install "$pkg"
  fi
}

_host_openai_bench() {
  local label="$1" base_url="${2%/}" model="${3:-}"
  if ! _host_http_ok "${base_url}/v1/models" 2; then
    echo -e "${C_YELLOW}${label} API is not reachable at ${base_url}.${C_RESET}"
    return 1
  fi
  if [[ -z "$model" ]]; then
    local models_csv
    models_csv="$(_host_openai_models "$base_url" || true)"
    model="${models_csv%%,*}"
  fi
  if [[ -z "$model" ]]; then
    echo -e "${C_YELLOW}No loaded/available model found at ${base_url}/v1/models.${C_RESET}"
    return 1
  fi
  if ! has_working_python3; then
    echo -e "${C_YELLOW}python3 is required to run the OpenAI-compatible benchmark.${C_RESET}"
    return 1
  fi
  echo -e "${C_CYAN}Benchmarking ${label} (${model}) at ${base_url}...${C_RESET}"
  python3 - "$base_url" "$model" <<'PY'
import json, sys, time, urllib.request

base_url, model = sys.argv[1], sys.argv[2]
payload = json.dumps({
    "model": model,
    "messages": [{"role": "user", "content": "Write a concise 120-word technical summary of how KV-cache paging improves LLM inference throughput."}],
    "max_tokens": 128,
    "temperature": 0.0,
    "stream": False,
}).encode("utf-8")
req = urllib.request.Request(
    f"{base_url}/v1/chat/completions",
    data=payload,
    headers={"Content-Type": "application/json"},
    method="POST",
)
t0 = time.perf_counter()
with urllib.request.urlopen(req, timeout=120) as resp:
    data = json.loads(resp.read().decode("utf-8"))
dt = max(time.perf_counter() - t0, 1e-6)
usage = data.get("usage") or {}
ptok = usage.get("prompt_tokens")
ctok = usage.get("completion_tokens")
print(f"  Model:            {model}")
print(f"  Wall time:        {dt:.2f} s")
if ptok is not None:
    print(f"  Prompt tokens:    {ptok}")
if ctok is not None:
    print(f"  Completion tokens:{ctok}")
    print(f"  Throughput:       {ctok / dt:.2f} tok/s (end-to-end)")
PY
}

_host_manage_service_action() {
  local label="$1" unit="$2" desc="$3" exec_start="$4" work_dir="${5:-}" env_lines="${6:-}"
  if service_installed "$unit"; then
    if unit_active "$unit"; then
      echo "  1) Stop ${label} service"
      echo "  2) Restart ${label} service"
      echo "  3) Remove ${label} service"
      echo "  0) Back"
      local ch=""
      read -r -p "Select action: " ch
      case "$ch" in
        1) service_ctl stop "$unit" || true ;;
        2) service_ctl restart "$unit" || true ;;
        3) confirm_yn "Remove ${unit}? [y/N]: " "N" && remove_service "$unit" ;;
      esac
    else
      echo "  1) Start ${label} service"
      echo "  2) Remove ${label} service"
      echo "  0) Back"
      local ch=""
      read -r -p "Select action: " ch
      case "$ch" in
        1) service_ctl start "$unit" || true ;;
        2) confirm_yn "Remove ${unit}? [y/N]: " "N" && remove_service "$unit" ;;
      esac
    fi
  else
    if confirm_yn "Install and start ${label} system service (${unit})? [Y/n]: " "Y"; then
      _host_install_systemd_unit "$unit" "$desc" "$exec_start" "$work_dir" "$env_lines"
    fi
  fi
}

_host_option_row() {
  local idx="$1" opt="$2" name="$3" unit="$4" ver="$5" running="$6" selected="$7"
  local badge="" title="" ptr=" " num=$(( idx + 1 )) row_num=""
  case "$opt" in
    install)
      badge="${C_YELLOW}[NOT INSTALLED]${C_RESET}"
      title="Install ${name}"
      ;;
    update)
      badge="${C_GREEN}[INSTALLED]    ${C_RESET}"
      title="Update ${name}${ver:+ (${ver})}"
      ;;
    service)
      if service_installed "$unit" 2>/dev/null; then
        if unit_active "$unit" 2>/dev/null; then
          badge="${C_GREEN}[ACTIVE]       ${C_RESET}"
        else
          badge="${C_YELLOW}[INACTIVE]     ${C_RESET}"
        fi
      else
        badge="${C_DIM}[NOT SET]      ${C_RESET}"
      fi
      title="Manage ${name} service (${unit})"
      ;;
    bench)
      if [[ "$running" == true ]]; then
        badge="${C_GREEN}[READY]        ${C_RESET}"
      else
        badge="${C_DIM}[STOPPED]      ${C_RESET}"
      fi
      title="Run ${name} benchmark"
      ;;
    latest)
      badge="${C_CYAN}[CHECK]        ${C_RESET}"
      title="Check latest upstream release"
      ;;
  esac
  if [[ "$selected" == true ]]; then
    ptr="${C_CYAN}>${C_RESET}"
    row_num="${C_CYAN}${C_BOLD}$(printf "%2d" "$num")${C_RESET}"
    title="${C_CYAN}${C_BOLD}${title}${C_RESET}"
  else
    row_num="$(printf "%2d" "$num")"
  fi
  printf "%b %b  | %b | %b" "$ptr" "$row_num" "$badge" "$title"
}

_host_build_options_list() {
  local installed="$1" has_docker="${2:-false}" src="${3:-}"
  if [[ "$installed" == true ]]; then
    if [[ "$src" == "manual" ]]; then
      echo "service bench latest"
    else
      echo "update service bench latest"
    fi
  elif [[ "$has_docker" == true ]]; then
    echo "bench latest"
  else
    echo "install"
  fi
}

_host_run_options_page() {
  local name="" unit="" refresh_fn="" bin_var="" ver_var="" docker_var="" source_var="" url="" is_running_fn="" dispatch_fn=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --unit) unit="$2"; shift 2 ;;
      --refresh) refresh_fn="$2"; shift 2 ;;
      --bin-var) bin_var="$2"; shift 2 ;;
      --ver-var) ver_var="$2"; shift 2 ;;
      --docker-var) docker_var="$2"; shift 2 ;;
      --source-var) source_var="$2"; shift 2 ;;
      --url) url="$2"; shift 2 ;;
      --is-running) is_running_fn="$2"; shift 2 ;;
      --dispatch) dispatch_fn="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local sel=0
  while true; do
    [[ -n "$refresh_fn" ]] && "$refresh_fn"
    local bin_val="${!bin_var:-}" ver_val="${!ver_var:-}" docker_val="" src_val=""
    [[ -n "$docker_var" ]] && docker_val="${!docker_var:-}"
    [[ -n "$source_var" ]] && src_val="${!source_var:-}"
    local installed=false has_docker=false running=false
    [[ -n "$bin_val" ]] && installed=true
    [[ -n "$docker_val" ]] && has_docker=true
    if [[ -n "$is_running_fn" ]] && "$is_running_fn"; then
      running=true
    fi

    local -a opts=()
    read -ra opts <<< "$(_host_build_options_list "$installed" "$has_docker" "$src_val")"
    local total=${#opts[@]}
    (( sel >= total )) && sel=$(( total - 1 ))
    (( sel < 0 )) && sel=0

    print_header
    echo -e "${C_BOLD}${name} Manager${C_RESET}"
    echo ""
    if [[ "$installed" != true && "$has_docker" == true ]]; then
      echo -e "  Docker:   ${docker_val%%|*} (${docker_val#*|})"
    else
      echo -e "  Binary:   ${bin_val:-not installed}${src_val:+ (${src_val})}"
      echo -e "  Version:  ${ver_val:-n/a}"
    fi
    echo -e "  Endpoint: ${url}"
    if [[ "$running" == true ]]; then
      echo -e "  Status:   ${C_GREEN}running${C_RESET}"
    else
      echo -e "  Status:   ${C_DIM}not running${C_RESET}"
    fi
    echo ""
    echo -e "${C_BOLD}${name} Options:${C_RESET}"
    echo ""
    printf "  ${C_BOLD}%-3s | %-15s | %s${C_RESET}\n" "#" "Status" "Option"
    printf "  %s\n" "----+-----------------+-------------------------------------------------------"
    local i is_sel
    for (( i = 0; i < total; i++ )); do
      is_sel=false
      (( i == sel )) && is_sel=true
      printf "%s\n" "$(_host_option_row "$i" "${opts[$i]}" "$name" "$unit" "$ver_val" "$running" "$is_sel")"
    done
    echo ""
    local num_hint="1"
    (( total > 1 )) && num_hint="1-${total}"
    echo -e "  ${C_BOLD}[${num_hint} / ↑↓+Enter]${C_RESET} Select an option"
    echo -e "  ${C_DIM}[i / b / Esc]${C_RESET} Back to Inference Servers"
    echo -e "  ${C_BOLD}[q]${C_RESET} Quit"
    echo ""

    local saved_tty="" chosen_opt=""
    saved_tty="$(stty -g 2>/dev/null || true)"
    stty -echo 2>/dev/null || true
    trap '_tui_restore_tty "$saved_tty"; exit 0' INT TERM

    printf "Select action: "
    while true; do
      local action=""
      IFS= read -rsn1 action || { _tui_restore_tty "$saved_tty"; trap - INT TERM; printf "\n"; return 0; }
      if [[ "$action" == $'\e' ]]; then
        local seq=""
        _tui_read_esc_seq seq
        if [[ -z "$seq" ]]; then
          _tui_restore_tty "$saved_tty"; trap - INT TERM; printf "\n"; return 0
        fi
        local old_sel="$sel" new_sel="$sel"
        if [[ "$seq" == "[A" || "$seq" == "OA" ]]; then
          new_sel=$(( (old_sel - 1 + total) % total ))
        elif [[ "$seq" == "[B" || "$seq" == "OB" ]]; then
          new_sel=$(( (old_sel + 1) % total ))
        fi
        if (( new_sel != old_sel )); then
          sel="$new_sel"
          local old_up=$(( 5 + (total - old_sel) ))
          local new_up=$(( 5 + (total - new_sel) ))
          local old_row new_row
          old_row="$(_host_option_row "$old_sel" "${opts[$old_sel]}" "$name" "$unit" "$ver_val" "$running" false)"
          new_row="$(_host_option_row "$new_sel" "${opts[$new_sel]}" "$name" "$unit" "$ver_val" "$running" true)"
          printf "\033[?2026h\033[?25l\033[s\033[%dA\r\033[2K%s\033[u\033[s\033[%dA\r\033[2K%s\033[u\033[?25h\033[?2026l" \
            "$old_up" "$old_row" "$new_up" "$new_row"
        fi
        continue
      fi

      case "$action" in
        "")
          chosen_opt="${opts[$sel]}"
          break
          ;;
        [1-9])
          if (( action <= total )); then
            sel=$(( action - 1 ))
            chosen_opt="${opts[$sel]}"
            break
          fi
          ;;
        0|b|B|i|I)
          _tui_restore_tty "$saved_tty"; trap - INT TERM; printf "\n"; return 0
          ;;
        q|Q)
          _tui_restore_tty "$saved_tty"; trap - INT TERM; printf "\n"; exit 0
          ;;
      esac
    done

    _tui_restore_tty "$saved_tty"
    trap - INT TERM
    printf "\n"
    "$dispatch_fn" "$chosen_opt"
    pause_prompt
  done
}
