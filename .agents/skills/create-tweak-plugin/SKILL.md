---
name: create-tweak-plugin
description: >
  Add a new host/hardware performance tweak to plugins/tweaks/<pack>.sh (or
  create a new tweak pack) for strata-performance-setup.
---

# Create a Performance Tweak

Use this workflow when adding a new OS, kernel, CPU, GPU, or laptop performance optimization in `plugins/tweaks/`.

## 1. Choose the Target Pack

Add the tweak to the matching existing pack in `plugins/tweaks/`:
- `common.sh` — Cross-platform tweaks (`--os "both"`).
- `linux-core.sh` — General Linux kernel, sysctl, memory, CPU, PCIe, storage, or network tweaks.
- `linux-laptop.sh` — Laptop OEM thermal/fan profile tweaks.
- `nvidia.sh` / `amd.sh` / `intel.sh` / `jetson.sh` — Vendor-specific GPU/CPU/SoC tweaks.
- `macos.sh` — macOS / Apple Silicon tweaks.

If creating a brand-new hardware/platform pack, copy `plugins/tweaks/_template.sh` to `plugins/tweaks/<pack>.sh` and wire its detection trigger in `load_applicable_tweak_packs()` inside `strata-performance-setup.sh`.

## 2. Register the Tweak

Call `register_tweak` once at the top of the pack:
```bash
register_tweak \
  --id "<snake_case_id>" \
  --stars 3 \                  # 1..5 relative performance/utility rating
  --tier "recommended" \       # recommended | opt_in | experimental | high_idle
  --os "linux" \               # linux | macos | both
  --laptop-recommended true \  # true | false
  --vm-supported true          # true | false
```

## 3. Implement All 6 Required Functions

Every registered tweak **must** define all 6 functions (verified by `tests/test_strata_setup.sh`):

- `applicable_<id>()` — Return `0` if this tweak applies to the current hardware/OS, `1` otherwise. Keep it fast and read-only.
- `title_<id>()` — Echo a concise, single-line title for the Index table.
- `status_<id>()` — Return `0` if currently applied on the host, `1` otherwise.
- `explain_<id>()` — Print what the tweak changes, why it helps, and any trade-offs.
- `apply_<id>()` — Apply the optimization cleanly.
- `revert_<id>()` — Cleanly revert the optimization and restore prior state.

## 4. Reuse Core Helpers

- **Kernel parameters:** `add_kernel_param`, `remove_kernel_param`, `has_kernel_param`, `kernel_param_value` (handles GRUB, systemd-boot, BLS, rEFInd, elilo, and `/etc/kernel/cmdline`).
- **Sysctl:** `write_sysctl_with_prev`, `restore_sysctl_prev`.
- **Services:** `install_service`, `remove_service`, `service_installed`, `unit_enabled`.
- **Packages & privileges:** `pkg_available`, `pkg_installed`, `prompt_install_deps`, `run_root`, `run_as_user`.
- Preserve `set -uo pipefail` safety (guard optional reads with `2>/dev/null || true`).

## 5. Register & Verify

1. Regenerate `plugins/registry.tsv`:
   ```bash
   ./scripts/gen-registry.sh
   ```
2. Run the full test suite (validates `bash -n`, all 6 handlers, and `STEP_GAIN_PTS`):
   ```bash
   ./tests/test_strata_setup.sh
   ```
3. Verify read-only applicability output:
   ```bash
   ./strata-performance-setup.sh --check
   ```
