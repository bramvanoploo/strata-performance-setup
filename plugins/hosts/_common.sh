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
  local url="$1" timeout="${2:-2}" h
  if (( $# >= 2 )); then shift 2; else shift $#; fi
  if command -v curl >/dev/null 2>&1; then
    if (( $# > 0 )); then
      local cfg="" esc_h=""
      for h in "$@"; do
        esc_h="${h//\\/\\\\}"
        esc_h="${esc_h//\"/\\\"}"
        cfg+="header = \"${esc_h}\""$'\n'
      done
      printf '%s' "$cfg" | curl -fsS --max-time "$timeout" -K - "$url" 2>/dev/null || return 1
    else
      curl -fsS --max-time "$timeout" "$url" 2>/dev/null || return 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    local -a hdr=()
    for h in "$@"; do hdr+=(--header="$h"); done
    wget -qO- --timeout="$timeout" ${hdr[@]+"${hdr[@]}"} "$url" 2>/dev/null || return 1
  else
    return 1
  fi
}

_host_http_ok() {
  _host_http_get "$1" "${2:-2}" >/dev/null 2>&1
}

_host_proc_running() {
  local pat="$1"
  [[ -n "$pat" ]] || return 1
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f "$pat" >/dev/null 2>&1
  else
    ps -eo args= 2>/dev/null | grep -E "$pat" | grep -qv grep
  fi
}

_host_extract_port_from_text() {
  local txt="${1:-}" port=""
  [[ -n "$txt" ]] || return 1
  port="$(sed -nE 's/.*(--port|--rest_port|--chatgpt-api-port|-p)[=[:space:]]+([0-9]{2,5})([[:space:]]|$).*/\2/p' <<<"$txt" | head -n1)"
  if [[ -z "$port" ]]; then
    port="$(sed -nE 's/.*(--address|OLLAMA_HOST)[=[:space:]]+[^[:space:]:]+:([0-9]{2,5})([[:space:]"'\'']|$).*/\2/p' <<<"$txt" | head -n1)"
  fi
  [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port <= 65535 )) || return 1
  echo "$port"
}

_host_detect_url() {
  local default_url="$1" proc_pat="$2" docker_val="${3:-}" unit="${4:-}"
  local port="" pids="" p=""

  if [[ -n "$docker_val" ]]; then
    local cname="${docker_val%%|*}" cli="docker"
    command -v docker >/dev/null 2>&1 || cli="podman"
    if command -v "$cli" >/dev/null 2>&1; then
      port="$("$cli" port "$cname" 2>/dev/null | sed -nE 's/.*:([0-9]+)$/\1/p' | head -n1 || true)"
    fi
  fi

  if [[ -z "$port" && -n "$proc_pat" ]]; then
    if command -v pgrep >/dev/null 2>&1; then
      pids="$(pgrep -f "$proc_pat" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)"
    fi
    if [[ -n "$pids" ]]; then
      if command -v ss >/dev/null 2>&1; then
        local ss_out=""
        ss_out="$(ss -tlpn 2>/dev/null || true)"
        for p in ${pids//,/ }; do
          port="$(awk -v pid="pid=${p}," '$0 ~ pid {split($4,a,":"); pt=a[length(a)]; if (pt ~ /^[0-9]+$/) {print pt; exit}}' <<<"$ss_out" || true)"
          [[ -n "$port" ]] && break
        done
      elif command -v lsof >/dev/null 2>&1; then
        port="$(lsof -nP -a -iTCP -sTCP:LISTEN -p "$pids" 2>/dev/null | awk 'NR>1 {split($9,a,":"); pt=a[length(a)]; if (pt ~ /^[0-9]+$/) {print pt; exit}}' || true)"
      fi
    fi
    if [[ -z "$port" ]]; then
      local args_out=""
      args_out="$(ps -eo args= 2>/dev/null | grep -E "$proc_pat" | grep -v grep | head -n1 || true)"
      port="$(_host_extract_port_from_text "$args_out" || true)"
    fi
  fi

  if [[ -z "$port" && -n "$unit" ]] && [[ "$HAS_SYSTEMD" == true ]] && service_installed "$unit" 2>/dev/null; then
    local unit_txt=""
    unit_txt="$(systemctl cat "$unit" 2>/dev/null || true)"
    port="$(_host_extract_port_from_text "$unit_txt" || true)"
  fi

  if [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port <= 65535 )); then
    echo "http://127.0.0.1:${port}"
  else
    echo "$default_url"
  fi
}

