# Supported Inference Servers

> **Note:** The modular plugin system and all non-Strata inference server plugins are **experimental**. Only servers compatible with your detected OS and hardware are shown in the wizard's `[SERVERS]` (**Inference Servers**) menu and `--list-plugins`.

## Inference Server Matrix

| Plugin ID | Server | Status | Platforms | Install | Service | Updates | Benchmark | Live Stats | Notes |
| :--- | :--- | :--- | :--- | :---: | :---: | :---: | :---: | :---: | :--- |
| `strata` | **Strata** | Primary | Linux, macOS | ✓ | ✓ | ✓ | ✓ | ✓ | Native installer/updater, `systemd`/`launchd`, local AMD HIP builds, `strata bench`, `/metrics` |
| `adamant` | **Adamant** | Experimental | Linux (NVIDIA) | ✓ | ✓ | — | ✓ | ✓ | NVIDIA Ada/Ampere (`sm_89`/`sm_86`) Basalt/Strata fork, OpenAI bench & live stats |
| `basalt` | **Basalt** | Experimental | Linux (NVIDIA) | ✓ | ✓ | ✓ | ✓ | ✓ | NVIDIA Blackwell (`sm_120`) Strata fork, release check, OpenAI bench & live stats |
| `exo` | **exo** | Experimental | Linux, macOS | ✓ | ✓ | ✓ | ✓ | ✓ | Distributed cluster server, release check, OpenAI bench & live stats |
| `ik-llamacpp` | **ik_llama.cpp** | Experimental | Linux, macOS | ✓ | ✓ | — | ✓ | ✓ | CPU/hybrid MoE `llama.cpp` fork (`llama-server`), `llama-bench` & OpenAI bench |
| `ktransformers` | **KTransformers** | Experimental | Linux | ✓ | ✓ | ✓ | ✓ | ✓ | Hybrid CPU/GPU MoE server, `uv`/`pip` venv, release check, OpenAI bench |
| `lemonade` | **Lemonade** | Experimental | Linux | ✓ | ✓ | ✓ | ✓ | ✓ | AMD Ryzen AI NPU/iGPU server, release check, OpenAI bench & live stats |
| `llamacpp` | **llama.cpp** | Experimental | Linux, macOS | ✓ | ✓ | ✓ | ✓ | ✓ | `brew` / distro / AUR (`llama-server`), `llamacpp.service`, `llama-bench` & OpenAI bench, Docker detection |
| `localai` | **LocalAI** | Experimental | Linux, macOS | ✓ | ✓ | ✓ | ✓ | ✓ | Official installer / `brew`, `localai.service`, `/readyz` live stats, OpenAI bench, Docker detection |
| `mlx-lm` | **MLX LM** | Experimental | macOS (Apple Silicon) | ✓ | ✓ | ✓ | ✓ | ✓ | Isolated `uv`/`pip` venv, `mlx-lm.service` (`launchd`), `mlx_lm.benchmark` & OpenAI bench |
| `ollama` | **Ollama** | Experimental | Linux, macOS | ✓ | ✓ | ✓ | ✓ | ✓ | Official installer / `brew`, `ollama.service`, `/api/ps` live stats, OpenAI `/v1/` bench, Docker detection |
| `openvino` | **OpenVINO** | Experimental | Linux | ✓ | ✓ | ✓ | ✓ | ✓ | OpenVINO Model Server (Intel NPU/GPU/CPU), release check, OpenAI bench & live stats |
| `polystrata` | **PolyStrata** | Experimental | Linux, macOS | ✓ | ✓ | ✓ | ✓ | ✓ | Multi-engine Strata fork, release check, OpenAI bench & live stats |
| `sglang` | **SGLang** | Experimental | Linux | ✓ | ✓ | ✓ | ✓ | ✓ | Isolated `uv`/`pip` venv, `sglang.service`, `/health` live stats, OpenAI bench, Docker detection |
| `tabbyapi` | **TabbyAPI** | Experimental | Linux (GPU) | ✓ | ✓ | ✓ | ✓ | ✓ | ExLlamaV2/V3 server, release check, OpenAI bench & live stats |
| `tensorrt-llm` | **TensorRT-LLM** | Experimental | Linux (NVIDIA) | ✓ | ✓ | ✓ | ✓ | ✓ | NVIDIA TensorRT-LLM (`trtllm-serve`), release check, OpenAI bench & live stats |
| `vllm` | **vLLM** | Experimental | Linux | ✓ | ✓ | ✓ | ✓ | ✓ | Isolated `uv`/`pip` venv, `vllm.service`, `/health` live stats, OpenAI bench, Docker detection |

## Platform Filtering

- **`mlx-lm`** (`macos-arm64`) is only shown when running on **macOS with Apple Silicon** (`IS_MACOS=true` and `IS_APPLE_SILICON=true`). It is hidden on Linux and Intel Macs.
- **`adamant`**, **`basalt`**, and **`tensorrt-llm`** (`linux-nvidia`) are only shown on **Linux with a detected NVIDIA GPU**.
- **`tabbyapi`** (`linux-gpu`) is only shown on **Linux with a detected NVIDIA, AMD, or Intel GPU**.
- **`ktransformers`**, **`lemonade`**, **`openvino`**, **`sglang`**, and **`vllm`** (`linux`) are only shown on **Linux** (and emit hardware warnings on the Inference Servers page when the target GPU/NPU is absent).
- **`strata`**, **`exo`**, **`ik-llamacpp`**, **`llamacpp`**, **`localai`**, **`ollama`**, and **`polystrata`** (`all`) are shown on both **Linux and macOS**.

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
