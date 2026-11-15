# Using the Wizard

Once launched, the main index lists every optimization applicable to your machine along with its live `[APPLIED]` / `[NOT APPLIED]` status:

- Navigate the index with **`↑` / `↓`** and press **`Enter`** (or type a **step number** / `s1`–`s5`) to open a step or Strata option, or press `w` to walk through the **guided wizard** step by step
- Press `a` to **apply all recommended optimizations** for your hardware in one action (with confirmation; excludes Strata setup, experimental options, and minimal-gain/higher-idle-power options like CPU Performance and PCIe ASPM)
- Press `x` to **revert all recommended optimizations** in one action (with confirmation)
- Press `u` (when shown) to open the **Update Strata** page, install a pending Strata update, and restart `strata.service`
- Press `r` on the index to **reboot** the system (the wizard also prompts automatically whenever applying or reverting a change requires a reboot)
- Inside any step, press `a` to **apply** (when not yet applied, or to open the Strata Manager menu), `r` to **revert** (when applied), `n` / `b` to move next/back, or `i` / `Esc` to return to the index
- Open **View All Benchmark Results & Coupled Options** (from Strata Options) to browse full-width tables of all recorded benchmarks with median/average `tok/s`, average system/GPU/CPU power, and a vertical list of active optimizations; use **`↑` / `↓` + `Enter`** (or `[1-N]`) to restore a benchmark's host configuration (with `[y]` Apply / `[N/c/Esc]` Cancel confirmation)
