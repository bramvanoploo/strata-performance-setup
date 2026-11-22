# Project Instructions (`strata-performance-setup`)

Interactive Bash 4.3+ TUI wizard and host performance optimizer with a lazy-loaded plugin architecture.

## Repository Layout

- `strata-performance-setup.sh` — Core entrypoint: CLI parsing, OS/hardware detection, shared helpers, TUI engine, and plugin loader.
- `plugins/hosts/` — LLM inference host managers (e.g. `strata.sh`). Lazy-loaded when selected on the Index page or passed via `--plugin <id>`.
- `plugins/tweaks/` — Hardware/OS performance tweak packs (`common.sh`, `linux-core.sh`, `linux-laptop.sh`, `nvidia.sh`, `amd.sh`, `intel.sh`, `jetson.sh`, `macos.sh`). Loaded automatically based on detected OS and hardware.
- `plugins/registry.tsv` — Auto-generated plugin manifest + SHA-256 checksums. Regenerate with `./scripts/gen-registry.sh` (never edit by hand).
- `documentation/contributing-plugins.md` — Human-facing contributor guide.
- `tests/test_strata_setup.sh` — Syntax, CLI, plugin registry, and unit test suite.

## Rules for Contributors & Agents

1. **Do not edit core to add a host or tweak.** Put LLM hosts in `plugins/hosts/<id>.sh` and tweaks in the matching `plugins/tweaks/<pack>.sh`.
2. **Reuse core helpers** instead of reimplementing OS/init/package logic:
   - Privileges & prompts: `run_root`, `run_as_user`, `confirm_yn`, `pause_prompt`
   - Services (`systemd` / `launchd` / SysVinit / Unraid / Synology): `install_service`, `remove_service`, `service_ctl`, `service_installed`, `unit_enabled`, `unit_active`
   - Packages: `pkg_installed`, `pkg_available`, `pkg_install`, `aur_install`, `prompt_install_deps`
   - Kernel & sysctl: `add_kernel_param`, `remove_kernel_param`, `has_kernel_param`, `kernel_param_value`, `write_sysctl_with_prev`, `restore_sysctl_prev`
   - TUI: `print_header`, `read_step_action`, color variables (`C_BOLD`, `C_GREEN`, `C_YELLOW`, `C_CYAN`, `C_DIM`, `C_RESET`)
3. **Preserve Bash 4.3+ and `set -uo pipefail` compatibility** (including macOS Homebrew Bash 4.3+).
4. **Always run `./scripts/gen-registry.sh` and `./tests/test_strata_setup.sh`** after adding or editing any plugin.

## Skills

- Creating a new LLM host plugin: `.agents/skills/create-host-plugin/SKILL.md`
- Creating or adding a performance tweak: `.agents/skills/create-tweak-plugin/SKILL.md`