_host_endpoint_running() {
  local probe_url="$1" proc_pat="$2" docker_val="${3:-}" unit="${4:-}"
  if [[ -z "$docker_val" ]] && { [[ -z "$unit" ]] || ! unit_active "$unit" 2>/dev/null; }; then
    _host_proc_running "$proc_pat" || return 1
  fi
  _host_http_ok "$probe_url" 1
}

_host_openai_models() {
  local base_url="${1%/}" body="" out=""
  # shortcut: model list cached 5s (positives only) so live-stats redraws don't re-GET the same endpoint
  local cts="${_HOST_MODELS_TS[$base_url]:-}"
  if [[ -n "$cts" ]] && (( SECONDS - cts < 5 )); then
    printf '%s\n' "${_HOST_MODELS_CACHE[$base_url]}"
    return 0
  fi
  body="$(_host_http_get "${base_url}/v1/models" 2 || true)"
  if [[ -n "$body" ]]; then
    if has_working_python3; then
      out="$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    ids = [str(m.get("id", "")) for m in (d.get("data") or []) if m.get("id")]
    print(",".join(ids))
except Exception:
    pass
' <<< "$body" 2>/dev/null || true)"
    else
      out="$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' <<< "$body" | sed -E 's/.*"([^"]+)"$/\1/' | paste -sd',' - || true)"
    fi
  fi
  [[ -n "$out" ]] || return 1
  _HOST_MODELS_CACHE[$base_url]="$out"
  _HOST_MODELS_TS[$base_url]="$SECONDS"
  printf '%s\n' "$out"
}
_host_has_served_model() {
  local base_url="${1%/}" models=""
  models="$(_host_openai_models "$base_url" || true)"
  [[ -n "$models" ]]
}

_host_owning_pkg() {
  local bin_path="${1:-}" owner="" real_p=""
  [[ -n "$bin_path" ]] || return 1
  if [[ "$IS_MACOS" == true ]] && command -v brew >/dev/null 2>&1; then
    real_p="$(readlink -f "$bin_path" 2>/dev/null || echo "$bin_path")"
    if [[ "$real_p" =~ /Cellar/([^/]+)/ ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  elif [[ "$DISTRO_FAMILY" == "arch" ]] && command -v pacman >/dev/null 2>&1; then
    owner="$(pacman -Qoq "$bin_path" 2>/dev/null | head -n1 || true)"
  elif [[ "$DISTRO_FAMILY" == "debian" ]] && command -v dpkg-query >/dev/null 2>&1; then
    owner="$(dpkg-query -S "$bin_path" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  elif [[ "$DISTRO_FAMILY" == "fedora" || "$DISTRO_FAMILY" == "suse" ]] && command -v rpm >/dev/null 2>&1; then
    owner="$(rpm -qf --qf '%{NAME}\n' "$bin_path" 2>/dev/null | head -n1 || true)"
    [[ "$owner" == *"is not owned"* ]] && owner=""
  fi
  [[ -n "$owner" ]] || return 1
  echo "$owner"
}

_host_pkg_uninstall() {
  local pkg="$1" rc=0
  case "$DISTRO_FAMILY" in
    arch)   run_root pacman -R --noconfirm "$pkg" || rc=$? ;;
    fedora)
      if [[ "$IS_OSTREE" == true ]] && command -v rpm-ostree >/dev/null 2>&1; then
        run_root rpm-ostree uninstall -y "$pkg" || rc=$?
      else
        run_root dnf remove -y "$pkg" || rc=$?
      fi
      ;;
    debian) run_root env DEBIAN_FRONTEND=noninteractive apt-get remove -y "$pkg" || rc=$? ;;
    suse)   run_root zypper --non-interactive remove "$pkg" || rc=$? ;;
    macos)  command -v brew >/dev/null 2>&1 && run_as_user_exec brew uninstall "$pkg" || rc=$? ;;
    *)      return 1 ;;
  esac
  PKG_INST_CACHE=()
  refresh_unit_files_cache
  return "$rc"
}

