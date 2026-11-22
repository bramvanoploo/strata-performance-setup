---
name: create-host-plugin
description: >
  Create a new lazy-loaded LLM inference host plugin in plugins/hosts/<id>.sh
  (e.g. Ollama, vLLM, llama.cpp) for strata-performance-setup.
---

# Create an LLM Host Plugin

Use this workflow when adding support for a new LLM inference server/host in `plugins/hosts/`.

## 1. Create the Plugin File

1. Copy `plugins/hosts/_template.sh` to `plugins/hosts/<id>.sh` using a lowercase alphanumeric/hyphen `<id>` (e.g. `ollama`).
2. Set the 3-line metadata header at the top of the file (used by `scripts/gen-registry.sh` and `discover_host_plugins`):
   ```bash
   # PLUGIN_ID: <id>
   # PLUGIN_NAME: <Display Name>
   # PLUGIN_DESC: <One-line description>
   ```
3. Call `register_host_plugin`:
   ```bash
   register_host_plugin \
     --id "<id>" \
     --name "<Display Name>" \
     --description "<One-line description>"
   ```

## 2. Implement Required Hooks

Every host plugin **must** define these three functions (verified by `tests/test_strata_setup.sh`):

- `<id>_init()` — Called once immediately after sourcing. Detect binary/container/version or start lightweight background pollers.
- `<id>_menu_row()` — Accepts `$1` (`true` if selected on Index, `false` otherwise) and prints a single formatted row (use `C_BOLD`, `C_CYAN`, `C_MAGENTA`, `C_DIM`, `C_RESET`).
- `<id>_open()` — Renders and handles the interactive TUI subpage, returning `0` when the user exits back to the Index.

## 3. Optional Hooks

Implement only what the host needs:

- `<id>_live_stats()` — Populate `LIVE_STAT_LINES` / `LIVE_COMPACT_STRATA` for `[STATS]`.
- `<id>_check_summary()` — Print `  <Name>: ...` lines during `--check` / `[c]`.
- `<id>_hw_warnings()` — Print hardware compatibility warnings above the Index.
- `<id>_cleanup()` — Stop any background pollers started by `<id>_init` on exit.

## 4. Reuse Core Helpers

- Never hardcode `systemctl` / `launchctl` / `rc.d` logic directly when `install_service`, `remove_service`, `service_ctl`, `service_installed`, `unit_enabled`, and `unit_active` handle Linux (`systemd`, SysVinit, Unraid, Synology) and macOS (`launchd`) uniformly.
- Use `run_root`, `run_as_user`, `pkg_install`, `confirm_yn`, `pause_prompt`, and `print_header`.
- Keep Bash 4.3+ and `set -uo pipefail` compatibility (quote variables, handle empty values with `|| true`).

## 5. Register & Verify

1. Regenerate the plugin registry and SHA-256 checksums:
   ```bash
   ./scripts/gen-registry.sh
   ```
2. Run the full test suite (checks `bash -n`, required hooks, and registry integrity):
   ```bash
   ./tests/test_strata_setup.sh
   ```
3. Smoke-test read-only detection with the new plugin pre-loaded:
   ```bash
   ./strata-performance-setup.sh --plugin <id> --check
   ```
