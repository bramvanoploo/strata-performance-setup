# Supported Inference Servers

> **Note:** The modular plugin system and all non-Strata inference server plugins are **experimental**. Only servers compatible with your detected OS and hardware are shown in the wizard's `[SERVERS]` (**Inference Servers**) menu and `--list-plugins`.

## Inference Server Matrix

| Plugin ID | Server | Status | Platforms | Install | Service | Updates | Benchmark | Live Stats | Notes |
| :--- | :--- | :--- | :--- | :---: | :---: | :---: | :---: | :---: | :--- |
| `strata` | **Strata** | Primary | Linux, macOS | ✓ | ✓ | ✓ | ✓ | ✓ | Native installer/updater, `systemd`/`launchd`, local AMD HIP builds, `strata bench`, `/metrics` |
| `ollama` | **Ollama** | Experimental | Linux, macOS | ✓ | ✓ | ✓ | ✓ | ✓ | Official installer / `brew`, `ollama.service`, `/api/ps` live stats, OpenAI `/v1/` bench, Docker detection |
| `llamacpp` | **llama.cpp** | Experimental | Linux, macOS | ✓ | ✓ | ✓ | ✓ | ✓ | `brew` / distro / AUR (`llama-server`), `llamacpp.service`, `llama-bench` & OpenAI bench, Docker detection |
| `localai` | **LocalAI** | Experimental | Linux, macOS | ✓ | ✓ | ✓ | ✓ | ✓ | Official installer / `brew`, `localai.service`, `/readyz` live stats, OpenAI bench, Docker detection |
| `vllm` | **vLLM** | Experimental | Linux | ✓ | ✓ | ✓ | ✓ | ✓ | Isolated `uv`/`pip` venv, `vllm.service`, `/health` live stats, OpenAI bench, Docker detection |
| `sglang` | **SGLang** | Experimental | Linux | ✓ | ✓ | ✓ | ✓ | ✓ | Isolated `uv`/`pip` venv, `sglang.service`, `/health` live stats, OpenAI bench, Docker detection |
| `mlx-lm` | **MLX LM** | Experimental | macOS (Apple Silicon) | ✓ | ✓ | ✓ | ✓ | ✓ | Isolated `uv`/`pip` venv, `mlx-lm.service` (`launchd`), `mlx_lm.benchmark` & OpenAI bench |

## Platform Filtering

- **`mlx-lm`** is only shown when running on **macOS with Apple Silicon** (`IS_MACOS=true` and `IS_APPLE_SILICON=true`). It is hidden on Linux and Intel Macs.
- **`vllm`** and **`sglang`** are only shown on **Linux** (and emit a warning if no discrete NVIDIA, AMD, or Intel GPU is detected).
- **`strata`**, **`ollama`**, **`llamacpp`**, and **`localai`** are shown on both Linux and macOS.

## Docker-Backed Servers

When a supported server is detected running inside a Docker or Podman container (without a native host binary), its status displays `[INSTALLED]` (`running (docker)`) and its manager page exposes **Run benchmark** and **Check latest upstream release** instead of native install/service actions.

## CLI Usage

```bash
# List inference server plugins applicable to this machine
./strata-performance-setup.sh --list-plugins

# Pre-load specific inference server plugin(s) for --check or TUI use
./strata-performance-setup.sh --plugin ollama,llamacpp --check

# Pre-download all plugins into cache for offline use
./strata-performance-setup.sh --download-plugins
```

To add or improve an inference server plugin, see [Contributing Plugins](contributing-plugins.md).