_host_standard_uninstall() {
  local id="$1" name="$2" unit="$3" bin_path="$4" src="$5" pkg_name="$6"
  shift 6
  if ! [[ "$id" =~ ^[a-z0-9_-]+$ ]]; then
    echo -e "${C_RED}Refusing to uninstall invalid host id '${id}'.${C_RESET}" >&2
    return 1
  fi
  local -a extra_paths=("$@")
  local vdir host_dir owner_pkg="" has_svc=false shared_interp=false
  vdir="$(_host_venv_dir "$id")"
  host_dir="${TARGET_HOME:-$HOME}/.local/share/strata-hosts/${id}"
  service_installed "$unit" 2>/dev/null && has_svc=true

  if [[ -n "$bin_path" ]]; then
    case "$(basename "$bin_path")" in
      python|python3|python3.*|node|sh|bash|zsh|env) shared_interp=true ;;
    esac
  fi

  if [[ "$src" == "manual" && -n "$bin_path" && "$shared_interp" == false ]]; then
    owner_pkg="$(_host_owning_pkg "$bin_path" || true)"
  fi

  echo -e "${C_YELLOW}WARNING: This will uninstall ${name} from this system.${C_RESET}"
  [[ "$has_svc" == true ]] && echo "  - System service to stop & remove: ${unit}"
  case "$src" in
    venv)
      echo "  - Managed Python environment: ${vdir}"
      [[ -d "$host_dir" ]] && echo "  - Managed host directory: ${host_dir}"
      ;;
    brew|distro|aur)
      echo "  - Package (${src}): ${pkg_name}"
      ;;
    installer|manual)
      if [[ "$shared_interp" == true ]]; then
        echo "  - Shared system interpreter (${bin_path}) will NOT be removed; run 'pip uninstall ${pkg_name}' if installed in system Python."
      elif [[ -n "$owner_pkg" ]]; then
        echo "  - Owning system package: ${owner_pkg}"
      elif [[ -n "$bin_path" ]]; then
        echo "  - Binary: ${bin_path}"
      fi
      [[ -d "$host_dir" ]] && echo "  - Managed host directory: ${host_dir}"
      ;;
  esac
  local ep
  for ep in ${extra_paths[@]+"${extra_paths[@]}"}; do
    [[ -e "$ep" || -L "$ep" ]] && echo "  - Extra path: ${ep}"
  done
  echo ""
  confirm_yn "Proceed with uninstalling ${name}? [y/N]: " "N" || { echo "Cancelled."; return 0; }

  if [[ "$has_svc" == true ]]; then
    service_ctl stop "$unit" >/dev/null 2>&1 || true
    remove_service "$unit" || true
  fi

  case "$src" in
    venv)
      rm -rf "$vdir" "$host_dir" 2>/dev/null || run_root rm -rf "$vdir" "$host_dir"
      ;;
    brew|distro|aur)
      _host_pkg_uninstall "$pkg_name" || return 1
      ;;
    installer|manual)
      if [[ "$shared_interp" == true ]]; then
        echo -e "${C_YELLOW}Skipped removing shared interpreter ${bin_path}; uninstall the Python package via pip.${C_RESET}"
      elif [[ -n "$owner_pkg" ]]; then
        _host_pkg_uninstall "$owner_pkg" || return 1
      elif [[ -n "$bin_path" && ( -e "$bin_path" || -L "$bin_path" ) ]]; then
        if [[ -w "$(dirname "$bin_path")" ]]; then
          rm -f "$bin_path"
        else
          run_root rm -f "$bin_path"
        fi
      fi
      [[ -d "$host_dir" ]] && { rm -rf "$host_dir" 2>/dev/null || run_root rm -rf "$host_dir"; }
      ;;
  esac
  for ep in ${extra_paths[@]+"${extra_paths[@]}"}; do
    [[ -e "$ep" || -L "$ep" ]] || continue
    if [[ -w "$(dirname "$ep")" ]]; then
      rm -rf "$ep"
    else
      run_root rm -rf "$ep"
    fi
  done
  echo -e "${C_GREEN}${name} uninstalled.${C_RESET}"
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
    # shortcut: no sort -V available → assume current rather than nag an update banner forever
    return 1
  fi
}

