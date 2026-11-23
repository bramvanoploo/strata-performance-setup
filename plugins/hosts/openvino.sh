#!/usr/bin/env bash
# PLUGIN_ID: openvino
# PLUGIN_NAME: OpenVINO
# PLUGIN_DESC: Install, update, manage service, and benchmark OpenVINO Model Server (Intel NPU/GPU/CPU)
# PLUGIN_PLATFORMS: linux

_OPENVINO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${_OPENVINO_DIR}/_common.sh" ]] && source "${_OPENVINO_DIR}/_common.sh"

register_host_plugin \
  --id "openvino" \
  --name "OpenVINO" \
  --description "Install, update, manage service, and benchmark OpenVINO Model Server (Intel NPU/GPU/CPU)" \
  --platforms "linux"

OPENVINO_BIN=""
OPENVINO_VERSION=""
OPENVINO_DOCKER=""
OPENVINO_SOURCE="none"
OPENVINO_PORT="${OPENVINO_PORT:-8000}"
OPENVINO_URL="http://127.0.0.1:${OPENVINO_PORT}"

_openvino_serve_py() {
  echo "${TARGET_HOME:-$HOME}/.local/share/strata-hosts/openvino/serve.py"
}

_openvino_write_serve_py() {
  local srv
  srv="$(_openvino_serve_py)"
  run_as_user_exec mkdir -p "$(dirname "$srv")"
  run_as_user_exec tee "$srv" >/dev/null <<'PY'
#!/usr/bin/env python3
import argparse, json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import openvino_genai as ov_genai

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True)
    p.add_argument("--device", default="NPU")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8000)
    args = p.parse_args()
    pipe = ov_genai.LLMPipeline(args.model, args.device)
    model_id = os.path.basename(os.path.abspath(args.model)) or "openvino-genai"

    class Handler(BaseHTTPRequestHandler):
        def _send(self, code, obj):
            body = json.dumps(obj).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path in ("/v1/models", "/v3/models"):
                self._send(200, {"object": "list", "data": [{"id": model_id, "object": "model"}]})
            elif self.path in ("/health", "/v1/config"):
                self._send(200, {"status": "ok"})
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            if self.path != "/v1/chat/completions":
                self._send(404, {"error": "not found"})
                return
            ln = int(self.headers.get("Content-Length", "0") or 0)
            req = json.loads(self.rfile.read(ln).decode("utf-8"))
            msgs = req.get("messages") or []
            prompt = "\n".join(f"{m.get('role', 'user')}: {m.get('content', '')}" for m in msgs)
            cfg = ov_genai.GenerationConfig()
            cfg.max_new_tokens = int(req.get("max_tokens") or 128)
            text = pipe.generate(prompt, cfg)
            self._send(200, {
                "id": f"ov-{int(time.time())}",
                "object": "chat.completion",
                "model": model_id,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
            })

    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()

if __name__ == "__main__":
    main()
PY
}

_openvino_refresh() {
  OPENVINO_BIN="$(_host_find_bin ovms || true)"
  OPENVINO_VERSION=""
  if [[ -n "$OPENVINO_BIN" ]]; then
    OPENVINO_VERSION="$(run_as_user_exec "$OPENVINO_BIN" --version 2>/dev/null | head -n1 || echo "installed")"
  else
    local vdir
    vdir="$(_host_venv_dir "openvino")"
    if [[ -x "${vdir}/bin/python3" ]]; then
      OPENVINO_VERSION="$(_host_venv_pkg_version "openvino" "openvino-genai" || true)"
      [[ -n "$OPENVINO_VERSION" ]] && OPENVINO_BIN="${vdir}/bin/python3"
    fi
  fi
  OPENVINO_DOCKER=""
  if [[ -z "$OPENVINO_BIN" ]]; then
    OPENVINO_DOCKER="$(_host_find_docker 'openvino|ovms' || true)"
  fi
  OPENVINO_SOURCE="$(_host_detect_install_source "openvino" "$OPENVINO_BIN" "openvino-genai" false)"
  OPENVINO_URL="$(_host_detect_url "http://127.0.0.1:${OPENVINO_PORT}" '(^|/)ovms([[:space:]]|$)|hosts/openvino/serve\.py' "$OPENVINO_DOCKER" "openvino.service")"
}

_openvino_running() {
  local pat='(^|/)ovms([[:space:]]|$)|hosts/openvino/serve\.py'
  _host_endpoint_running "${OPENVINO_URL}/v1/models" "$pat" "$OPENVINO_DOCKER" "openvino.service" ||
    _host_endpoint_running "${OPENVINO_URL}/v3/models" "$pat" "$OPENVINO_DOCKER" "openvino.service" ||
    _host_endpoint_running "${OPENVINO_URL}/v1/config" "$pat" "$OPENVINO_DOCKER" "openvino.service"
}

