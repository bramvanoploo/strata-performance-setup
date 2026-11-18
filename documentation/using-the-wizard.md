# Using the Wizard

To inspect detected hardware, OS/init, Strata or Docker container status, and which steps would apply without launching the TUI or making changes, run `./strata-performance-setup.sh --check`. For API-key-protected Strata instances, pass `--strata-api-key <key>` (overrides `STRATA_API_KEY`) or export `STRATA_API_KEY` so live `/metrics` telemetry, `strata bench run` benchmarks, and Strata CLI requests authenticate automatically (see `--help` for CLI options).

Once launched, the main index lists `[STATS]` (live system & Strata metrics), `[STRATA]` (Strata options & benchmark summaries), and every optimization applicable to your machine along with its live `[APPLIED]` / `[NOT APPLIED]` status:

- Navigate the index with **`↑` / `↓`** and press **`Enter`** (or type a **step number**) to open `[STATS]`, `[STRATA]`, or an optimization step, or press `w` to walk through the **guided wizard** step by step
- Press `c` on the index to view the read-only **Check / detection summary** inside the TUI (same OS, hardware, Strata, and step-applicability summary as `--check`)
- Open `[STRATA]` for Strata lifecycle management (`s1`–`s6` / `1`–`6`: Install, Update, Remove, Service, Benchmark, and Benchmark History) along with Latest, Previous, and Best benchmark summaries
- Press `a` to **apply all recommended optimizations** for your hardware in one action (with confirmation; excludes Strata setup, experimental options, and minimal-gain/higher-idle-power options like CPU Performance and PCIe ASPM)
- Press `l` (shown on laptops) to **apply laptop-recommended optimizations** (`[L]`) for minimal idle battery power impact and comfortable unplugged usage across any laptop vendor (additionally excludes sleep/lid-close masking, idle high-clock/persistence GPU settings, and platform/vendor performance profiles). When applying via `a` or `l`, any currently applied options outside that scope are listed so you can choose to revert them or leave them as is
- Press `x` to **revert all recommended optimizations** in one action (with confirmation)
- Press `u` (when shown) to open the **Update Strata** page, install a pending Strata update, and restart `strata.service`
- Press `r` on the index to **reboot** the system (the wizard also prompts automatically whenever applying or reverting a change requires a reboot)
- Inside any step, press `a` to **apply** (when not yet applied), `r` to **revert** (when applied), `n` / `b` to move next/back, or `i` / `Esc` to return to the index
- Open **View All Benchmark Results & Coupled Options** (from `[STRATA]`, or press `h` when history exists) to browse full-width tables of all recorded benchmarks with median/average `tok/s`, average system/GPU/CPU power, and a vertical list of active optimizations; use **`↑` / `↓` + `Enter`** (or `[1-N]`) to restore a benchmark's host configuration (with `[y]` Apply / `[N/c/Esc]` Cancel confirmation). *(Note: after a cold model load, run a warmup pass before A/B comparing host optimizations—decode throughput can ramp over the first several probes as the engine warms up.)*