_host_check_update_cached() {
  local id="$1" inst_ver="$2" target="$3" ttl="${4:-7200}" kind="${5:-github}"
  [[ "${_FORCE_FRESH_UPDATE_CHECK:-false}" == true ]] && ttl=0
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
  if [[ "$id" == "strata" ]]; then
    STRATA_UPDATE_AVAILABLE=false
    STRATA_UPDATE_SUMMARY=""
  fi
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
  [[ "${_FORCE_FRESH_UPDATE_CHECK:-false}" == true ]] && ttl=0
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
      local _hid="${unit%.service}"
      if declare -F _server_has_update >/dev/null 2>&1 && _server_has_update "$_hid"; then
        badge="${C_UPDATE_BANNER}[UPDATE READY]${C_RESET} "
      else
        badge="${C_GREEN}[INSTALLED]    ${C_RESET}"
      fi
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
    uninstall)
      badge="${C_RED}[UNINSTALL]    ${C_RESET}"
      title="Uninstall ${name}"
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
  local installed="$1" has_docker="${2:-false}" src="${3:-}" can_bench="${4:-false}"
  local -a opts=()
  if [[ "$installed" == true ]]; then
    [[ "$src" != "manual" ]] && opts+=("update")
    opts+=("service")
    [[ "$can_bench" == true ]] && opts+=("bench")
    opts+=("latest" "uninstall")
  elif [[ "$has_docker" == true ]]; then
    [[ "$can_bench" == true ]] && opts+=("bench")
    opts+=("latest")
  else
    opts+=("install")
  fi
  echo "${opts[*]}"
}