openvino_init() {
  _openvino_refresh
}

openvino_menu_row() {
  local running=false
  _openvino_running && running=true
  _host_std_menu_row "OVMS" "OpenVINO" "${OPENVINO_BIN:+$OPENVINO_VERSION}" "$OPENVINO_DOCKER" "$running" "${1:-false}"
}

openvino_check_summary() {
  local running=false
  _openvino_running && running=true
  _host_std_check_summary "OpenVINO" "${OPENVINO_BIN:+$OPENVINO_VERSION}" "$OPENVINO_URL" "$OPENVINO_DOCKER" "$running" "$OPENVINO_BIN"
}

openvino_hw_warnings() {
  if [[ "$HAS_INTEL_NPU" != true && "$HAS_INTEL_GPU" != true ]]; then
    echo -e "  ${C_YELLOW}[OpenVINO]${C_RESET} No Intel NPU/GPU detected; OpenVINO will run on CPU."
  fi
}

openvino_live_stats() {
  local running=false
  _openvino_running && running=true
  _host_std_live_stats "OpenVINO" "$OPENVINO_BIN" "$OPENVINO_URL" "$running"
}

openvino_table_status() {
  local running=false
  _openvino_running && running=true
  _host_std_table_status "$OPENVINO_BIN" "$OPENVINO_DOCKER" "$running" "openvino.service"
}

openvino_check_update() {
  [[ -n "$OPENVINO_BIN" ]] && _host_check_update_by_source "openvino" "$OPENVINO_SOURCE" "$OPENVINO_VERSION" "openvino-genai" "openvinotoolkit/model_server" "openvino-genai"
}

openvino_update() {
  _openvino_dispatch update
}

_openvino_dispatch() {
  case "$1" in
    install|update)
      local upgrade=false
      [[ -n "$OPENVINO_BIN" ]] && upgrade=true
      _host_venv_install_or_upgrade "openvino" "openvino-genai" "$upgrade"
      _openvino_write_serve_py
      _openvino_refresh
      _host_clear_update_cache "openvino"
      ;;
    latest)
      local latest
      latest="$(_host_github_latest_tag "openvinotoolkit/model_server" || true)"
      echo "  Installed: ${OPENVINO_VERSION:-none}"
      echo "  Latest:    ${latest:-unavailable}"
      ;;
    service)
      local model_repo="" dev_target="CPU"
      [[ "$HAS_INTEL_GPU" == true ]] && dev_target="GPU"
      [[ "$HAS_INTEL_NPU" == true ]] && dev_target="NPU"
      if ! service_installed "openvino.service"; then
        read -r -p "OpenVINO IR model directory path: " model_repo
        [[ -n "$model_repo" ]] || return 0
      fi
      local q_bin q_repo
      q_bin="$(_host_shell_quote "$OPENVINO_BIN")"
      q_repo="$(_host_shell_quote "$model_repo")"
      if [[ -n "$OPENVINO_BIN" && "$(basename "$OPENVINO_BIN")" == "ovms" ]]; then
        _host_manage_service_action "OpenVINO" "openvino.service" "OpenVINO Model Server" \
          "${q_bin} --rest_port ${OPENVINO_PORT} --source_model ${q_repo} --task text_generation --target_device ${dev_target}"
      else
        local srv q_srv
        srv="$(_openvino_serve_py)"
        [[ -f "$srv" ]] || _openvino_write_serve_py
        q_srv="$(_host_shell_quote "$srv")"
        _host_manage_service_action "OpenVINO" "openvino.service" "OpenVINO GenAI Server" \
          "${q_bin} ${q_srv} --model ${q_repo} --device ${dev_target} --host 0.0.0.0 --port ${OPENVINO_PORT}"
      fi
      ;;
    bench)
      _host_openai_bench "OpenVINO" "$OPENVINO_URL"
      ;;
    uninstall)
      _host_standard_uninstall "openvino" "OpenVINO" "openvino.service" "$OPENVINO_BIN" "$OPENVINO_SOURCE" "openvino-genai"
      _openvino_refresh
      _host_clear_update_cache "openvino"
      ;;
  esac
}

openvino_open() {
  _host_run_options_page \
    --name "OpenVINO" \
    --unit "openvino.service" \
    --refresh "_openvino_refresh" \
    --bin-var "OPENVINO_BIN" \
    --ver-var "OPENVINO_VERSION" \
    --docker-var "OPENVINO_DOCKER" \
    --source-var "OPENVINO_SOURCE" \
    --url "$OPENVINO_URL" \
    --url-var "OPENVINO_URL" \
    --is-running "_openvino_running" \
    --dispatch "_openvino_dispatch"
}