_host_run_options_page() {
  local name="" unit="" refresh_fn="" bin_var="" ver_var="" docker_var="" source_var="" url="" url_var="" is_running_fn="" dispatch_fn=""
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
      --url-var) url_var="$2"; shift 2 ;;
      --is-running) is_running_fn="$2"; shift 2 ;;
      --dispatch) dispatch_fn="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local sel=0 last_probe=-99
  local bin_val="" ver_val="" docker_val="" src_val="" cur_url="$url"
  local installed=false has_docker=false running=false can_bench=false
  while true; do
    # shortcut: probes cached 3s to keep the menu responsive; forced fresh after every action below.
    if (( SECONDS - last_probe >= 3 )); then
      last_probe=$SECONDS
      [[ -n "$refresh_fn" ]] && "$refresh_fn"
      bin_val="${!bin_var:-}"; ver_val="${!ver_var:-}"; docker_val=""; src_val=""; cur_url="$url"
      [[ -n "$docker_var" ]] && docker_val="${!docker_var:-}"
      [[ -n "$source_var" ]] && src_val="${!source_var:-}"
      [[ -n "$url_var" && -n "${!url_var:-}" ]] && cur_url="${!url_var}"
      installed=false; has_docker=false; running=false; can_bench=false
      [[ -n "$bin_val" ]] && installed=true
      [[ -n "$docker_val" ]] && has_docker=true
      if [[ -n "$is_running_fn" ]] && "$is_running_fn"; then
        running=true
        _host_has_served_model "$cur_url" && can_bench=true
      fi
    fi

    local -a opts=()
    read -ra opts <<< "$(_host_build_options_list "$installed" "$has_docker" "$src_val" "$can_bench")"
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
    echo -e "  Endpoint: ${cur_url}"
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
    local num_hint="1" footer_extra=0 _host_upd_names=""
    (( total > 1 )) && num_hint="1-${total}"
    echo -e "  ${C_BOLD}[${num_hint} / ↑↓+Enter]${C_RESET} Select an option"
    declare -F _outdated_server_names >/dev/null 2>&1 && _host_upd_names="$(_outdated_server_names)"
    if [[ -n "$_host_upd_names" ]]; then
      echo -e "  ${C_BGREEN}[u]${C_RESET} Install update(s) for: ${_host_upd_names}"
      footer_extra=1
    fi
    echo -e "  ${C_DIM}[i / b / Esc]${C_RESET} Back to Inference Servers"
    echo -e "  ${C_BOLD}[q]${C_RESET} Quit"
    echo ""

    local saved_tty="" chosen_opt="" do_refresh=false do_upd_all=false init_upd_cnt=0
    declare -F _count_server_updates >/dev/null 2>&1 && init_upd_cnt="$(_count_server_updates)"
    saved_tty="$(stty -g 2>/dev/null || true)"
    stty -echo 2>/dev/null || true
    trap '_tui_restore_tty "$saved_tty"; exit 0' INT TERM

    printf "Select action: "
    while true; do
      local action="" rc=0
      if [[ -t 0 && -t 1 ]]; then
        IFS= read -rsn1 -t 1 action || rc=$?
      else
        IFS= read -rsn1 action || rc=$?
      fi
      if (( rc > 128 )); then
        if declare -F load_server_update_states >/dev/null 2>&1; then
          load_server_update_states
          declare -F load_strata_update_state >/dev/null 2>&1 && load_strata_update_state
          if (( $(_count_server_updates) != init_upd_cnt )); then
            do_refresh=true
            break
          fi
        fi
        continue
      elif (( rc != 0 )); then
        _tui_restore_tty "$saved_tty"; trap - INT TERM; printf "\n"; return 0
      fi
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
          local old_up=$(( 5 + footer_extra + (total - old_sel) ))
          local new_up=$(( 5 + footer_extra + (total - new_sel) ))
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
        u|U)
          if [[ -n "$_host_upd_names" ]] && declare -F _run_all_server_updates >/dev/null 2>&1; then
            do_upd_all=true
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
    [[ "$do_refresh" == true ]] && continue
    if [[ "$do_upd_all" == true ]]; then
      _run_all_server_updates
      last_probe=-99
      continue
    fi
    "$dispatch_fn" "$chosen_opt"
    pause_prompt
    last_probe=-99
  done
}

declare -gA _HOST_VP_TAG=() _HOST_VP_NAME=() _HOST_VP_BIN_NAME=() _HOST_VP_PIP_PKG=() _HOST_VP_PKG_SPEC=()
declare -gA _HOST_VP_REPO=() _HOST_VP_PORT=() _HOST_VP_URL=() _HOST_VP_HEALTH=() _HOST_VP_DOCKER_PAT=()
declare -gA _HOST_VP_SVC_DESC=() _HOST_VP_SVC_ARGS=() _HOST_VP_MODEL_PROMPT=() _HOST_VP_LIVE_LABEL=()
declare -gA _HOST_VP_BIN=() _HOST_VP_VER=() _HOST_VP_DOCKER=() _HOST_VP_SRC=()
declare -gA _HOST_VP_RUN=() _HOST_VP_RUN_TS=() _HOST_MODELS_CACHE=() _HOST_MODELS_TS=()
_HOST_VP_ACTIVE_ID="" _HOST_VP_CUR_BIN="" _HOST_VP_CUR_VER="" _HOST_VP_CUR_DOCKER="" _HOST_VP_CUR_SRC="" _HOST_VP_CUR_URL=""

_host_vp_setup() {
  local id="" tag="" name="" bin_name="" pip_pkg="" pkg_spec="" repo="" port="8000" health="/v1/models"
  local docker_pat="" svc_desc="" svc_args="" model_prompt="" live_label=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) id="$2"; shift 2 ;;
      --tag) tag="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --bin) bin_name="$2"; shift 2 ;;
      --pip-pkg) pip_pkg="$2"; shift 2 ;;
      --pkg-spec) pkg_spec="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --port) port="$2"; shift 2 ;;
      --health) health="$2"; shift 2 ;;
      --docker-pat) docker_pat="$2"; shift 2 ;;
      --svc-desc) svc_desc="$2"; shift 2 ;;
      --svc-args) svc_args="$2"; shift 2 ;;
      --model-prompt) model_prompt="$2"; shift 2 ;;
      --live-label) live_label="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$id" ]] || return 1
  _HOST_VP_TAG[$id]="$tag"
  _HOST_VP_NAME[$id]="$name"
  _HOST_VP_BIN_NAME[$id]="$bin_name"
  _HOST_VP_PIP_PKG[$id]="$pip_pkg"
  _HOST_VP_PKG_SPEC[$id]="${pkg_spec:-$pip_pkg}"
  _HOST_VP_REPO[$id]="$repo"
  _HOST_VP_PORT[$id]="$port"
  _HOST_VP_URL[$id]="http://127.0.0.1:${port}"
  _HOST_VP_HEALTH[$id]="$health"
  _HOST_VP_DOCKER_PAT[$id]="${docker_pat:-$id}"
  _HOST_VP_SVC_DESC[$id]="${svc_desc:-${name} Server}"
  _HOST_VP_SVC_ARGS[$id]="$svc_args"
  _HOST_VP_MODEL_PROMPT[$id]="$model_prompt"
  _HOST_VP_LIVE_LABEL[$id]="${live_label:-$name}"
}

_host_vp_refresh() {
  local id="$1" bin_name="${_HOST_VP_BIN_NAME[$1]:-}" pip_pkg="${_HOST_VP_PIP_PKG[$1]:-}"
  local docker_pat="${_HOST_VP_DOCKER_PAT[$1]:-$1}" bin="" ver="" docker="" src="none" vdir=""
  if [[ "$bin_name" == "python3" ]]; then
    vdir="$(_host_venv_dir "$id")"
    if [[ -x "${vdir}/bin/python3" ]]; then
      bin="${vdir}/bin/python3"
      ver="$(_host_venv_pkg_version "$id" "$pip_pkg" || true)"
      [[ -z "$ver" ]] && ver="installed"
    elif has_working_python3 && python3 -c "import ${pip_pkg//-/_}" 2>/dev/null; then
      bin="$(command -v python3)"
      ver="$(_host_venv_pkg_version "$id" "$pip_pkg" || echo "installed")"
    fi
  else
    bin="$(_host_venv_bin "$id" "$bin_name" || true)"
    if [[ -n "$bin" ]]; then
      ver="$(_host_venv_pkg_version "$id" "$pip_pkg" || true)"
      [[ -z "$ver" ]] && ver="installed"
    fi
  fi
  if [[ -z "$bin" && -n "$docker_pat" ]]; then
    docker="$(_host_find_docker "$docker_pat" || true)"
  fi
  src="$(_host_detect_install_source "$id" "$bin" "$pip_pkg" false)"
  _HOST_VP_BIN[$id]="$bin"
  _HOST_VP_VER[$id]="$ver"
  _HOST_VP_DOCKER[$id]="$docker"
  _HOST_VP_SRC[$id]="$src"
  local pat="$id"
  [[ -n "$bin_name" && "$bin_name" != "python3" ]] && pat="(^|/)${bin_name}([[:space:]]|$)"
  _HOST_VP_URL[$id]="$(_host_detect_url "http://127.0.0.1:${_HOST_VP_PORT[$id]}" "$pat" "$docker" "${id}.service")"
}

_host_vp_running() {
  local id="$1" base="${_HOST_VP_URL[$1]:-}" ep bin_name="${_HOST_VP_BIN_NAME[$1]:-}" pat="" rc=1
  local docker_val="${_HOST_VP_DOCKER[$1]:-}"
  # shortcut: run state cached 5s so dashboard redraws don't repeat pgrep+HTTP probes;
  # _host_vp_dispatch clears the cache after actions that can change server state.
  local cts="${_HOST_VP_RUN_TS[$id]:-}"
  if [[ -n "$cts" ]] && (( SECONDS - cts < 5 )); then
    [[ "${_HOST_VP_RUN[$id]:-1}" == "0" ]] && return 0
    return 1
  fi
  if [[ -n "$bin_name" && "$bin_name" != "python3" ]]; then
    pat="(^|/)${bin_name}([[:space:]]|$)"
  else
    pat="$id"
  fi
  if [[ -n "$docker_val" ]] || unit_active "${id}.service" 2>/dev/null || _host_proc_running "$pat"; then
    for ep in ${_HOST_VP_HEALTH[$id]:-/v1/models}; do
      if _host_http_ok "${base}${ep}" 1; then rc=0; break; fi
    done
  fi
  _HOST_VP_RUN[$id]="$rc"
  _HOST_VP_RUN_TS[$id]="$SECONDS"
  return "$rc"
}

_host_vp_menu_row() {
  local id="$1" sel="${2:-false}" running=false ver="${_HOST_VP_VER[$1]:-}" bin="${_HOST_VP_BIN[$1]:-}"
  _host_vp_running "$id" && running=true
  _host_std_menu_row "${_HOST_VP_TAG[$id]}" "${_HOST_VP_NAME[$id]}" "${bin:+$ver}" "${_HOST_VP_DOCKER[$id]:-}" "$running" "$sel"
}

_host_vp_check_summary() {
  local id="$1" running=false ver="${_HOST_VP_VER[$1]:-}" bin="${_HOST_VP_BIN[$1]:-}"
  _host_vp_running "$id" && running=true
  _host_std_check_summary "${_HOST_VP_NAME[$id]}" "${bin:+$ver}" "${_HOST_VP_URL[$id]}" "${_HOST_VP_DOCKER[$id]:-}" "$running" "$bin"
}

_host_vp_live_stats() {
  local id="$1" running=false
  _host_vp_running "$id" && running=true
  _host_std_live_stats "${_HOST_VP_LIVE_LABEL[$id]}" "${_HOST_VP_BIN[$id]:-}" "${_HOST_VP_URL[$id]}" "$running"
}

_host_vp_table_status() {
  local id="$1" running=false
  _host_vp_running "$id" && running=true
  _host_std_table_status "${_HOST_VP_BIN[$id]:-}" "${_HOST_VP_DOCKER[$id]:-}" "$running" "${id}.service"
}

_host_vp_check_update() {
  local id="$1"
  [[ -n "${_HOST_VP_BIN[$id]:-}" ]] && _host_check_update_by_source "$id" "${_HOST_VP_SRC[$id]:-none}" "${_HOST_VP_VER[$id]:-}" "${_HOST_VP_PIP_PKG[$id]}" "${_HOST_VP_REPO[$id]}" "${_HOST_VP_PIP_PKG[$id]}"
}

_host_vp_dispatch() {
  local id="$1" action="$2"
  local name="${_HOST_VP_NAME[$id]}" url="${_HOST_VP_URL[$id]}" port="${_HOST_VP_PORT[$id]}"
  unset "_HOST_VP_RUN_TS[$id]" "_HOST_VP_RUN[$id]"
  case "$action" in
    install|update)
      local upgrade=false
      [[ -n "${_HOST_VP_BIN[$id]:-}" ]] && upgrade=true
      _host_venv_install_or_upgrade "$id" "${_HOST_VP_PKG_SPEC[$id]}" "$upgrade"
      _host_vp_refresh "$id"
      _host_clear_update_cache "$id"
      ;;
    latest)
      local latest
      latest="$(_host_github_latest_tag "${_HOST_VP_REPO[$id]}" || true)"
      echo "  Installed: ${_HOST_VP_VER[$id]:-none}"
      echo "  Latest:    ${latest:-unavailable}"
      ;;
    service)
      local prompt="${_HOST_VP_MODEL_PROMPT[$id]:-}" model_id="" unit="${id}.service"
      if [[ -n "$prompt" ]] && ! service_installed "$unit"; then
        read -r -p "${prompt}: " model_id
        [[ -n "$model_id" ]] || return 0
      fi
      local q_bin q_model cmd="${_HOST_VP_SVC_ARGS[$id]}"
      q_bin="$(_host_shell_quote "${_HOST_VP_BIN[$id]:-}")"
      q_model="$(_host_shell_quote "$model_id")"
      cmd="${cmd//\{BIN\}/$q_bin}"
      cmd="${cmd//\{MODEL\}/$q_model}"
      cmd="${cmd//\{PORT\}/$port}"
      _host_manage_service_action "$name" "$unit" "${_HOST_VP_SVC_DESC[$id]}" "$cmd"
      ;;
    bench)
      _host_openai_bench "$name" "$url"
      ;;
    uninstall)
      _host_standard_uninstall "$id" "$name" "${id}.service" "${_HOST_VP_BIN[$id]:-}" "${_HOST_VP_SRC[$id]:-none}" "${_HOST_VP_PIP_PKG[$id]}"
      _host_vp_refresh "$id"
      _host_clear_update_cache "$id"
      ;;
  esac
}

_host_vp_cur_refresh() {
  local id="$_HOST_VP_ACTIVE_ID"
  _host_vp_refresh "$id"
  _HOST_VP_CUR_BIN="${_HOST_VP_BIN[$id]:-}"
  _HOST_VP_CUR_VER="${_HOST_VP_VER[$id]:-}"
  _HOST_VP_CUR_DOCKER="${_HOST_VP_DOCKER[$id]:-}"
  _HOST_VP_CUR_SRC="${_HOST_VP_SRC[$id]:-none}"
  _HOST_VP_CUR_URL="${_HOST_VP_URL[$id]:-}"
}

_host_vp_cur_running() { _host_vp_running "$_HOST_VP_ACTIVE_ID"; }
_host_vp_cur_dispatch() { _host_vp_dispatch "$_HOST_VP_ACTIVE_ID" "$1"; }

_host_vp_open() {
  local id="$1"
  _HOST_VP_ACTIVE_ID="$id"
  _host_run_options_page \
    --name "${_HOST_VP_NAME[$id]}" \
    --unit "${id}.service" \
    --refresh "_host_vp_cur_refresh" \
    --bin-var "_HOST_VP_CUR_BIN" \
    --ver-var "_HOST_VP_CUR_VER" \
    --docker-var "_HOST_VP_CUR_DOCKER" \
    --source-var "_HOST_VP_CUR_SRC" \
    --url "${_HOST_VP_URL[$id]}" \
    --url-var "_HOST_VP_CUR_URL" \
    --is-running "_host_vp_cur_running" \
    --dispatch "_host_vp_cur_dispatch"
}

_host_git_venv_install_or_update() {
  local id="$1" repo_url="$2" mode="$3" target="${4:-.}"
  command -v git >/dev/null 2>&1 || { echo -e "${C_RED}git is required to install ${id}.${C_RESET}"; return 1; }
  local pfx src_dir vdir
  pfx="${TARGET_HOME:-$HOME}/.local/share/strata-hosts/${id}"
  src_dir="${pfx}/src"
  vdir="$(_host_venv_dir "$id")"
  run_as_user_exec mkdir -p "$pfx" "$(dirname "$vdir")"
  if [[ -d "${src_dir}/.git" ]]; then
    run_as_user_exec git -C "$src_dir" pull --ff-only || return 1
  else
    run_as_user_exec git clone --depth 1 "$repo_url" "$src_dir" || return 1
  fi
  local -a pip_args=()
  if [[ "$mode" == "req" ]]; then
    pip_args=(-r "${src_dir}/${target}")
  else
    pip_args=(-e "$src_dir")
  fi
  if command -v uv >/dev/null 2>&1; then
    [[ -x "${vdir}/bin/python3" ]] || run_as_user_exec uv venv "$vdir" || return 1
    run_as_user_exec uv pip install --python "${vdir}/bin/python3" "${pip_args[@]}"
  else
    has_working_python3 || { echo -e "${C_RED}python3 is required to install ${id}.${C_RESET}"; return 1; }
    [[ -x "${vdir}/bin/python3" ]] || run_as_user_exec python3 -m venv "$vdir" || return 1
    run_as_user_exec "${vdir}/bin/pip" install "${pip_args[@]}"
  fi
}
